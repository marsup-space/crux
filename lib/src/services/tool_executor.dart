import 'dart:convert';

import '../models/provider_config.dart';
import '../models/session_runtime_state.dart';
import '../tools/edit_tool.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../tools/write_tool.dart';
import 'llm_client.dart';

class ToolCall {
  final String callId;
  final String name;
  final Map<String, dynamic> input;
  final String? parseError;

  const ToolCall({
    required this.callId,
    required this.name,
    required this.input,
    this.parseError,
  });
}

class _ToolCallAccum {
  String? callId;
  String? name;
  final StringBuffer inputBuffer = StringBuffer();
}

class ToolExecutor {
  final ToolRegistry _registry;

  /// Runtime gate for the subagent workers-mode guard (plan §模式切换
  /// 与 cache item 3): when the workers switch is on, hands-on tools
  /// (edit / write / bash / powershell / cmd) called by the MAIN agent
  /// are redirected to send_agent instead of executed. Null (tests,
  /// legacy harnesses) disables the guard.
  ///
  /// Returns the redirect ToolResult, or null to allow the call.
  final ToolResult? Function(String toolName)? subagentWorkersGuard;

  ToolExecutor(this._registry, {this.subagentWorkersGuard});

  ToolDef? lookupTool(String name) => _registry.lookup(name);

  /// Names of every tool currently registered, in registry
  /// declaration order. Used by the streaming-time unknown-tool
  /// abort (see `_StreamingGuardAccumulator.accumulateAndCheck` in
  /// `chat_turn_executor.dart`) so the model can be told which
  /// tools *do* exist when it hallucinates a tool name (e.g.
  /// `ask`) that doesn't.
  List<String> allToolNames() => [for (final tool in _registry.all) tool.name];

  Future<GuardResult?> checkWriteGuard({
    required String filePath,
    required String workingDirectory,
    SessionRuntimeState? sessionRuntime,
  }) async {
    final tool = _registry.lookup('write');
    if (tool is! WriteTool) return null;
    return tool.checkStreamingGuard(
      filePath: filePath,
      workingDirectory: workingDirectory,
      sessionRuntime: sessionRuntime,
    );
  }

  Future<GuardResult?> checkEditGuard({
    required String filePath,
    required String oldString,
    required String workingDirectory,
    SessionRuntimeState? sessionRuntime,
  }) async {
    final tool = _registry.lookup('edit');
    if (tool is! EditTool) return null;
    return tool.checkStreamingGuard(
      filePath: filePath,
      oldString: oldString,
      workingDirectory: workingDirectory,
      sessionRuntime: sessionRuntime,
    );
  }

  Future<ToolResult> executeTool(ToolCall call, ToolContext ctx) async {
    if (call.parseError != null) {
      return ToolResult.error(call.parseError!);
    }
    final tool = _registry.lookup(call.name);
    if (tool == null) {
      return ToolResult.error('Unknown tool: ${call.name}');
    }
    // Subagent workers-mode guard: reflect the LIVE switch state on
    // every call (an announcement the model forgot does not matter —
    // the guard is the enforcement).
    if (subagentWorkersGuard case final guard?) {
      if (guard(call.name) case final blocked?) {
        return blocked;
      }
    }
    return tool.execute(call.input, ctx);
  }

  Map<String, dynamic> formatToolResultForApi(
    ToolCall call,
    ToolResult result,
    WireFamily wireFamily,
  ) {
    if (wireFamily == WireFamily.anthropicCompatible) {
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': call.callId,
            'content': result.output,
          },
        ],
      };
    }
    return {
      'role': 'tool',
      'tool_call_id': call.callId,
      'content': result.output,
    };
  }

  Map<String, dynamic> formatAssistantToolCallsMessage(
    List<ToolCall> calls,
    String textContent,
    WireFamily wireFamily, {
    String reasoningContent = '',
    String reasoningSignature = '',
  }) {
    if (wireFamily == WireFamily.anthropicCompatible) {
      final content = <Map<String, dynamic>>[];
      if (reasoningContent.isNotEmpty && reasoningSignature.isNotEmpty) {
        content.add({
          'type': 'thinking',
          'thinking': reasoningContent,
          'signature': reasoningSignature,
        });
      }
      if (textContent.isNotEmpty) {
        content.add({'type': 'text', 'text': textContent});
      }
      for (final call in calls) {
        content.add({
          'type': 'tool_use',
          'id': call.callId,
          'name': call.name,
          'input': call.input,
        });
      }
      return {'role': 'assistant', 'content': content};
    }
    final toolCalls = calls
        .map(
          (call) => {
            'id': call.callId,
            'type': 'function',
            'function': {
              'name': call.name,
              'arguments': jsonEncode(call.input),
            },
          },
        )
        .toList();
    return {
      'role': 'assistant',
      'content': textContent.isNotEmpty ? textContent : null,
      // Responses API (DeepSeek) requires the assistant's CoT to be
      // passed back on tool-call rounds — without it the API 400s
      // ("The reasoning_text in the thinking mode must be passed back
      // to the API"). This is the in-agentic-loop message ChatService
      // adds on rounds 2+, so it bypasses buildApiMessages; carry the
      // reasoning here or the follow-up request dies on round 2.
      if (wireFamily == WireFamily.responsesApi && reasoningContent.isNotEmpty)
        'reasoning_content': reasoningContent,
      'tool_calls': toolCalls,
    };
  }

  List<Map<String, dynamic>> getApiToolDefinitions() {
    return _registry.toApiTools();
  }

  static List<ToolCall> parseToolUseFromChunks(List<LlmChunk> chunks) {
    final groups = <int, _ToolCallAccum>{};

    for (final chunk in chunks) {
      if (chunk.toolUse != null) {
        final tu = chunk.toolUse!;
        final idx = tu.index;
        final acc = groups.putIfAbsent(idx, () => _ToolCallAccum());
        if (tu.callId.isNotEmpty) acc.callId = tu.callId;
        if (tu.name.isNotEmpty) acc.name = tu.name;
        acc.inputBuffer.write(tu.inputDelta);
      }
    }

    final calls = <ToolCall>[];
    for (final idx in groups.keys.toList()..sort()) {
      final acc = groups[idx]!;
      if (acc.callId == null || acc.name == null) continue;
      Map<String, dynamic> input = {};
      String? parseError;
      try {
        final raw = acc.inputBuffer.toString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            input = decoded;
          } else {
            parseError =
                'Tool input must be a JSON object, got ${decoded.runtimeType}';
          }
        }
      } catch (e) {
        parseError = 'Failed to parse tool input JSON: $e';
      }
      calls.add(
        ToolCall(
          callId: acc.callId!,
          name: acc.name!,
          input: input,
          parseError: parseError,
        ),
      );
    }
    return calls;
  }

  static String? parseFinishReason(List<LlmChunk> chunks) {
    for (final chunk in chunks) {
      if (chunk.finishReason != null) {
        final reason = chunk.finishReason!;
        if (reason == 'tool_use' || reason == 'tool_calls') return 'tool_use';
        if (reason == 'end_turn' || reason == 'stop') return 'stop';
        if (reason == 'done') return 'done';
        return reason;
      }
    }
    return null;
  }
}

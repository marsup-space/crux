import 'dart:convert';

import '../models/provider_config.dart';
import '../storage/session_store.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import 'llm_client.dart';

/// Minimum byte size (utf-8) before a LargePayloadTool's argument
/// is off-loaded to the `offloaded_content` table and replaced in
/// the conversation log with a stand-in pointer. 2 KB is a
/// reasonable default: small enough to skip trivial content,
/// large enough to catch the common case (a typical source-file
/// edit is well over 2 KB).
const int offloadThresholdBytes = 2048;

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
  final SessionStore _store;

  ToolExecutor(this._registry, this._store);

  ToolDef? lookupTool(String name) => _registry.lookup(name);

  Future<ToolResult> executeTool(ToolCall call, ToolContext ctx) async {
    if (call.parseError != null) {
      return ToolResult.error(call.parseError!);
    }
    final tool = _registry.lookup(call.name);
    if (tool == null) {
      return ToolResult.error('Unknown tool: ${call.name}');
    }
    return tool.execute(call.input, ctx);
  }

  /// Return a [ToolCall] whose `input` map is safe to persist into
  /// the conversation log. If [call] is for a [LargePayloadTool]
  /// and any of its declared offloadable args exceeds
  /// [offloadThresholdBytes] bytes (utf-8), the full value is
  /// written to `offloaded_content` keyed by `(sessionId, callId)`
  /// and replaced in the returned call's input with a stand-in
  /// pointer `[N lines, B bytes; recall: <callId>]`.
  ///
  /// The original [call] is left unchanged so the tool itself
  /// still receives the full content when it runs.
  Future<ToolCall> compressCallForPersistence(
    ToolCall call,
    int sessionId,
  ) async {
    final tool = _registry.lookup(call.name);
    if (tool is! LargePayloadTool) return call;

    var modified = false;
    var newInput = call.input;
    for (final argKey in tool.offloadableArgs) {
      final value = newInput[argKey];
      if (value is! String) continue;
      final bytes = utf8.encode(value);
      if (bytes.length < offloadThresholdBytes) continue;

      final lineCount = '\n'.allMatches(value).length + 1;
      final compositeKey = '${call.callId}_$argKey';
      await _store.saveOffloadedContent(
        sessionId: sessionId,
        callId: compositeKey,
        toolName: call.name,
        byteSize: bytes.length,
        lineCount: lineCount,
        content: value,
      );
      newInput = Map<String, dynamic>.from(newInput);
      newInput[argKey] =
          '[$lineCount lines, ${_formatBytes(bytes.length)}]';
      modified = true;
    }

    if (!modified) return call;
    return ToolCall(
      callId: call.callId,
      name: call.name,
      input: newInput,
      parseError: call.parseError,
    );
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
            parseError = 'Tool input must be a JSON object, got ${decoded.runtimeType}';
          }
        }
      } catch (e) {
        parseError = 'Failed to parse tool input JSON: $e';
      }
      calls.add(ToolCall(
        callId: acc.callId!,
        name: acc.name!,
        input: input,
        parseError: parseError,
      ));
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

String _formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}

import 'dart:convert';

import '../models/provider_config.dart';
import '../storage/session_store.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
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
  /// and replaced in the returned call's input with an
  /// unambiguous stand-in pointer (see [_buildOffloadStandIn]).
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
      newInput[argKey] = _buildOffloadStandIn(
        callId: call.callId,
        argKey: argKey,
        lineCount: lineCount,
        bytes: bytes.length,
      );
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

/// Build the stand-in pointer that replaces a large offloadable
/// argument in the persisted tool_call.
///
/// The pointer is visible to the LLM in the conversation history
/// (it's the value of the argument on the next turn) and on rare
/// occasions the LLM has pasted it into a subsequent `edit` /
/// `write` `oldString` / `newString` / `content`, polluting the
/// file. The format is therefore designed to NOT look like a
/// numbered line of source code (the `read` tool prefixes each
/// line with `N: `, so a stand-in starting with `[\d+` is
/// visually adjacent to that prefix and gets mis-copied).
///
/// Two properties that make the pointer robust against that bug:
///
/// 1. It does not start with `[\d+`. It starts with the literal
///    word `offloaded` so the LLM can recognize it as
///    meta-content, not as a line of code.
///
/// 2. It includes the composite key (`<callId>_<argKey>`) of the
///    row in `offloaded_content` where the full bytes live, so
///    the LLM has the information it needs to recover the bytes
///    via the `recall` tool. (The previous format omitted this
///    and the LLM had no way to know how to recover.)
String _buildOffloadStandIn({
  required String callId,
  required String argKey,
  required int lineCount,
  required int bytes,
}) {
  final compositeKey = '${callId}_$argKey';
  return '[offloaded: $lineCount lines / ${_formatBytes(bytes)}; '
      'recall via offloaded_content(key="$compositeKey")]';
}

import 'dart:convert';

import '../models/provider_config.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import 'llm_client.dart';

class ToolCall {
  final String callId;
  final String name;
  final Map<String, dynamic> input;

  const ToolCall({
    required this.callId,
    required this.name,
    required this.input,
  });
}

class _ToolCallAccum {
  String? callId;
  String? name;
  final StringBuffer inputBuffer = StringBuffer();
}

class ToolExecutor {
  final ToolRegistry _registry;

  ToolExecutor(this._registry);

  ToolDef? lookupTool(String name) => _registry.lookup(name);

  Future<ToolResult> executeTool(ToolCall call, ToolContext ctx) async {
    final tool = _registry.lookup(call.name);
    if (tool == null) {
      return ToolResult.error('Unknown tool: ${call.name}');
    }
    return tool.execute(call.input, ctx);
  }

  Map<String, dynamic> formatToolResultForApi(
    ToolCall call,
    ToolResult result,
    ProviderType providerType,
  ) {
    if (providerType == ProviderType.anthropic) {
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
    ProviderType providerType,
  ) {
    if (providerType == ProviderType.anthropic) {
      final content = <Map<String, dynamic>>[];
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
      try {
        final raw = acc.inputBuffer.toString();
        if (raw.isNotEmpty) {
          input = jsonDecode(raw) as Map<String, dynamic>;
        }
      } catch (_) {}
      calls.add(ToolCall(callId: acc.callId!, name: acc.name!, input: input));
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

import '../llm_provider.dart';

class DeepSeekProvider extends LlmProvider {
  @override
  String get name => 'deepseek';

  @override
  String mapEffort(String? effort) {
    switch (effort) {
      case 'normal':
        return 'high';
      case 'high':
        return 'xhigh';
      case 'max':
        return 'max';
      default:
        return 'high';
    }
  }

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    List<Map<String, dynamic>>? tools,
  }) {
    return {
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'thinking': {'type': thinkingMode},
      if (thinkingMode != 'disabled' && reasoningEffort != null)
        'reasoning_effort': mapEffort(reasoningEffort),
      if (tools != null && tools.isNotEmpty)
        'tools': tools
            .map(
              (t) => {
                'type': 'function',
                'function': {
                  'name': t['name'],
                  'description': t['description'],
                  'parameters': t['parameters'],
                },
              },
            )
            .toList(),
    };
  }
}

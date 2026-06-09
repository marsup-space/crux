import '../../models/provider_config.dart';
import '../llm_provider.dart';

class OpenAICompatibleProvider extends LlmProvider {
  @override
  String get name => 'openai_compatible';

  @override
  WireFamily get wire => WireFamily.openaiCompatible;

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    return {
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'thinking': {'type': thinkingMode},
      if (thinkingMode != 'disabled' && reasoningEffort != null)
        'reasoning_effort': mapEffort(reasoningEffort),
      if (maxTokens != null) 'max_completion_tokens': maxTokens,
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
      if (userId != null) 'user_id': userId,
    };
  }

  String mapEffort(String? effort) {
    switch (effort) {
      case 'normal':
        return 'high';
      case 'high':
        return 'high';
      case 'max':
        return 'max';
      default:
        return 'high';
    }
  }
}

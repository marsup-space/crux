import '../models/provider_config.dart';
import 'providers/deepseek_provider.dart';

abstract class LlmProvider {
  String get name;

  String mapEffort(String? effort);

  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, String>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
  });
}

class OpenAiProvider extends LlmProvider {
  @override
  String get name => 'openai';

  @override
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

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, String>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
  }) {
    return {
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'thinking': {'type': thinkingMode},
      if (thinkingMode != 'disabled' && reasoningEffort != null)
        'reasoning_effort': mapEffort(reasoningEffort),
    };
  }
}

class AnthropicProvider extends LlmProvider {
  @override
  String get name => 'anthropic';

  @override
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

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, String>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
  }) {
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final body = <String, dynamic>{
      'model': modelId,
      'messages': chatMsgs,
      'max_tokens': 16384,
      'stream': true,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = systemMsg.map((m) => m['content']).join('\n');
    }
    if (thinkingMode == 'enabled') {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget ?? 10000,
      };
    }
    return body;
  }
}

LlmProvider providerFor(String providerName, ProviderType providerType) {
  if (providerName == 'deepseek') return DeepSeekProvider();
  if (providerType == ProviderType.anthropic) return AnthropicProvider();
  return OpenAiProvider();
}

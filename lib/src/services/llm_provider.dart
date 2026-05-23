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
  }) {
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final body = <String, dynamic>{
      'model': modelId,
      'messages': chatMsgs,
      'max_tokens': 8192,
      'stream': true,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = systemMsg.map((m) => m['content']).join('\n');
    }
    body['thinking'] = {'type': thinkingMode};
    if (thinkingMode != 'disabled' && reasoningEffort != null) {
      body['reasoning_effort'] = mapEffort(reasoningEffort);
    }
    return body;
  }
}

LlmProvider providerFor(String providerName, ProviderType providerType) {
  if (providerName == 'deepseek') return DeepSeekProvider();
  if (providerType == ProviderType.anthropic) return AnthropicProvider();
  return OpenAiProvider();
}

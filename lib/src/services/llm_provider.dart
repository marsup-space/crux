import '../models/provider_config.dart';
import 'providers/deepseek_provider.dart';
import 'providers/minimax_provider.dart';

abstract class LlmProvider {
  String get name;

  WireFamily get wire;
  AuthStyle get authStyle;

  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
  });
}

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

class AnthropicCompatibleProvider extends LlmProvider {
  @override
  String get name => 'anthropic_compatible';

  @override
  WireFamily get wire => WireFamily.anthropicCompatible;

  @override
  AuthStyle get authStyle => AuthStyle.anthropicApiKey;

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
  }) {
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final body = <String, dynamic>{
      'model': modelId,
      'messages': chatMsgs,
      'max_tokens': maxTokens ?? 16384,
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
      // Anthropic-compatible endpoints (Claude 4.6+, MiniMax, ...) accept
      // a sibling `output_config.effort` to steer reasoning depth. The
      // base provider doesn't know whether the target model supports
      // adaptive thinking, so we keep the legacy `enabled`+`budget_tokens`
      // shape and only add the effort knob when the caller asked for one.
      // Subclasses that switch to `adaptive` thinking (e.g. MiniMaxProvider)
      // are responsible for emitting `output_config` themselves.
      if (reasoningEffort != null) {
        body['output_config'] = {
          'effort': mapEffort(reasoningEffort),
        };
      }
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => ({
              'name': t['name'],
              'description': t['description'],
              'input_schema': t['parameters'] as Map<String, dynamic>,
            }),
          )
          .toList();
    }
    return body;
  }

  /// Translate Crux's user-facing preset vocabulary to the Anthropic
  /// `output_config.effort` enum (`low|medium|high|max`).
  ///
  /// Crux stores `off|normal|high|max` in session/runtime state. The
  /// `off` value is handled upstream by `thinkingMode` and shouldn't
  /// reach this helper; we still treat it defensively. `null` falls
  /// back to `'medium'`, matching the `?? 'normal'` default applied
  /// upstream in `chat_service.dart`.
  String mapEffort(String? effort) {
    switch (effort) {
      case 'low':
        return 'low';
      case 'normal':
      case 'medium':
        return 'medium';
      case 'high':
        return 'high';
      case 'max':
        return 'max';
      default:
        return 'medium';
    }
  }
}

class ResolvedProvider {
  final LlmProvider provider;
  final WireFamily wire;
  final AuthStyle authStyle;

  const ResolvedProvider({
    required this.provider,
    required this.wire,
    required this.authStyle,
  });
}

ResolvedProvider resolveProvider(String type) {
  switch (type) {
    case 'openai_compatible':
      return ResolvedProvider(
        provider: OpenAICompatibleProvider(),
        wire: WireFamily.openaiCompatible,
        authStyle: AuthStyle.bearer,
      );
    case 'anthropic_compatible':
      return ResolvedProvider(
        provider: AnthropicCompatibleProvider(),
        wire: WireFamily.anthropicCompatible,
        authStyle: AuthStyle.anthropicApiKey,
      );
    case 'deepseek':
      return ResolvedProvider(
        provider: DeepSeekProvider(),
        wire: WireFamily.openaiCompatible,
        authStyle: AuthStyle.bearer,
      );
    case 'minimax':
      return ResolvedProvider(
        provider: MiniMaxProvider(),
        wire: WireFamily.anthropicCompatible,
        authStyle: AuthStyle.bearer,
      );
    default:
      throw ArgumentError(
        'Unknown provider type "$type". Known types: '
        '${knownProviderTypes().join(", ")}. To add a new type, register a '
        'case in resolveProvider() in llm_provider.dart.',
      );
  }
}

List<String> knownProviderTypes() => [
      'openai_compatible',
      'anthropic_compatible',
      'deepseek',
      'minimax',
    ];

String typeDisplayName(String type) {
  switch (type) {
    case 'openai_compatible':
      return 'OpenAI Compatible';
    case 'anthropic_compatible':
      return 'Anthropic Compatible';
    case 'deepseek':
      return 'DeepSeek';
    case 'minimax':
      return 'MiniMax';
    default:
      return type;
  }
}

LlmProvider providerFor(ProviderConfig config) =>
    resolveProvider(config.type).provider;

import '../models/provider_config.dart';
import 'providers/deepseek_provider.dart';

abstract class LlmProvider {
  String get name;

  String mapEffort(String? effort);

  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    List<Map<String, dynamic>>? tools,
  });
}

class OpenAiProvider extends LlmProvider {
  @override
  String get name => 'openai_compatible';

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

class AnthropicProvider extends LlmProvider {
  @override
  String get name => 'anthropic_compatible';

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
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    List<Map<String, dynamic>>? tools,
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
}

/// The result of resolving a TOML `type` string: a concrete [LlmProvider]
/// implementation plus the [WireFamily] it speaks.
class ResolvedProvider {
  final LlmProvider provider;
  final WireFamily wire;

  const ResolvedProvider({required this.provider, required this.wire});
}

/// Resolves a TOML `type` string to a concrete provider + wire family.
///
/// To add a new provider with custom request body quirks, add a case here
/// and reference a new `LlmProvider` subclass. The provider is reachable
/// from the TOML by its `type = "<value>"` key.
///
/// Generic types (`openai_compatible`, `anthropic_compatible`) always work
/// for any endpoint that speaks the standard protocol — no code change
/// required to point crux at a new compatible service.
///
/// Throws [ArgumentError] for unknown types. The error message lists the
/// currently registered types so the user knows what's available.
ResolvedProvider resolveProvider(String type) {
  switch (type) {
    // ── Generic wire families — no custom request body needed ──
    case 'openai_compatible':
      return ResolvedProvider(
        provider: OpenAiProvider(),
        wire: WireFamily.openaiCompatible,
      );
    case 'anthropic_compatible':
      return ResolvedProvider(
        provider: AnthropicProvider(),
        wire: WireFamily.anthropicCompatible,
      );

    // ── Specific providers with custom request body quirks ──
    case 'deepseek':
      return ResolvedProvider(
        provider: DeepSeekProvider(),
        wire: WireFamily.openaiCompatible,
      );

    default:
      throw ArgumentError(
        'Unknown provider type "$type". Known types: '
        '${knownProviderTypes().join(", ")}. To add a new type, register a '
        'case in resolveProvider() in llm_provider.dart.',
      );
  }
}

/// Returns the list of currently registered provider type strings.
///
/// Useful for the wizard's type-selector dropdown — present a live list
/// of what's available without hardcoding the same strings in two places.
List<String> knownProviderTypes() => [
  'openai_compatible',
  'anthropic_compatible',
  'deepseek',
];

/// Human-readable display name for a TOML `type` value.
///
/// Falls back to the raw string for unknown types so user-typed values
/// still render legibly in the UI.
String typeDisplayName(String type) {
  switch (type) {
    case 'openai_compatible':
      return 'OpenAI Compatible';
    case 'anthropic_compatible':
      return 'Anthropic Compatible';
    case 'deepseek':
      return 'DeepSeek';
    default:
      return type;
  }
}

/// Default endpoint URL for a given type, if the user hasn't typed one.
///
/// Used by the wizard as a placeholder / reset value.
String? defaultEndpointFor(String type) {
  switch (type) {
    case 'openai_compatible':
      return 'https://api.openai.com/v1';
    case 'anthropic_compatible':
      return 'https://api.anthropic.com/v1';
    case 'deepseek':
      return 'https://api.deepseek.com/v1';
    default:
      return null;
  }
}

/// Returns the [LlmProvider] for a loaded [ProviderConfig].
///
/// Shorthand for `resolveProvider(config.type).provider` — used by the
/// HTTP client to build request bodies.
LlmProvider providerFor(ProviderConfig config) =>
    resolveProvider(config.type).provider;

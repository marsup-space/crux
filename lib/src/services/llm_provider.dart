import '../models/provider_config.dart';
import 'providers/anthropic_compatible_provider.dart';
import 'providers/deepseek_provider.dart';
import 'providers/minimax_provider.dart';
import 'providers/openai_compatible_provider.dart';

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
    String? userId,
  });
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

import '../models/provider_config.dart';
import 'providers/anthropic_compatible_provider.dart';
import 'providers/deepseek_provider.dart';
import 'providers/minimax_provider.dart';
import 'providers/openai_compatible_provider.dart';

/// A reasoning preset exposed to the user in the UI and `/think` command.
///
/// Each preset has an [internalValue] (stored in the database, passed to
/// `buildRequestBody`) and a [displayLabel] (shown in buttons, toasts,
/// message bubbles). Providers can override the default mapping — e.g.
/// MiniMax maps `normal` to `adaptive` because it emits
/// `{type: "adaptive"}` for that effort level.
class ReasoningPreset {
  final String internalValue;
  final String displayLabel;

  const ReasoningPreset({
    required this.internalValue,
    required this.displayLabel,
  });

  /// Convenience: when display label equals internal value.
  const ReasoningPreset.same(String value)
      : internalValue = value,
        displayLabel = value;

  @override
  String toString() => 'ReasoningPreset($internalValue → $displayLabel)';
}

abstract class LlmProvider {
  String get name;

  WireFamily get wire;

  AuthStyle get authStyle;

  /// Reasoning presets offered by this provider for a given model.
  /// The UI cycle button, `/think` command, and message bubbles all
  /// consume this list. Subclasses override to customize the display
  /// mapping per model (e.g. MiniMax shows `normal` as `adaptive`
  /// only on M3 — M2.x shows it as `normal` because it doesn't
  /// support adaptive thinking).
  List<ReasoningPreset> reasoningPresetsFor(String modelId) => const [
        ReasoningPreset(internalValue: 'off', displayLabel: 'off'),
        ReasoningPreset(internalValue: 'low', displayLabel: 'low'),
        ReasoningPreset(internalValue: 'normal', displayLabel: 'normal'),
        ReasoningPreset(internalValue: 'high', displayLabel: 'high'),
        ReasoningPreset(internalValue: 'max', displayLabel: 'max'),
      ];

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
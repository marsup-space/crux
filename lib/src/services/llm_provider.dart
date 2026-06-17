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

  /// Whether this provider exposes a coding-plan (subscription
  /// usage) endpoint. The toolbar uses this to decide whether
  /// to render a live quota readout next to the metrics.
  ///
  /// Default is `false`. Providers that want a coding-plan
  /// display include the `CodingPlanProvider` mixin (declared
  /// in `services/providers/coding_plan_provider.dart`), which
  /// overrides this getter to `true` and provides the polling
  /// lifecycle.
  bool get isCodingPlan => false;

  /// Reasoning presets for a model, with TOML-driven label overrides applied.
  ///
  /// Resolution priority (highest wins on label conflicts):
  ///   1. Model-level TOML `[models.reasoning_labels]`
  ///   2. Provider-level TOML `[reasoning_labels]`
  ///   3. Custom provider class override of [baseReasoningPresets]
  ///   4. Default five-level scale from [LlmProvider]
  ///
  /// The UI cycle button, `/think` command, and message bubbles all
  /// consume this list.
  List<ReasoningPreset> reasoningPresetsFor(
    String modelId, {
    Map<String, String> providerLabels = const {},
    Map<String, String> modelLabels = const {},
  }) {
    // Start with provider class base presets (levels 3–4)
    var presets = baseReasoningPresets(modelId);

    // Apply provider-level TOML labels (level 2)
    if (providerLabels.isNotEmpty) {
      presets = _applyLabels(presets, providerLabels);
    }

    // Apply model-level TOML labels (level 1 — highest priority)
    if (modelLabels.isNotEmpty) {
      presets = _applyLabels(presets, modelLabels);
    }

    return presets;
  }

  /// Override in subclasses to customize the base preset list before
  /// TOML label overrides are applied. The default returns the standard
  /// five-level scale.
  List<ReasoningPreset> baseReasoningPresets(String modelId) =>
      defaultReasoningPresets;

  /// Apply a label map on top of a preset list. [labels] patches the
  /// base presets:
  ///
  /// - Key present with a label → keep and rename (e.g. `normal = "adaptive"`)
  /// - Key present with `"disabled"` → remove from the list
  /// - Key absent → pass through unchanged
  static List<ReasoningPreset> _applyLabels(
    List<ReasoningPreset> presets,
    Map<String, String> labels,
  ) {
    if (labels.isEmpty) return presets;
    final result = <ReasoningPreset>[];
    for (final p in presets) {
      final override = labels[p.internalValue];
      if (override == null) {
        // Not mentioned — keep as-is
        result.add(p);
      } else if (override == 'disabled') {
        // Explicitly disabled — skip
        continue;
      } else {
        // Renamed — keep with new display label
        result.add(ReasoningPreset(
          internalValue: p.internalValue,
          displayLabel: override,
        ));
      }
    }
    return result;
  }

  /// The default five-level reasoning preset scale.
  static const List<ReasoningPreset> defaultReasoningPresets = [
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
    double temperature = 0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  });

  /// Last-chance hook to mutate the wire-format message list before
  /// it gets sent to the model. Default: no-op (returns [messages]
  /// unchanged).
  ///
  /// Use this to backfill provider-specific required fields that may
  /// be missing from messages produced by other providers — e.g.
  /// when the user switches the session model mid-conversation, the
  /// prior `assistant` messages in the history were serialized by a
  /// different provider's `buildApiMessages` and may lack fields the
  /// new provider requires. The DeepSeek provider, for instance,
  /// needs every prior `assistant` message to include a
  /// `reasoning_content` field when the request is in thinking mode
  /// and a previous turn involved tool calls; see
  /// [DeepSeekProvider.sanitizeMessages].
  ///
  /// The returned list is what gets serialized into the request body.
  /// Implementations should return the original list reference
  /// unchanged when no modifications are needed so callers can invoke
  /// this unconditionally without per-request allocation overhead.
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) => messages;
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
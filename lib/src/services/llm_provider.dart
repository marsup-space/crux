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

  /// Whether this provider exposes a credit-balance endpoint.
  /// The toolbar uses this to decide whether to render a live
  /// credit balance readout next to the metrics.
  ///
  /// Default is `false`. Providers that want a credit-balance
  /// display include the `CreditBalanceProvider` mixin
  /// (declared in
  /// `services/providers/credit_balance_provider.dart`),
  /// which overrides this getter to `true` and provides the
  /// polling lifecycle.
  bool get isCreditBalance => false;

  /// `true` when this provider's wire family is susceptible to
  /// "orphan tool history" errors — a `tool_result` referencing
  /// a `tool_use_id` that doesn't appear in any preceding
  /// assistant `tool_use` — and exposes a DB-side repair that
  /// the chat executor can run and retry once on detection.
  ///
  /// Default `false`. Anthropic-compatible providers override
  /// to `true`: their wire format encodes the pairing inside
  /// content blocks, so the per-request sanitizer in
  /// `AnthropicCompatibleProvider` strips orphans from the wire
  /// payload but doesn't heal the underlying DB — this flag
  /// additionally arms the executor with the storage-side
  /// repair. MiniMax inherits the override and picks up the
  /// `true` value with no MiniMax-specific code.
  ///
  /// Used at exactly one site — the orphan-tool auto-repair
  /// branch in `ChatTurnExecutor.sendMessage` — so the
  /// capability is intentionally scoped narrowly: it doesn't
  /// authorize any other DB-side intervention.
  bool get supportsOrphanToolRepair => false;

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

  /// Default value for the `hint_parallel_calls` toggle, used
  /// when no TOML override is set.
  ///
  /// When `true`, the chat service injects a short in-context
  /// hint into the LLM's next turn whenever the model exhibits
  /// either of two patterns:
  ///
  ///   1. **Praise** — emits ≥2 successful tool calls in a single
  ///      round (positive reinforcement + a user-facing
  ///      `parallel_praise` bubble in the TUI).
  ///   2. **Single-call hint** — emits the same single tool call
  ///      round after round (corrective nudge after
  ///      [defaultHintParallelCallsSingleThreshold] consecutive
  ///      single-tool-call rounds; the user does not see this one).
  ///
  /// The intent of both signals is to fight context-length decay in
  /// long sessions, where the agent tends to forget system-prompt
  /// instructions and regress to one call per turn.
  ///
  /// Subclasses can override this (e.g. a provider whose models
  /// are known to over-batch junk calls might default to `false`).
  /// Per-provider and per-model TOML overrides then take
  /// precedence over the class default — see
  /// [effectiveHintParallelCallsFor].
  bool get defaultHintParallelCalls => true;

  /// Resolve the effective `hint_parallel_calls` value for a
  /// specific (provider, model) pair.
  ///
  /// Resolution order, highest wins:
  ///   1. [modelOverride] — the `[[models]]` `hint_parallel_calls`
  ///      field for this model, if non-null.
  ///   2. [providerOverride] — the provider-level TOML
  ///      `hint_parallel_calls` field, if non-null.
  ///   3. [defaultHintParallelCalls] — the LLM-provider class
  ///      default (`true` unless a subclass overrides).
  ///
  /// Both overrides are nullable bools so `null` (TOML absent) is
  /// distinguishable from `false` (TOML explicit opt-out).
  bool effectiveHintParallelCallsFor({
    bool? modelOverride,
    bool? providerOverride,
  }) {
    if (modelOverride != null) return modelOverride;
    if (providerOverride != null) return providerOverride;
    return defaultHintParallelCalls;
  }

  /// Default value for the `hint_parallel_calls_single_threshold`
  /// setting, used when no TOML override is set.
  ///
  /// After this many consecutive single-tool-call rounds in a row,
  /// the chat service injects the corrective single-call hint into
  /// the LLM's next turn. The default of 10 is empirically the
  /// threshold at which the agent has typically drifted into
  /// serialization during long sessions — shorter and it would
  /// fire on legitimate serial workflows; longer and the drift
  /// compounds before any nudge.
  ///
  /// Setting this to a very large value effectively disables the
  /// single-call hint at the class level (the praise hint on ≥2
  /// calls is unaffected).
  int get defaultHintParallelCallsSingleThreshold => 10;

  /// Resolve the effective `hint_parallel_calls_single_threshold`
  /// value for a specific (provider, model) pair.
  ///
  /// Resolution order, highest wins:
  ///   1. [modelOverride] — the `[[models]]`
  ///      `hint_parallel_calls_single_threshold` field for this
  ///      model, if non-null.
  ///   2. [providerOverride] — the provider-level TOML
  ///      `hint_parallel_calls_single_threshold` field, if non-null.
  ///   3. [defaultHintParallelCallsSingleThreshold] — the
  ///      LLM-provider class default (10 unless a subclass
  ///      overrides).
  ///
  /// Both overrides are nullable ints so `null` (TOML absent) is
  /// distinguishable from `0` (TOML explicit "fire on every
  /// single-tool-call round"). The chat service treats 0 the same
  /// as 1 for the modulo check (`counter % threshold == 0`), so
  /// 0 effectively means "fire every single-tool-call round" —
  /// only useful for testing.
  int effectiveHintParallelCallsSingleThresholdFor({
    int? modelOverride,
    int? providerOverride,
  }) {
    if (modelOverride != null) return modelOverride;
    if (providerOverride != null) return providerOverride;
    return defaultHintParallelCallsSingleThreshold;
  }

  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    /// Nucleus-sampling ceiling in [0.0, 1.0]. Crux's
    /// `chat_turn_executor` derives this from the effective
    /// temperature (see `topPForTemperature`); production callers
    /// always pass an explicit value, and the default of 1.0 just
    /// matches the temp=0 endpoint so existing tests that don't
    /// care about top_p get a harmless full-nucleus body.
    double topP = 1.0,
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
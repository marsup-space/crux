// The convenience resolvers for the parallel-tool-call hint feature live on
// `LlmProvider` (`effectiveHintParallelCallsFor` and
// `effectiveHintParallelCallsSingleThresholdFor`) rather than on
// `ProviderConfig`, because pulling `LlmProvider` into the `models/`
// package would create a `models` → `services` → `models` import
// cycle (`llm_provider.dart` already imports `models/provider_config.dart`).
// Call sites that have both the config and the LLM pass the
// provider's `hintParallelCalls` and the model's
// `hintParallelCalls` to the LLM's resolver:
//
//   final on = llm.effectiveHintParallelCallsFor(
//     modelOverride: model.hintParallelCalls,
//     providerOverride: provider.hintParallelCalls,
//   );
//
// The feature was previously named "praise_parallel_calls" — renamed to
// "hint_parallel_calls" because the toggle now governs two signals
// (a positive praise hint and a corrective single-call hint) rather
// than just praise.

/// The HTTP wire family a provider uses — determines URL paths, stream
/// parsing, and message format.
///
/// This is derived from the TOML `type` field via the dispatcher in
/// `llm_provider.dart`. Two providers can share a [WireFamily] (e.g. DeepSeek
/// and a generic OpenAI-compatible endpoint) but have different request
/// bodies — that's what the [LlmProvider] implementation handles.
///
/// - [openaiCompatible] — POST `<base>/v1/chat/completions`, Chat
///   Completions message shape, OpenAI SSE deltas, `data: [DONE]` end.
/// - [anthropicCompatible] — POST `<base>/messages`, Anthropic content-block
///   message shape, Anthropic SSE events with `event:` headers.
/// - [responsesApi] — POST `<base>/responses`, OpenAI Responses API input
///   items, semantic SSE events (`response.output_text.delta`, etc.),
///   no `[DONE]`. Used by DeepSeek's Responses API endpoint.
enum WireFamily { openaiCompatible, anthropicCompatible, responsesApi }

/// How the API key is sent in HTTP headers — independent of [WireFamily].
///
/// Most providers use Bearer tokens regardless of wire protocol.
/// Anthropic's native API uses `x-api-key`, but some Anthropic-compatible
/// providers (like MiniMax) use `Authorization: Bearer` instead.
enum AuthStyle { bearer, anthropicApiKey }

/// Human-readable label for a [WireFamily] (used in UI / logs).
String wireFamilyLabel(WireFamily w) {
  switch (w) {
    case WireFamily.openaiCompatible:
      return 'OpenAI-compatible';
    case WireFamily.anthropicCompatible:
      return 'Anthropic-compatible';
    case WireFamily.responsesApi:
      return 'Responses API';
  }
}

/// Reasoning effort levels for models that support adjustable reasoning.
///
/// Models like OpenAI o1/o3 allow the user to trade off compute vs. speed.
/// `null` (absent in TOML) means the model does not support reasoning effort.
enum ReasoningEffort { low, medium, high, max }

extension ReasoningEffortParse on ReasoningEffort {
  static ReasoningEffort? fromString(String? value) {
    if (value == null) return null;
    switch (value.toLowerCase()) {
      case 'none':
        return null;
      case 'low':
        return ReasoningEffort.low;
      case 'normal': // alias for medium — matches the runtime string used in UI/commands
      case 'medium':
        return ReasoningEffort.medium;
      case 'high':
        return ReasoningEffort.high;
      case 'max':
        return ReasoningEffort.max;
      default:
        throw FormatException('Unknown reasoning effort: "$value"');
    }
  }

  String toConfigString() => name;
}

/// A single model offered by a provider.
///
/// Corresponds to one `[[models]]` entry in the provider TOML file.
class ModelConfig {
  /// The model ID sent in API requests (e.g. "gpt-4o", "claude-3-5-sonnet-20241022").
  final String id;

  /// Human-readable display name (e.g. "GPT-4o", "Claude 3.5 Sonnet").
  final String name;

  /// Maximum context window size in tokens.
  final int contextSize;

  /// Whether the model can accept and process image inputs.
  final bool imageSupport;

  /// Adjustable reasoning effort level, or `null` if the model doesn't
  /// support reasoning effort configuration.
  ///
  /// Models like OpenAI o1/o3 allow low/medium/high reasoning trade-offs.
  /// Defaults to [ReasoningEffort.medium] (exposed as "normal" in the UI)
  /// so that reasoning levels are
  /// available in the UI for any model unless explicitly opted out.
  final ReasoningEffort? reasoningEffort;

  /// Whether the model supports extended "thinking" / chain-of-thought mode.
  ///
  /// For Anthropic models this maps to the `thinking` parameter; for OpenAI
  /// o-series it corresponds to reasoning mode being active.
  /// Defaults to `true` so that thinking controls are shown by default —
  /// set `thinking = false` in the TOML to opt out.
  final bool thinking;

  /// Optional thinking budget in tokens when [thinking] is enabled.
  ///
  /// Some models allow specifying how many tokens the thinking phase may
  /// consume (e.g. Anthropic's `budget_tokens`).
  final int? thinkingBudget;

  /// Maximum output tokens the model can generate per request.
  ///
  /// Maps to `max_tokens` (Anthropic) or `max_completion_tokens` (OpenAI).
  /// When `null`, the provider uses its own default.
  final int? maxTokens;

  final bool streamLerp;

  /// Sampling temperature. Default `0` — deterministic output
  /// suitable for coding agents. Set higher in TOML for creative
  /// tasks.
  ///
  /// **Range depends on the provider:**
  ///   - OpenAI-compatible (and providers that emulate the OpenAI
  ///     Chat Completions shape): `0.0–2.0`.
  ///   - Anthropic-compatible and MiniMax (this repo's
  ///     `AnthropicCompatibleProvider` / `MinimaxProvider`): `0.0–1.0`.
  ///     Values above 1.0 are rejected by the server with a 400.
  ///
  /// The user-facing `/temperature` slash command clamps to the
  /// universal `0.0–1.0` range so the same input works across
  /// providers; this TOML field has no such guard at load time, so
  /// model authors must respect their provider's actual range.
  final double temperature;

  /// Per-model display label overrides for reasoning effort levels.
  ///
  /// Maps internal effort values to user-facing labels. For example,
  /// MiniMax M3 maps `normal` to `adaptive` because its API uses
  /// `{type: "adaptive"}` for that effort level. Any key not present
  /// falls back to the provider's default (identity mapping — show the
  /// internal value as-is).
  ///
  /// Set in TOML as:
  /// ```toml
  /// [models.reasoning_labels]
  /// normal = "adaptive"
  /// ```
  final Map<String, String> reasoningLabels;

  /// Optional per-turn round-trip cap for the agentic tool loop.
  ///
  /// When `null`, falls back to [ProviderConfig.defaultMaxRounds]. When
  /// that is also `null`, the loop is unbounded (no cap). When set to a
  /// positive integer, the loop bails out after that many
  /// model→tool→model round-trips in a single user turn and surfaces a
  /// soft "step limit reached" signal to the UI. `0` is treated the same
  /// as `null` (unbounded).
  final int? maxRounds;

  /// Per-model override for the `hint_parallel_calls` toggle.
  ///
  /// Gates two complementary in-context signals the chat service
  /// can inject into the LLM's next turn:
  ///
  ///   1. **Praise hint** — when the model emits ≥2 successful
  ///      tool calls in a single round, inject a short positive
  ///      note and persist a user-facing `parallel_praise` bubble.
  ///   2. **Single-call hint** — when the model has emitted N
  ///      consecutive single-tool-call rounds (where N comes from
  ///      [hintParallelCallsSingleThreshold]), inject a corrective
  ///      nudge. Not persisted; the user doesn't see it.
  ///
  /// `null` (TOML absent) means "fall through to the provider-level
  /// override, then to the LLM-provider class default". A concrete
  /// `true`/`false` always wins, so a model can opt out explicitly
  /// even if the provider enables it for everyone else.
  final bool? hintParallelCalls;

  /// Per-model override for the single-call hint threshold.
  ///
  /// When the session has accumulated this many consecutive
  /// single-tool-call rounds in a row, the chat service injects
  /// the corrective single-call hint. `null` (TOML absent) falls
  /// through to the provider-level override, then to the
  /// `LlmProvider.defaultHintParallelCallsSingleThreshold` (10).
  ///
  /// Setting this to a very large value effectively disables the
  /// reminder for this model (the praise hint still fires on
  /// rounds with ≥2 calls).
  final int? hintParallelCallsSingleThreshold;

  /// Per-model system-prompt tuning block.
  ///
  /// Rendered as a separate layer in the system prompt, after the
  /// universal `system-prompt.md` and before project notes / env
  /// meta. Use for model-specific quirks the universal prompt
  /// shouldn't carry: parallel-call encouragement for a chatty
  /// model, file-reference style for a model that handles them
  /// poorly, etc.
  ///
  /// `null` (TOML absent) means "fall through to
  /// [ProviderConfig.systemPromptAddition]". A non-null value
  /// here overrides the provider-level value for this model.
  /// If both are `null`, the layer is omitted entirely.
  ///
  /// TOML shape:
  /// ```toml
  /// [models.system_prompt_addition]
  /// ```
  /// or, for short single-block additions:
  /// ```toml
  /// system_prompt_addition = "one-line tuning"
  /// ```
  final String? systemPromptAddition;

  /// Optional ISO date (`yyyy-MM-dd`) after which the model may
  /// disappear from its provider. Populated by the OpenRouter stealth
  /// sync from the catalog's `expiration_date`; `null` = no published
  /// expiry. Informational only — the runtime never blocks a request
  /// on it; the sync surfaces a preview warning once the date is
  /// within [OpenRouterStealthSync.expiryWarningDays].
  final String? expirationDate;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.contextSize,
    this.imageSupport = false,
    this.reasoningEffort = ReasoningEffort.medium,
    this.thinking = true,
    this.thinkingBudget,
    this.maxTokens,
    this.streamLerp = false,
    this.temperature = 0,
    this.reasoningLabels = const {},
    this.maxRounds,
    this.hintParallelCalls,
    this.hintParallelCallsSingleThreshold,
    this.systemPromptAddition,
    this.expirationDate,
  });

  /// The composite key used throughout Crux: `providerName/modelId`.
  String compositeKey(String providerName) => '$providerName/$id';

  @override
  String toString() =>
      'ModelConfig($id, name=$name, ctx=$contextSize, '
      'img=$imageSupport, effort=$reasoningEffort, think=$thinking, '
      'temp=$temperature, maxRounds=$maxRounds, '
      'hintParallelCalls=$hintParallelCalls, '
      'hintParallelCallsSingleThreshold=$hintParallelCallsSingleThreshold, '
      'exp=$expirationDate)';
}

/// Usage quota tier — maps a time window label to a token/request budget.
class UsageQuotaTier {
  final String label; // e.g. "5h", "1w", "1m"
  final int limit;

  const UsageQuotaTier({required this.label, required this.limit});

  @override
  String toString() => 'UsageQuotaTier($label: $limit)';
}

/// Optional coding-plan quota configuration.
///
/// Allows Crux to query an external quota API to check remaining usage
/// before making expensive model calls.
class UsageQuotaConfig {
  /// The API endpoint to query for quota information.
  final String apiUrl;

  /// Named usage tiers, e.g. {"5h": 100, "1w": 500, "1m": 2000}.
  ///
  /// These define how many tokens/requests are budgeted per time window.
  final List<UsageQuotaTier> tiers;

  const UsageQuotaConfig({required this.apiUrl, required this.tiers});

  @override
  String toString() => 'UsageQuotaConfig(url=$apiUrl, tiers=$tiers)';
}

/// Top-level provider configuration, loaded from a single TOML file.
///
/// The filename (without `.toml`) serves as the provider name, e.g.
/// `openai.toml` → provider name `"openai"`.
///
/// The `type` field is a free-form string that selects a registered
/// `LlmProvider` implementation. Two flavors of values are supported:
///
/// - **Generic**: `"openai_compatible"`, `"anthropic_compatible"`. These
///   work for any endpoint that speaks the standard wire protocol — pick
///   one of these to point crux at a new compatible service without
///   recompiling.
/// - **Specific**: `"deepseek"`, and any other provider with custom request
///   body quirks. These are registered in `llm_provider.dart`'s
///   `resolveProvider()` dispatcher and require a rebuild to add new ones.
///
/// Example TOML:
/// ```toml
/// type = "openai_compatible"
/// endpoint_url = "https://api.openai.com/v1"
///
/// [[models]]
/// id = "gpt-4o"
/// name = "GPT-4o"
/// context_size = 128000
/// image_support = true
/// thinking = false
///
/// [[models]]
/// id = "o1"
/// name = "o1"
/// context_size = 200000
/// image_support = false
/// reasoning_effort = "medium"
/// thinking = true
/// thinking_budget = 10000
///
/// [quota]
/// api_url = "https://api.openai.com/v1/quota"
///
/// [quota.usage]
/// "5h" = 100
/// "1w" = 500
/// "1m" = 2000
/// ```
class ProviderConfig {
  /// Provider name derived from the TOML filename (sans extension).
  final String name;

  /// The TOML `type` value — the dispatch key into the LlmProvider registry.
  ///
  /// Always one of the values accepted by `resolveProvider()`. If the TOML
  /// contains an unknown type, the loader records a load error and skips
  /// the file.
  final String type;

  /// The HTTP wire family (URL paths, auth headers, stream parsing).
  /// Derived from [type] by the loader.
  final WireFamily wireFamily;

  /// The base endpoint URL for API calls.
  final String endpointUrl;

  /// Models available under this provider.
  final List<ModelConfig> models;

  /// Optional coding-plan quota configuration.
  final UsageQuotaConfig? quota;

  /// Provider-level display label overrides for reasoning effort levels.
  ///
  /// Applies to all models under this provider unless overridden by a
  /// model-level [ModelConfig.reasoningLabels]. Set in TOML as:
  /// ```toml
  /// [reasoning_labels]
  /// normal = "adaptive"
  /// ```
  final Map<String, String> reasoningLabels;

  /// Provider-level default cap on model→tool→model round-trips per
  /// user turn. Used when a [[models]] entry's [ModelConfig.maxRounds]
  /// is `null`. `null` (or `0`) means unbounded — the agentic loop is
  /// not interrupted by a step cap.
  final int? defaultMaxRounds;

  /// Provider-level override for the `hint_parallel_calls` toggle.
  ///
  /// Gates two complementary in-context signals the chat service
  /// can inject into the LLM's next turn: the praise hint (on
  /// rounds with ≥2 successful tool calls) and the single-call
  /// hint (after enough consecutive single-tool-call rounds).
  /// Setting this to `false` disables both signals for every model
  /// under this provider.
  ///
  /// `null` (TOML absent) means "fall through to the LLM-provider
  /// class default". A concrete `true`/`false` always wins at the
  /// provider level — per-model overrides take precedence over
  /// this. See [LlmProvider.effectiveHintParallelCallsFor] for the
  /// full resolution order.
  final bool? hintParallelCalls;

  /// Provider-level default for the single-call hint threshold.
  ///
  /// When the session has accumulated this many consecutive
  /// single-tool-call rounds in a row, the chat service injects
  /// the corrective single-call hint. `null` (TOML absent) falls
  /// through to the
  /// `LlmProvider.defaultHintParallelCallsSingleThreshold` (10).
  /// Per-model overrides take precedence.
  final int? hintParallelCallsSingleThreshold;

  /// Provider-level system-prompt tuning block, applied to every
  /// model under this provider that does not define its own
  /// [ModelConfig.systemPromptAddition].
  ///
  /// Use this for tuning that holds across an entire provider
  /// (e.g. "all DeepSeek models prefer explicit `path:line`
  /// references"). For model-specific quirks, override at the
  /// model level. If both are null, the layer is omitted
  /// entirely.
  final String? systemPromptAddition;

  /// Provider-level override for the stream idle watchdog (ms).
  ///
  /// The LlmClient resets an idle timer on every chunk; if no chunk
  /// (or, for Anthropic, `event: ping`) arrives within this window,
  /// the stream is considered stalled and is closed with a
  /// `LlmErrorKind.timeout` chunk. `null` (TOML absent) keeps the
  /// hardcoded default of 120_000 ms (2 min).
  ///
  /// Some models produce very long reasoning passes with no
  /// intermediate content chunks (the whole pass lands as one big
  /// thinking block at the end). For those, raise this — e.g. LongCat
  /// uses 10 min by default. The chunk-reset logic still fires on
  /// any byte that arrives, so this only governs the *worst-case*
  /// silence between chunks, not the total stream duration (see
  /// [streamMaxDurationMs] for that).
  final int? streamIdleTimeoutMs;

  /// Provider-level override for the total stream max duration (ms).
  ///
  /// Hard wall-clock cap on a single stream from request start to
  /// final chunk. Once this fires, the stream is closed with a
  /// `LlmErrorKind.timeout` chunk. `null` (TOML absent) keeps the
  /// hardcoded default of 600_000 ms (10 min, matching Anthropic's
  /// own streaming recommendation).
  ///
  /// Set this for models with reasoning phases that can exceed 10
  /// min in aggregate (thinking + final answer), e.g. LongCat uses
  /// 30 min by default.
  final int? streamMaxDurationMs;

  const ProviderConfig({
    required this.name,
    required this.type,
    required this.wireFamily,
    required this.endpointUrl,
    required this.models,
    this.quota,
    this.reasoningLabels = const {},
    this.defaultMaxRounds,
    this.hintParallelCalls,
    this.hintParallelCallsSingleThreshold,
    this.systemPromptAddition,
    this.streamIdleTimeoutMs,
    this.streamMaxDurationMs,
  });

  /// Resolve the effective system-prompt tuning block for a model.
  ///
  /// Precedence: [ModelConfig.systemPromptAddition] (per-model) →
  /// [ProviderConfig.systemPromptAddition] (per-provider) → `null`.
  ///
  /// The caller should treat a `null` return as "omit this layer
  /// entirely" — no placeholder text.
  String? effectiveSystemPromptAdditionFor(ModelConfig model) {
    return model.systemPromptAddition ?? systemPromptAddition;
  }

  /// Convenience: look up a model by its [ModelConfig.id].
  ModelConfig? modelById(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Convenience: look up a model by its composite key `"providerName/modelId"`.
  ///
  /// The model ID itself may contain slashes (e.g. OpenRouter's
  /// `anthropic/claude-sonnet-4`), so we split on the FIRST slash only.
  ModelConfig? modelByCompositeKey(String key) {
    final slashIdx = key.indexOf('/');
    if (slashIdx <= 0) return null;
    if (key.substring(0, slashIdx) != name) return null;
    return modelById(key.substring(slashIdx + 1));
  }

  /// All composite keys for models under this provider.
  List<String> compositeKeys() =>
      models.map((m) => m.compositeKey(name)).toList();

  /// Whether any model under this provider supports image inputs.
  bool hasImageSupport() => models.any((m) => m.imageSupport);

  /// Resolve the effective per-turn round-trip cap for a specific model.
  ///
  /// Precedence: [ModelConfig.maxRounds] (per-model override) →
  /// [defaultMaxRounds] (provider-level) → `null` (unbounded).
  ///
  /// Returns `null` if neither is set, or if the resolved value is `0`
  /// (treated as "no cap"). Returns a positive integer otherwise.
  int? effectiveMaxRoundsFor(ModelConfig model) {
    final fromModel = model.maxRounds;
    if (fromModel != null && fromModel > 0) return fromModel;
    if (defaultMaxRounds != null && defaultMaxRounds! > 0)
      return defaultMaxRounds;
    return null;
  }

  @override
  String toString() =>
      'ProviderConfig($name, type=$type, wire=$wireFamily, '
      'endpoint=$endpointUrl, models=${models.length}, quota=$quota, '
      'defaultMaxRounds=$defaultMaxRounds, '
      'hintParallelCalls=$hintParallelCalls, '
      'hintParallelCallsSingleThreshold=$hintParallelCallsSingleThreshold, '
      'streamIdleTimeoutMs=$streamIdleTimeoutMs, '
      'streamMaxDurationMs=$streamMaxDurationMs)';
}

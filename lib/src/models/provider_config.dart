/// The API protocol family a provider uses.
///
/// This determines how requests are formatted and responses are parsed.
enum ProviderType { openai, anthropic }

/// Extension to parse [ProviderType] from TOML string values.
extension ProviderTypeParse on ProviderType {
  /// Parse a provider type string from config.
  ///
  /// Accepts: "openai", "anthropic".
  /// Throws [FormatException] for unknown values.
  static ProviderType fromString(String value) {
    switch (value.toLowerCase()) {
      case 'openai':
        return ProviderType.openai;
      case 'anthropic':
        return ProviderType.anthropic;
      default:
        throw FormatException('Unknown provider type: "$value"');
    }
  }

  /// Serialize back to the TOML-friendly string.
  String toConfigString() => name;
}

/// Reasoning effort levels for models that support adjustable reasoning.
///
/// Models like OpenAI o1/o3 allow the user to trade off compute vs. speed.
/// `null` (absent in TOML) means the model does not support reasoning effort.
enum ReasoningEffort { low, medium, high }

extension ReasoningEffortParse on ReasoningEffort {
  static ReasoningEffort? fromString(String? value) {
    if (value == null) return null;
    switch (value.toLowerCase()) {
      case 'low':
        return ReasoningEffort.low;
      case 'medium':
        return ReasoningEffort.medium;
      case 'high':
        return ReasoningEffort.high;
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
  final ReasoningEffort? reasoningEffort;

  /// Whether the model supports extended "thinking" / chain-of-thought mode.
  ///
  /// For Anthropic models this maps to the `thinking` parameter; for OpenAI
  /// o-series it corresponds to reasoning mode being active.
  final bool thinking;

  /// Optional thinking budget in tokens when [thinking] is enabled.
  ///
  /// Some models allow specifying how many tokens the thinking phase may
  /// consume (e.g. Anthropic's `budget_tokens`).
  final int? thinkingBudget;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.contextSize,
    this.imageSupport = false,
    this.reasoningEffort,
    this.thinking = false,
    this.thinkingBudget,
  });

  /// The composite key used throughout Crux: `providerName/modelId`.
  String compositeKey(String providerName) => '$providerName/$id';

  @override
  String toString() =>
      'ModelConfig($id, name=$name, ctx=$contextSize, '
      'img=$imageSupport, effort=$reasoningEffort, think=$thinking)';
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
/// Example TOML:
/// ```toml
/// type = "openai"
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

  /// Which API protocol family this provider uses.
  final ProviderType type;

  /// The base endpoint URL for API calls.
  final String endpointUrl;

  /// Models available under this provider.
  final List<ModelConfig> models;

  /// Optional coding-plan quota configuration.
  final UsageQuotaConfig? quota;

  const ProviderConfig({
    required this.name,
    required this.type,
    required this.endpointUrl,
    required this.models,
    this.quota,
  });

  /// Convenience: look up a model by its [ModelConfig.id].
  ModelConfig? modelById(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Convenience: look up a model by its composite key `"providerName/modelId"`.
  ModelConfig? modelByCompositeKey(String key) {
    final parts = key.split('/');
    if (parts.length != 2 || parts[0] != name) return null;
    return modelById(parts[1]);
  }

  /// All composite keys for models under this provider.
  List<String> compositeKeys() =>
      models.map((m) => m.compositeKey(name)).toList();

  /// Whether any model under this provider supports image inputs.
  bool hasImageSupport() => models.any((m) => m.imageSupport);

  @override
  String toString() =>
      'ProviderConfig($name, type=$type, '
      'endpoint=$endpointUrl, models=${models.length}, quota=$quota)';
}

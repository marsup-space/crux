import 'dart:io';
import 'package:toml/toml.dart';
import '../models/provider_config.dart';
import 'llm_provider.dart';
import 'provider_seeder.dart';

/// Loads and manages provider configuration files from TOML directories.
///
/// Each provider is defined by a single `.toml` file in one of the
/// configured search directories. The filename (sans `.toml`) becomes
/// the provider name, e.g. `openai.toml` → provider `"openai"`.
///
/// Multiple search directories are supported — typically a read-only
/// built-in dir (shipped with the binary) plus a writable per-user
/// dir (e.g. `~/.config/crux/providers/`). Earlier entries in the
/// list take precedence on name collisions, so the user dir should
/// be listed first to allow overriding built-ins.
///
/// Usage:
/// ```dart
/// final loader = ProviderConfigLoader(
///   providersDirs: [
///     Directory('~/.config/crux/providers'),
///     Directory('providers'),  // built-in
///   ],
/// );
/// await loader.loadAll();
/// final openai = loader.providerByName('openai');
/// final gpt4o = loader.modelByCompositeKey('openai/gpt-4o');
/// ```
class ModelEntry {
  final String compositeKey;
  final String providerName;
  final ModelConfig model;
  const ModelEntry({
    required this.compositeKey,
    required this.providerName,
    required this.model,
  });
}

class ProviderConfigLoader {
  /// The directories searched for `.toml` provider config files, in
  /// precedence order (earlier wins on name collisions).
  final List<Directory> providersDirs;

  /// Loaded configs keyed by provider name.
  final Map<String, ProviderConfig> _configs = {};

  /// Ordered list of provider names as they were loaded (for stable iteration).
  final List<String> _loadOrder = [];

  /// Any errors encountered during loading, keyed by filename.
  final Map<String, String> _errors = {};

  /// Convenience: search a single directory. Use [providersDirs] for
  /// multi-dir precedence.
  ProviderConfigLoader({required Directory providersDir})
    : providersDirs = [providersDir];

  /// Search multiple directories, earlier entries win on collisions.
  ProviderConfigLoader.multi({required this.providersDirs});

  /// Whether any configs have been loaded.
  bool get isLoaded => _configs.isNotEmpty;

  /// All loaded provider names in load order.
  List<String> providerNames() => List.unmodifiable(_loadOrder);

  /// All loaded configs in load order.
  List<ProviderConfig> providers() =>
      _loadOrder.map((n) => _configs[n]!).toList();

  /// All models across all providers, as composite keys.
  List<String> allModelKeys() =>
      providers().expand((p) => p.compositeKeys()).toList();

  /// All models across all providers with full metadata.
  List<ModelEntry> allModelEntries() {
    final entries = <ModelEntry>[];
    for (final p in providers()) {
      for (final m in p.models) {
        entries.add(
          ModelEntry(
            compositeKey: m.compositeKey(p.name),
            providerName: p.name,
            model: m,
          ),
        );
      }
    }
    return entries;
  }

  /// Look up a provider by name. Returns `null` if not found.
  ProviderConfig? providerByName(String name) => _configs[name];

  /// Look up a model by its composite key `"provider/modelId"`.
  ///
  /// Searches across all loaded providers.
  ModelConfig? modelByCompositeKey(String key) {
    final parts = key.split('/');
    if (parts.length != 2) return null;
    final provider = providerByName(parts[0]);
    if (provider == null) return null;
    return provider.modelById(parts[1]);
  }

  /// Find the provider that owns a given model ID (non-composite).
  ///
  /// If multiple providers have a model with the same ID, returns the first
  /// one found in load order.
  ProviderConfig? providerForModelId(String modelId) {
    for (final name in _loadOrder) {
      final p = _configs[name]!;
      if (p.modelById(modelId) != null) return p;
    }
    return null;
  }

  /// Whether any model (across all providers) supports image input.
  bool anyImageSupport() => providers().any((p) => p.hasImageSupport());

  /// The set of composite keys for models that support images.
  Set<String> imageModelKeys() {
    final keys = <String>{};
    for (final p in providers()) {
      for (final m in p.models) {
        if (m.imageSupport) keys.add(m.compositeKey(p.name));
      }
    }
    return keys;
  }

  /// Errors encountered during loading, keyed by filename.
  Map<String, String> loadErrors() => Map.unmodifiable(_errors);

  /// Load all `.toml` files from [providersDirs].
  ///
  /// Clears any previously loaded configs and errors first.
  /// Directories are searched in order; the first occurrence of a given
  /// provider name wins, so list the user dir (where customizations live)
  /// before the built-in dir.
  /// Files that fail to parse are skipped; their errors are recorded in
  /// [loadErrors].
  /// Files matching [isExampleProviderFile] (e.g. `example.provider.toml`)
  /// are skipped — those are reference templates, not real providers.
  Future<void> loadAll() async {
    _configs.clear();
    _loadOrder.clear();
    _errors.clear();

    for (final dir in providersDirs) {
      if (!await dir.exists()) continue;

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.toml'))
          .where((f) => !isExampleProviderFile(f.path))
          .toList();

      files.sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        final name = _providerNameFromFile(file);
        if (_configs.containsKey(name)) continue;
        try {
          final config = await _loadSingle(file, name);
          _configs[name] = config;
          _loadOrder.add(name);
        } catch (e) {
          _errors[file.path] = e.toString();
        }
      }
    }
  }

  /// Reload a single provider config by name.
  ///
  /// Useful after editing a TOML file. Returns the updated config, or `null`
  /// if the file no longer exists or fails to parse.
  ///
  /// Searches all configured [providersDirs] in precedence order; the
  /// first matching file wins. If a previously-loaded config came from
  /// a higher-priority dir and that file still exists, it stays put.
  Future<ProviderConfig?> reload(String providerName) async {
    File? file;
    for (final dir in providersDirs) {
      final candidate = File('${dir.path}/$providerName.toml');
      // Example files (e.g. `example.provider.toml`) are reference templates,
      // not real providers — never reload through them.
      if (isExampleProviderFile(candidate.path)) continue;
      if (await candidate.exists()) {
        file = candidate;
        break;
      }
    }
    if (file == null) {
      _configs.remove(providerName);
      _loadOrder.remove(providerName);
      return null;
    }

    try {
      final config = await _loadSingle(file, providerName);
      _configs[providerName] = config;
      if (!_loadOrder.contains(providerName)) {
        _loadOrder.add(providerName);
      }
      _errors.remove(file.path);
      return config;
    } catch (e) {
      _errors[file.path] = e.toString();
      return null;
    }
  }

  /// Extract the provider name from a file path.
  ///
  /// `providers/openai.toml` → `"openai"`
  String _providerNameFromFile(File file) {
    final basename = file.uri.pathSegments.last;
    return basename.replaceAll('.toml', '');
  }

  /// Parse a single TOML file into a [ProviderConfig].
  Future<ProviderConfig> _loadSingle(File file, String name) async {
    final content = await file.readAsString();
    final doc = TomlDocument.parse(content);
    final map = doc.toMap();

    return _parseProviderConfig(map, name);
  }

  /// Parse the top-level TOML map into a [ProviderConfig].
  ProviderConfig _parseProviderConfig(Map<String, dynamic> map, String name) {
    // --- Required fields ---
    final type = _requireString(map, 'type');
    final endpointUrl = _requireString(map, 'endpoint_url');

    // Resolve the type to a (provider, wireFamily) pair. Unknown types
    // throw a helpful ArgumentError which we surface as a load error
    // recorded in _errors instead of aborting startup.
    final resolved = resolveProvider(type);

    // --- Models ([[models]] array of tables) ---
    final modelsRaw = map['models'];
    if (modelsRaw == null) {
      throw FormatException('Provider "$name": missing [[models]] section');
    }
    if (modelsRaw is! List) {
      throw FormatException(
        'Provider "$name": "models" must be an array of tables ([[models]])',
      );
    }
    final models = modelsRaw
        .map((m) => _parseModelConfig(m as Map<String, dynamic>))
        .toList();

    // --- Optional quota section ([quota]) ---
    final quotaRaw = map['quota'];
    UsageQuotaConfig? quota;
    if (quotaRaw != null) {
      quota = _parseUsageQuotaConfig(quotaRaw as Map<String, dynamic>);
    }

    // --- Optional provider-level round-trip cap (default_max_rounds) ---
    // 0 or absent = unbounded. Negative values are rejected at load time
    // with a clear error rather than silently ignored.
    final defaultMaxRounds = _optionalNonNegativeInt(
      map,
      'default_max_rounds',
      fieldLabel: 'Provider "$name"',
    );

    // --- Optional provider-level reasoning label overrides ([reasoning_labels]) ---
    final providerLabelsRaw = map['reasoning_labels'];
    final Map<String, String> providerReasoningLabels;
    if (providerLabelsRaw != null) {
      if (providerLabelsRaw is! Map) {
        throw FormatException(
          'Provider "$name": "reasoning_labels" must be a table '
          '([reasoning_labels]), got ${providerLabelsRaw.runtimeType}',
        );
      }
      providerReasoningLabels = providerLabelsRaw.map(
        (k, v) => MapEntry(k as String, v as String),
      );
    } else {
      providerReasoningLabels = const {};
    }

    // --- Optional provider-level hint_parallel_calls override ---
    // `true` or `false` only; `null` (TOML absent) preserves the
    // LLM-provider class default. The legacy key
    // `praise_parallel_calls` is also accepted for backward
    // compatibility (it was renamed to `hint_parallel_calls` when
    // the feature grew a second signal); when both are present the
    // new name wins so a user can migrate by editing one line.
    final hintParallelCalls = _resolveHintParallelCallsBool(
      map,
      legacyKey: 'praise_parallel_calls',
      newKey: 'hint_parallel_calls',
    );

    // --- Optional provider-level single-call hint threshold ---
    // Integer; must be >= 0. `null` falls through to the
    // LLM-provider class default. There is no legacy name for
    // this field — it didn't exist when `praise_parallel_calls`
    // was the only knob.
    final hintParallelCallsSingleThreshold = _optionalNonNegativeInt(
      map,
      'hint_parallel_calls_single_threshold',
      fieldLabel: 'Provider "$name"',
    );

    // --- Optional provider-level system_prompt_addition ---
    // String (single-line) or multi-line TOML string. `null` if
    // absent. A non-empty value is rendered as a separate system
    // prompt layer for every model under this provider that
    // doesn't define its own override.
    final systemPromptAddition = _optionalString(
      map,
      'system_prompt_addition',
    );

    // --- Optional provider-level stream watchdog overrides ---
    // Both are positive integers in milliseconds. `null` (TOML
    // absent) means "use the LlmClient's hardcoded default" (120s
    // for idle, 10min for max), so this is fully backward-
    // compatible — existing provider TOMLs need no change.
    // Negative values are rejected at load time with a clear
    // error rather than silently ignored.
    final streamIdleTimeoutMs = _optionalNonNegativeInt(
      map,
      'stream_idle_timeout_ms',
      fieldLabel: 'Provider "$name"',
    );
    final streamMaxDurationMs = _optionalNonNegativeInt(
      map,
      'stream_max_duration_ms',
      fieldLabel: 'Provider "$name"',
    );

    return ProviderConfig(
      name: name,
      type: type,
      wireFamily: resolved.wire,
      endpointUrl: endpointUrl,
      models: List.unmodifiable(models),
      quota: quota,
      reasoningLabels: providerReasoningLabels,
      defaultMaxRounds: defaultMaxRounds,
      hintParallelCalls: hintParallelCalls,
      hintParallelCallsSingleThreshold: hintParallelCallsSingleThreshold,
      systemPromptAddition: systemPromptAddition,
      streamIdleTimeoutMs: streamIdleTimeoutMs,
      streamMaxDurationMs: streamMaxDurationMs,
    );
  }

  /// Parse a single `[[models]]` table into a [ModelConfig].
  ModelConfig _parseModelConfig(Map<String, dynamic> map) {
    final id = _requireString(map, 'id');
    final displayName = _requireString(map, 'name');
    final contextSize = _requireInt(map, 'context_size');

    // Optional booleans (default true for thinking — most modern models
    // support it; opt out with `thinking = false` in TOML)
    final imageSupport = _optionalBool(map, 'image_support') ?? false;
    final thinking = _optionalBool(map, 'thinking') ?? true;

    // Optional reasoning_effort (string → enum).
    // Defaults to "normal" when absent so reasoning levels are available
    // in the UI unless explicitly omitted via `reasoning_effort = "none"`.
    final effortStr = _optionalString(map, 'reasoning_effort') ?? 'normal';
    final reasoningEffort = ReasoningEffortParse.fromString(effortStr);

    // Optional thinking_budget (int)
    final thinkingBudget = _optionalInt(map, 'thinking_budget');

    final maxTokens = _optionalInt(map, 'max_tokens');

        final streamLerp = _optionalBool(map, 'stream_lerp') ?? false;

    final temperature = _optionalDouble(map, 'temperature') ?? 0;

    // Optional per-model display label overrides for reasoning effort.
    // TOML: [models.reasoning_labels]
    //   normal = "adaptive"
    final reasoningLabelsRaw = map['reasoning_labels'];
    final Map<String, String> reasoningLabels;
    if (reasoningLabelsRaw != null) {
      if (reasoningLabelsRaw is! Map) {
        throw FormatException(
          'Model "$id": "reasoning_labels" must be a table '
          '([models.reasoning_labels]), got ${reasoningLabelsRaw.runtimeType}',
        );
      }
      reasoningLabels = reasoningLabelsRaw.map(
        (k, v) => MapEntry(k as String, v as String),
      );
    } else {
      reasoningLabels = const {};
    }

    // Optional per-model round-trip cap. 0 or absent = unbounded (falls
    // back to the provider-level default_max_rounds, or unbounded if
    // that's also unset). Negative values are rejected with a clear
    // load error.
    final maxRounds = _optionalNonNegativeInt(
      map,
      'max_rounds',
      fieldLabel: 'Model "$id"',
    );

    // Optional per-model override for the parallel-tool-call hint
    // toggle. `true`/`false` always wins over the provider-level
    // override; `null` (TOML absent) falls through. The legacy
    // key `praise_parallel_calls` is also accepted; the new
    // `hint_parallel_calls` wins when both are present so users
    // can migrate by editing one line.
    final hintParallelCalls = _resolveHintParallelCallsBool(
      map,
      legacyKey: 'praise_parallel_calls',
      newKey: 'hint_parallel_calls',
    );

    // Optional per-model override for the single-call hint
    // threshold. Integer; must be >= 0. `null` falls through to
    // the provider-level override, then the LLM-provider class
    // default.
    final hintParallelCallsSingleThreshold = _optionalNonNegativeInt(
      map,
      'hint_parallel_calls_single_threshold',
      fieldLabel: 'Model "$id"',
    );

    // Optional per-model system_prompt_addition. A non-null,
    // non-empty value here overrides the provider-level value.
    // `null` falls through to the provider-level value; if both
    // are null, the system-prompt tuning layer is omitted.
    final systemPromptAddition = _optionalString(
      map,
      'system_prompt_addition',
    );

    return ModelConfig(
      id: id,
      name: displayName,
      contextSize: contextSize,
      imageSupport: imageSupport,
      reasoningEffort: reasoningEffort,
      thinking: thinking,
      thinkingBudget: thinkingBudget,
      maxTokens: maxTokens,
      streamLerp: streamLerp,
      temperature: temperature,
      reasoningLabels: reasoningLabels,
      maxRounds: maxRounds,
      hintParallelCalls: hintParallelCalls,
      hintParallelCallsSingleThreshold: hintParallelCallsSingleThreshold,
      systemPromptAddition: systemPromptAddition,
    );
  }

  /// Parse the `[quota]` table into a [UsageQuotaConfig].
  UsageQuotaConfig _parseUsageQuotaConfig(Map<String, dynamic> map) {
    final apiUrl = _requireString(map, 'api_url');

    final usageRaw = map['usage'];
    if (usageRaw == null) {
      throw FormatException('Quota section: missing [quota.usage] sub-table');
    }
    if (usageRaw is! Map) {
      throw FormatException(
        'Quota section: "usage" must be a table ([quota.usage])',
      );
    }

    final tiers = <UsageQuotaTier>[];
    for (final entry in usageRaw.entries) {
      final label = entry.key as String;
      final limit = entry.value as int;
      tiers.add(UsageQuotaTier(label: label, limit: limit));
    }

    // Sort tiers by expected granularity: 5h → 1w → 1m
    tiers.sort((a, b) => _tierOrder(a.label).compareTo(_tierOrder(b.label)));

    return UsageQuotaConfig(apiUrl: apiUrl, tiers: List.unmodifiable(tiers));
  }

  /// Rough ordering for quota tier labels so they sort short-window first.
  ///
  /// "5h" → 0, "1w" → 1, "1m" → 2. Unknown labels get a high value so they
  /// sort after the known ones.
  int _tierOrder(String label) {
    switch (label) {
      case '5h':
        return 0;
      case '1w':
        return 1;
      case '1m':
        return 2;
      default:
        return 99;
    }
  }

  // --- Typed map accessor helpers ---
  // These provide clear error messages when a TOML field is missing or has
  // the wrong type, rather than cryptic null / cast errors.

  String _requireString(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) {
      throw FormatException('Missing required field: "$key"');
    }
    if (v is! String) {
      throw FormatException(
        'Field "$key" must be a string, got ${v.runtimeType}',
      );
    }
    return v;
  }

  int _requireInt(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) {
      throw FormatException('Missing required field: "$key"');
    }
    if (v is! int) {
      throw FormatException(
        'Field "$key" must be an integer, got ${v.runtimeType}',
      );
    }
    return v;
  }

  String? _optionalString(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is! String) {
      throw FormatException(
        'Field "$key" must be a string if present, got ${v.runtimeType}',
      );
    }
    return v;
  }

  int? _optionalInt(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is! int) {
      throw FormatException(
        'Field "$key" must be an integer if present, got ${v.runtimeType}',
      );
    }
    return v;
  }

  double? _optionalDouble(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw FormatException(
      'Field "$key" must be a number if present, got ${v.runtimeType}',
    );
  }

  bool? _optionalBool(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return null;
    if (v is! bool) {
      throw FormatException(
        'Field "$key" must be a boolean if present, got ${v.runtimeType}',
      );
    }
    return v;
  }

  /// Resolve the parallel-tool-call hint boolean with backward
  /// compatibility for the legacy `praise_parallel_calls` key.
  ///
  /// The feature was originally gated by a single
  /// `praise_parallel_calls` TOML field. When a second signal
  /// (the single-call reminder) was added, the field was renamed
  /// to `hint_parallel_calls` to reflect the unified feature. To
  /// avoid breaking existing user TOMLs, this helper accepts
  /// either name. When both are present the new name wins (so
  /// the user can migrate by editing one line and re-saving).
  ///
  /// If only the legacy key is present and it has the wrong type,
  /// the error message names the legacy key so the user knows
  /// exactly which line in their TOML is wrong even before they
  /// migrate. When both keys are present and the legacy one is
  /// malformed, we still throw (with a "rename to silence this"
  /// hint) rather than silently overriding.
  bool? _resolveHintParallelCallsBool(
    Map<String, dynamic> map, {
    required String legacyKey,
    required String newKey,
  }) {
    final hasNew = map.containsKey(newKey);
    final hasLegacy = map.containsKey(legacyKey);

    if (hasNew) {
      // The new key wins outright. If the legacy key is also
      // present but malformed, surface that as a hint-laden error
      // rather than letting it silently co-exist with a valid
      // new-key value.
      if (hasLegacy && map[legacyKey] is! bool) {
        throw FormatException(
          'Field "$legacyKey" must be a boolean if present, got '
          '${map[legacyKey].runtimeType} (note: "$legacyKey" is '
          'deprecated; rename to "$newKey" to silence this)',
        );
      }
      return _optionalBool(map, newKey);
    }

    if (hasLegacy) {
      return _optionalBool(map, legacyKey);
    }

    return null;
  }

  /// Optional non-negative integer accessor. Used for round-trip caps
  /// where `0` is a meaningful value ("no cap", same as absent) but
  /// negatives are always a user error.
  ///
  /// [fieldLabel] appears in the error message so the user knows which
  /// `[[models]]` entry or which provider file is misconfigured.
  int? _optionalNonNegativeInt(
    Map<String, dynamic> map,
    String key, {
    required String fieldLabel,
  }) {
    final v = map[key];
    if (v == null) return null;
    if (v is! int) {
      throw FormatException(
        '$fieldLabel: field "$key" must be an integer if present, '
        'got ${v.runtimeType}',
      );
    }
    if (v < 0) {
      throw FormatException(
        '$fieldLabel: field "$key" must be >= 0 (0 means unbounded), got $v',
      );
    }
    return v;
  }
}

import 'dart:io';
import 'package:toml/toml.dart';
import '../models/provider_config.dart';

/// Loads and manages provider configuration files from a TOML-based directory.
///
/// Each provider is defined by a single `.toml` file in the providers directory.
/// The filename (sans `.toml`) becomes the provider name, e.g. `openai.toml`
/// yields provider `"openai"`.
///
/// Usage:
/// ```dart
/// final loader = ProviderConfigLoader(
///   providersDir: Directory('providers'),
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
  /// The directory containing `.toml` provider config files.
  final Directory providersDir;

  /// Loaded configs keyed by provider name.
  final Map<String, ProviderConfig> _configs = {};

  /// Ordered list of provider names as they were loaded (for stable iteration).
  final List<String> _loadOrder = [];

  /// Any errors encountered during loading, keyed by filename.
  final Map<String, String> _errors = {};

  ProviderConfigLoader({required this.providersDir});

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
        entries.add(ModelEntry(
          compositeKey: m.compositeKey(p.name),
          providerName: p.name,
          model: m,
        ));
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

  /// Load all `.toml` files from [providersDir].
  ///
  /// Clears any previously loaded configs and errors first.
  /// Files that fail to parse are skipped; their errors are recorded in
  /// [loadErrors].
  Future<void> loadAll() async {
    _configs.clear();
    _loadOrder.clear();
    _errors.clear();

    if (!await providersDir.exists()) {
      return; // No providers directory — nothing to load.
    }

    final files = providersDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.toml'))
        .toList();

    // Sort by filename for deterministic load order.
    files.sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final name = _providerNameFromFile(file);
      try {
        final config = await _loadSingle(file, name);
        _configs[name] = config;
        _loadOrder.add(name);
      } catch (e) {
        _errors[file.path] = e.toString();
      }
    }
  }

  /// Reload a single provider config by name.
  ///
  /// Useful after editing a TOML file. Returns the updated config, or `null`
  /// if the file no longer exists or fails to parse.
  Future<ProviderConfig?> reload(String providerName) async {
    final file = File('${providersDir.path}/$providerName.toml');
    if (!await file.exists()) {
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
    final typeStr = _requireString(map, 'type');
    final type = ProviderTypeParse.fromString(typeStr);
    final endpointUrl = _requireString(map, 'endpoint_url');

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

    return ProviderConfig(
      name: name,
      type: type,
      endpointUrl: endpointUrl,
      models: List.unmodifiable(models),
      quota: quota,
    );
  }

  /// Parse a single `[[models]]` table into a [ModelConfig].
  ModelConfig _parseModelConfig(Map<String, dynamic> map) {
    final id = _requireString(map, 'id');
    final displayName = _requireString(map, 'name');
    final contextSize = _requireInt(map, 'context_size');

    // Optional booleans (default false if absent)
    final imageSupport = _optionalBool(map, 'image_support') ?? false;
    final thinking = _optionalBool(map, 'thinking') ?? false;

    // Optional reasoning_effort (string → enum)
    final effortStr = _optionalString(map, 'reasoning_effort');
    final reasoningEffort = ReasoningEffortParse.fromString(effortStr);

    // Optional thinking_budget (int)
    final thinkingBudget = _optionalInt(map, 'thinking_budget');

    return ModelConfig(
      id: id,
      name: displayName,
      contextSize: contextSize,
      imageSupport: imageSupport,
      reasoningEffort: reasoningEffort,
      thinking: thinking,
      thinkingBudget: thinkingBudget,
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
}

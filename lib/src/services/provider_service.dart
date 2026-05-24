import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import '../models/provider_config.dart';
import 'provider_config_loader.dart';

/// A model discovered from a provider's remote API endpoint.
///
/// Contains only the information available from the API response;
/// optional fields may be null if the provider doesn't expose them.
class DiscoveredModel {
  /// The model ID as reported by the provider (e.g. "gpt-4o").
  final String id;

  /// Human-readable name, if the provider supplies one.
  final String? name;

  /// Context window size in tokens, if available.
  final int? contextSize;

  /// Whether the model supports image inputs, if known.
  final bool? imageSupport;

  const DiscoveredModel({
    required this.id,
    this.name,
    this.contextSize,
    this.imageSupport,
  });

  @override
  String toString() =>
      'DiscoveredModel($id, name=$name, ctx=$contextSize, img=$imageSupport)';
}

/// Manages provider configuration files, API key storage, and model discovery.
///
/// [ProviderService] wraps a [ProviderConfigLoader] for reading/writing TOML
/// configs, persists API keys in an `auth.json` file following XDG conventions
/// (`$XDG_DATA_HOME/crux/auth.json` with `0o600` permissions), and can query
/// remote endpoints to discover available models.
///
/// Example:
/// ```dart
/// final service = ProviderService();
/// await service.initialize();
///
/// final openai = service.providerByName('openai');
/// final models = await service.discoverModels('openai');
///
/// service.setApiKey('openai', 'sk-xxx');
/// print(service.getApiKey('openai')); // sk-xxx
/// ```
class ProviderService {
  /// Path to the directory containing provider `.toml` config files.
  final String providersDir;

  /// The loader that reads and parses TOML provider configs.
  final ProviderConfigLoader _loader;

  /// API keys stored in-memory, keyed by env var name (e.g.
  /// `CRUX_API_KEY_OPENAI`). Populated from [authJsonPath] on initialization
  /// and updated by [setApiKey] / [removeApiKey].
  final Map<String, String> _envKeys = {};

  /// The last model the user switched to via `/model`. Persisted in
  /// `auth.json` and loaded on startup. Used by [resolveDefaultModel].
  String? _lastUsedModel;

  /// The auxiliary model used for generating session names, summaries, etc.
  /// Persisted in `auth.json` and loaded on startup. Global — not per-session.
  String? _auxiliaryModel;

  /// Path to the auth.json file for persistent key storage.
  /// Follows XDG: `$XDG_DATA_HOME/crux/auth.json`
  /// (defaults to `~/.local/share/crux/auth.json`).
  late final String authJsonPath;

  ProviderService({this.providersDir = 'providers'})
    : _loader = ProviderConfigLoader(providersDir: Directory(providersDir)) {
    final xdgDataHome = Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME']!, '.local', 'share');
    authJsonPath = p.join(xdgDataHome, 'crux', 'auth.json');
  }

  // ---------------------------------------------------------------------------
  // Initialization & reload
  // ---------------------------------------------------------------------------

  /// Initializes the service: loads all provider TOML configs and API keys
  /// from the persistent `auth.json` file.
  Future<void> initialize() async {
    await _loader.loadAll();
    await _loadAuthKeys();
  }

  /// Performs a full reload of all provider configs from disk.
  Future<void> reload() async {
    await _loader.loadAll();
  }

  // ---------------------------------------------------------------------------
  // Delegated loader accessors
  // ---------------------------------------------------------------------------

  /// Look up a provider by name. Returns `null` if not found.
  ProviderConfig? providerByName(String name) => _loader.providerByName(name);

  /// Look up a model by its composite key `"provider/modelId"`.
  ModelConfig? modelByCompositeKey(String key) =>
      _loader.modelByCompositeKey(key);

  /// All loaded provider names in load order.
  List<String> providerNames() => _loader.providerNames();

  /// All loaded configs in load order.
  List<ProviderConfig> providers() => _loader.providers();

  /// All models across all providers, as composite keys.
  List<String> allModelKeys() => _loader.allModelKeys();

  /// All models across all providers with full metadata.
  List<ModelEntry> allModelEntries() => _loader.allModelEntries();

  /// The set of composite keys for models that support images.
  Set<String> imageModelKeys() => _loader.imageModelKeys();

  // ---------------------------------------------------------------------------
  // Provider management (add / remove / modify)
  // ---------------------------------------------------------------------------

  /// Creates a new provider config file and loads it.
  ///
  /// Writes a TOML file at `providersDir/<name>.toml`, then reloads
  /// all configs. Returns the loaded [ProviderConfig].
  Future<ProviderConfig> addProvider(ProviderConfig config) async {
    final file = File('$providersDir/${config.name}.toml');
    final tomlContent = _serializeProviderConfig(config);
    await _ensureProvidersDir();
    await file.writeAsString(tomlContent);
    await _loader.loadAll();
    return _loader.providerByName(config.name)!;
  }

  /// Deletes a provider config file and reloads.
  ///
  /// Returns `true` if the file was deleted, `false` if it didn't exist.
  Future<bool> removeProvider(String providerName) async {
    final file = File('$providersDir/$providerName.toml');
    if (!await file.exists()) return false;
    await file.delete();
    await _loader.loadAll();
    return true;
  }

  /// Modifies an existing provider config by merging non-null fields.
  ///
  /// Only the fields that are explicitly provided (non-null) are updated;
  /// all others retain their current values. The TOML file is overwritten
  /// and configs are reloaded. Returns the updated [ProviderConfig], or
  /// `null` if the provider wasn't found.
  Future<ProviderConfig?> modifyProvider(
    String providerName, {
    String? endpointUrl,
    ProviderType? type,
    List<ModelConfig>? models,
    UsageQuotaConfig? quota,
  }) async {
    final current = _loader.providerByName(providerName);
    if (current == null) return null;

    final updated = ProviderConfig(
      name: providerName,
      type: type ?? current.type,
      endpointUrl: endpointUrl ?? current.endpointUrl,
      models: models ?? current.models,
      quota: quota ?? current.quota,
    );

    final file = File('$providersDir/$providerName.toml');
    final tomlContent = _serializeProviderConfig(updated);
    await file.writeAsString(tomlContent);
    await _loader.loadAll();
    return _loader.providerByName(providerName);
  }

  // ---------------------------------------------------------------------------
  // Model discovery (query remote /models endpoint)
  // ---------------------------------------------------------------------------

  /// Queries a provider's remote API to discover available models.
  ///
  /// For OpenAI-compatible providers, makes a GET request to
  /// `<endpoint_url>/models` and parses the response. For Anthropic
  /// providers, returns an empty list (no public model list endpoint).
  /// Falls back to an empty list on any request failure.
  Future<List<DiscoveredModel>> discoverModels(String providerName) async {
    final provider = _loader.providerByName(providerName);
    if (provider == null) return [];

    // Anthropic has no public model list endpoint
    if (provider.type == ProviderType.anthropic) return [];

    // OpenAI-compatible providers expose a /models endpoint
    if (provider.type == ProviderType.openai) {
      return _discoverOpenAIModels(provider);
    }

    // Other provider types: not yet supported
    return [];
  }

  /// Fetches models from an OpenAI-compatible `/models` endpoint.
  ///
  /// Sends an HTTP GET to `<endpoint_url>/models` with the appropriate
  /// auth header if an API key is available. Parses the `{data: [...]}`
  /// JSON response into a list of [DiscoveredModel] objects.
  Future<List<DiscoveredModel>> _discoverOpenAIModels(
    ProviderConfig provider,
  ) async {
    final apiKey = getApiKey(provider.name);
    final baseUri = Uri.parse(provider.endpointUrl);
    final modelsUri = baseUri.resolve('models');

    final client = HttpClient();
    try {
      final request = await client.getUrl(modelsUri);

      // Attach auth header if an API key is available.
      // Header format varies by provider type:
      //   OpenAI:   Authorization: Bearer <key>
      //   Anthropic: x-api-key: <key>
      if (apiKey != null && apiKey.isNotEmpty) {
        if (provider.type == ProviderType.openai) {
          request.headers.set('Authorization', 'Bearer $apiKey');
        } else if (provider.type == ProviderType.anthropic) {
          request.headers.set('x-api-key', apiKey);
        }
      }

      final response = await request.close();
      if (response.statusCode != 200) return [];

      final responseBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>?;

      if (data == null) return [];

      return data.map((item) {
        final obj = item as Map<String, dynamic>;
        return DiscoveredModel(
          id: obj['id'] as String? ?? '',
          name: obj['name'] as String? ?? obj['id'] as String?,
        );
      }).toList();
    } catch (_) {
      // Network errors, parse failures, etc. — fall back gracefully
      return [];
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Model selection persistence & resolution
  // ---------------------------------------------------------------------------

  /// Persists the given model composite key as the last-used model.
  ///
  /// Called when the user switches model via `/model` or the local model
  /// button. The value is stored in `auth.json` and used by
  /// [resolveDefaultModel] on the next launch.
  Future<void> setLastUsedModel(String compositeKey) async {
    _lastUsedModel = compositeKey;
    await _persistAuthKeys();
  }

  /// Returns the auxiliary model composite key, or null if not set.
  String? get auxiliaryModel => _auxiliaryModel;

  /// Persists the given model composite key as the auxiliary model.
  ///
  /// Called when the user selects a model via `/auxiliary`. The value is
  /// stored globally in `auth.json` and persists across sessions.
  Future<void> setAuxiliaryModel(String compositeKey) async {
    _auxiliaryModel = compositeKey;
    await _persistAuthKeys();
  }

  /// Resolves the default model to use on startup, following these rules:
  ///
  /// 1. **Last used model**: if [_lastUsedModel] is set and still valid
  ///    (provider exists, model exists, API key available), use it.
  /// 2. **Latest configured model**: the first model from the first
  ///    provider that has an API key configured.
  /// 3. Returns `null` if no models are available at all.
  String? resolveDefaultModel() {
    // Rule 1: last used model, if still valid
    if (_lastUsedModel != null) {
      final model = modelByCompositeKey(_lastUsedModel!);
      if (model != null) {
        final providerName = _lastUsedModel!.split('/').first;
        if (getApiKey(providerName) != null) {
          return _lastUsedModel;
        }
      }
    }

    // Rule 2: latest configured model (first model from first provider
    // with an API key)
    for (final name in providerNames()) {
      if (getApiKey(name) == null) continue;
      final provider = providerByName(name);
      if (provider != null && provider.models.isNotEmpty) {
        return provider.models.first.compositeKey(provider.name);
      }
    }

    // Rule 3: no available models
    return null;
  }

  // ---------------------------------------------------------------------------
  // API key management (env vars + auth.json persistence)
  // ---------------------------------------------------------------------------

  /// Retrieves the API key for a given provider.
  ///
  /// Checks the following sources in order:
  /// 1. Keys stored in `auth.json` (loaded into [_envKeys])
  /// 2. Process environment variables ([Platform.environment])
  /// 3. The global default key `CRUX_API_KEY` (from either source)
  ///
  /// Convention: `CRUX_API_KEY_<PROVIDERNAME>` (uppercase),
  /// e.g. `CRUX_API_KEY_OPENAI`, `CRUX_API_KEY_ANTHROPIC`.
  String? getApiKey(String providerName) {
    final envKey = 'CRUX_API_KEY_${providerName.toUpperCase()}';

    if (_envKeys.containsKey(envKey)) return _envKeys[envKey];

    if (Platform.environment.containsKey(envKey)) {
      return Platform.environment[envKey];
    }

    if (_envKeys.containsKey('CRUX_API_KEY')) return _envKeys['CRUX_API_KEY'];
    return Platform.environment['CRUX_API_KEY'];
  }

  /// Stores an API key for a provider and persists it to `auth.json`.
  ///
  /// The key is written to both the in-memory map and the on-disk
  /// `auth.json` file (XDG data dir, mode `0o600`).
  Future<void> setApiKey(String providerName, String key) async {
    final envKey = 'CRUX_API_KEY_${providerName.toUpperCase()}';
    _envKeys[envKey] = key;
    await _persistAuthKeys();
  }

  /// Removes an API key for a provider from both memory and `auth.json`.
  ///
  /// Note: if the key was also present in [Platform.environment] (set
  /// externally before the process started), it remains accessible there.
  Future<void> removeApiKey(String providerName) async {
    final envKey = 'CRUX_API_KEY_${providerName.toUpperCase()}';
    _envKeys.remove(envKey);
    await _persistAuthKeys();
  }

  /// Loads API keys and last-used model from the `auth.json` file.
  ///
  /// Supports two formats:
  /// - **Legacy** (flat): `{ "CRUX_API_KEY_DEEPSEEK": "sk-..." }`
  /// - **Current** (structured):
  ///   ```json
  ///   {
  ///     "apiKeys": { "CRUX_API_KEY_DEEPSEEK": "sk-..." },
  ///     "lastUsedModel": "deepseek/deepseek-v4-flash"
  ///   }
  ///   ```
  Future<void> _loadAuthKeys() async {
    final file = File(authJsonPath);
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      if (data.containsKey('apiKeys')) {
        // Structured format
        final apiKeys = data['apiKeys'] as Map<String, dynamic>;
        for (final entry in apiKeys.entries) {
          if (entry.value is String) {
            _envKeys[entry.key] = entry.value as String;
          }
        }
        _lastUsedModel = data['lastUsedModel'] as String?;
        _auxiliaryModel = data['auxiliaryModel'] as String?;
      } else {
        // Legacy flat format — migrate on next write
        for (final entry in data.entries) {
          if (entry.value is String) {
            _envKeys[entry.key] = entry.value as String;
          }
        }
      }
    } catch (_) {
      // Corrupt or unreadable auth file — skip gracefully
    }
  }

  /// Persists API keys and last-used model to the `auth.json` file.
  ///
  /// Creates the XDG data directory if it doesn't exist, then writes
  /// structured JSON with `0o600` permissions (owner rw only).
  Future<void> _persistAuthKeys() async {
    final dir = File(authJsonPath).parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final data = <String, dynamic>{
      'apiKeys': _envKeys,
      if (_lastUsedModel != null) 'lastUsedModel': _lastUsedModel,
      if (_auxiliaryModel != null) 'auxiliaryModel': _auxiliaryModel,
    };
    final content =
        JsonEncoder.withIndent('  ').convert(data) + '\n';
    final file = File(authJsonPath);
    await file.writeAsString(content);
    try {
      await Process.run('chmod', ['600', authJsonPath]);
    } catch (_) {
      // chmod may not be available on all platforms
    }
  }

  // ---------------------------------------------------------------------------
  // TOML serialization (private)
  // ---------------------------------------------------------------------------

  /// Converts a [ProviderConfig] to a TOML string.
  ///
  /// Only non-default and non-null optional fields are written to keep the
  /// output clean. For example, `image_support` is only written when `true`,
  /// and `reasoning_effort` is omitted when `null`.
  String _serializeProviderConfig(ProviderConfig config) {
    final map = <String, dynamic>{
      'type': config.type.toConfigString(),
      'endpoint_url': config.endpointUrl,
      'models': config.models.map(_serializeModelConfig).toList(),
    };

    if (config.quota != null) {
      map['quota'] = _serializeUsageQuotaConfig(config.quota!);
    }

    final doc = TomlDocument.fromMap(map);
    return doc.toString();
  }

  /// Converts a [ModelConfig] to a TOML-friendly map.
  ///
  /// Required fields (`id`, `name`, `context_size`) are always included.
  /// Optional fields are included only when they differ from defaults:
  /// - `image_support` → only if `true` (default is `false`)
  /// - `thinking` → only if `true` (default is `false`)
  /// - `reasoning_effort` → only if non-null
  /// - `thinking_budget` → only if non-null
  Map<String, dynamic> _serializeModelConfig(ModelConfig model) {
    final map = <String, dynamic>{
      'id': model.id,
      'name': model.name,
      'context_size': model.contextSize,
    };

    if (model.imageSupport) map['image_support'] = true;
    if (model.thinking) map['thinking'] = true;
    if (model.reasoningEffort != null) {
      map['reasoning_effort'] = model.reasoningEffort!.toConfigString();
    }
    if (model.thinkingBudget != null) {
      map['thinking_budget'] = model.thinkingBudget!;
    }

    return map;
  }

  /// Converts a [UsageQuotaConfig] to a TOML-friendly map.
  ///
  /// Produces a nested structure that serializes as:
  /// ```toml
  /// [quota]
  /// api_url = "..."
  ///
  /// [quota.usage]
  /// "5h" = 100
  /// ```
  Map<String, dynamic> _serializeUsageQuotaConfig(UsageQuotaConfig quota) {
    final usage = <String, dynamic>{};
    for (final tier in quota.tiers) {
      usage[tier.label] = tier.limit;
    }

    return {'api_url': quota.apiUrl, 'usage': usage};
  }

  // ---------------------------------------------------------------------------
  // Utility (private)
  // ---------------------------------------------------------------------------

  /// Ensures the providers directory exists on disk.
  Future<void> _ensureProvidersDir() async {
    final dir = Directory(providersDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }
}

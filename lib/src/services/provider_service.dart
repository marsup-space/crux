import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/provider_config.dart';
import 'llm_provider.dart';
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
/// Two directories drive config lookup:
/// - [userProvidersDir] (e.g. `~/.config/crux/providers/`) — writable,
///   per-user, populated by [seedExampleProviders] on launch.
/// - [builtInProvidersDir] (e.g. `./providers/`, next to the binary) —
///   read-only, shipped with the binary.
///
/// The loader searches the user dir first, then the built-in dir, so the
/// user can override any built-in example by placing a same-named file in
/// their user dir.
///
/// Example:
/// ```dart
/// final service = ProviderService(
///   userProvidersDir: '~/.config/crux/providers',
///   builtInProvidersDir: 'providers',
/// );
/// await service.initialize();
///
/// final openai = service.providerByName('openai');
/// final models = await service.discoverModels('openai');
///
/// service.setApiKey('openai', 'sk-xxx');
/// print(service.getApiKey('openai')); // sk-xxx
/// ```
class ProviderService {
  /// Path to the per-user, writable providers directory. All writes
  /// (add/modify/remove from the custom wizard) go here.
  final String userProvidersDir;

  /// Path to the read-only built-in providers directory (shipped with
  /// the binary). Used as a fallback for built-in examples.
  final String? builtInProvidersDir;

  /// Convenience: the writable user dir.
  String get providersDir => userProvidersDir;

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

  /// Character threshold for TLDR generation. If an AI response exceeds this
  /// many characters, a TLDR summary is generated using the auxiliary model.
  /// Persisted in `auth.json`. Default is 5000.
  int _tldrThreshold = 5000;

  /// Path to the auth.json file for persistent key storage.
  /// Follows XDG: `$XDG_DATA_HOME/crux/auth.json`
  /// (defaults to `~/.local/share/crux/auth.json`).
  late final String authJsonPath;

  ProviderService({
    required this.userProvidersDir,
    this.builtInProvidersDir,
  }) : _loader = ProviderConfigLoader.multi(
           providersDirs: [
             Directory(userProvidersDir),
             if (builtInProvidersDir != null) Directory(builtInProvidersDir!),
           ],
         ) {
    final xdgDataHome =
        Platform.environment['XDG_DATA_HOME'] ??
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

  /// Resolve the [LlmProvider] implementation backing the named provider,
  /// based on its TOML `type`. Returns `null` if the provider is unknown.
  LlmProvider? llmProviderByName(String name) {
    final cfg = _loader.providerByName(name);
    if (cfg == null) return null;
    return resolveProvider(cfg.type).provider;
  }

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
    if (provider.wireFamily == WireFamily.anthropicCompatible) return [];

    // OpenAI-compatible providers expose a /models endpoint
    if (provider.wireFamily == WireFamily.openaiCompatible) {
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

      // Header format varies by auth style:
      //   Bearer:             Authorization: Bearer <key>
      //   Anthropic API key:  x-api-key: <key>
      if (apiKey != null && apiKey.isNotEmpty) {
        final authStyle = resolveProvider(provider.type).authStyle;
        if (authStyle == AuthStyle.bearer) {
          request.headers.set('Authorization', 'Bearer $apiKey');
        } else if (authStyle == AuthStyle.anthropicApiKey) {
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

  /// Returns the last-used model composite key, or null if none has been
  /// set in this session (or persisted in `auth.json`).
  String? get lastUsedModel => _lastUsedModel;

  /// Returns the auxiliary model composite key, or null if not set.
  String? get auxiliaryModel => _auxiliaryModel;

  /// Returns the TLDR threshold in characters.
  int get tldrThreshold => _tldrThreshold;

  /// Persists the given model composite key as the auxiliary model.
  ///
  /// Called when the user selects a model via `/auxiliary`. The value is
  /// stored globally in `auth.json` and persists across sessions.
  Future<void> setAuxiliaryModel(String compositeKey) async {
    _auxiliaryModel = compositeKey;
    await _persistAuthKeys();
  }

  /// Sets the TLDR threshold and persists it to `auth.json`.
  Future<void> setTldrThreshold(int threshold) async {
    _tldrThreshold = threshold;
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
        _tldrThreshold = data['tldrThreshold'] as int? ?? 5000;
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
      'tldrThreshold': _tldrThreshold,
    };
    final content = JsonEncoder.withIndent('  ').convert(data) + '\n';
    final file = File(authJsonPath);
    await file.writeAsString(content);
    try {
      await Process.run('chmod', ['600', authJsonPath]);
    } catch (_) {
      // chmod may not be available on all platforms
    }
  }

}

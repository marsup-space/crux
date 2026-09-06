import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/user_data_directory.dart';
import 'web_service_provider.dart';

/// Owns the set of registered [WebServiceProvider]s and the
/// API keys that back them. Tools (`webfetch`, `websearch`)
/// talk only to this registry — they don't know which provider
/// actually answers the call. To add a new provider, write a
/// class extending [WebServiceProvider] and call [register]
/// from `initServices` in `bin/crux.dart`.
///
/// Key persistence mirrors the existing `ProviderService` flow:
/// - `auth.toml` at `~/.config/crux/auth.toml` (XDG-aware) with
///   `0o600` permissions
/// - Each provider's key sits at the top level under a
///   provider-specific field name (e.g. `TINYFISH_API_KEY`)
/// - Falls back to the matching env var when the file is absent
///   or the field is empty, so CI / container deployments work
///   without editing the file
///
/// The registry is also a `Stream`-based notifier: every
/// `setApiKey` / `removeApiKey` fires a `changes` event so the
/// chat panel can rebuild the `webfetch` / `websearch` tool
/// registrations to match the new key state.
class WebProviderRegistry {
  final Map<String, WebServiceProvider> _providers = {};
  final StreamController<void> _changes = StreamController.broadcast();
  String? _authTomlPath;
  Future<void>? _initialization;

  /// Optional override for the directory holding `auth.toml`.
  /// `null` (the default) means "use `resolveUserDataDirectory()`"
  /// — i.e. honour `XDG_DATA_HOME` / `HOME` / platform defaults.
  /// Tests pass a temp dir to keep persistence isolated.
  final String? userDataDirOverride;

  WebProviderRegistry({this.userDataDirOverride});

  /// Stream of key-change events. New subscribers don't replay
  /// history — they just hear future events.
  Stream<void> get changes => _changes.stream;

  /// All registered providers in registration order.
  List<WebServiceProvider> get allProviders =>
      List.unmodifiable(_providers.values);

  WebServiceProvider? getProvider(String id) => _providers[id];

  /// The provider currently serving search calls. Returns the
  /// first registered provider that supports search and is
  /// configured. Returns `null` if no search-capable provider
  /// is configured.
  ///
  /// For now, the only registered provider is TinyFish which
  /// supports both search and fetch. When multiple search
  /// providers are added, the resolution order becomes:
  /// 1. Explicit user preference (if set via command)
  /// 2. First-registered configured provider
  WebServiceProvider? get activeSearchProvider {
    for (final p in _providers.values) {
      if (p.supportsSearch && p.isConfigured) return p;
    }
    return null;
  }

  /// The provider currently serving fetch calls. See
  /// [activeSearchProvider] for the resolution order.
  WebServiceProvider? get activeFetchProvider {
    for (final p in _providers.values) {
      if (p.supportsFetch && p.isConfigured) return p;
    }
    return null;
  }

  /// True if at least one search-capable provider is configured.
  bool get isAnySearchProviderConfigured => activeSearchProvider != null;

  /// True if at least one fetch-capable provider is configured.
  bool get isAnyFetchProviderConfigured => activeFetchProvider != null;

  /// Register a provider. Idempotent: re-registering the same
  /// id replaces the previous instance (useful for tests).
  void register(WebServiceProvider provider) {
    _providers[provider.id] = provider;
  }

  /// Initialize: load persisted keys from `auth.toml`, push
  /// them to each provider, and pick up env-var fallbacks. Safe
  /// to call more than once; concurrent callers await the same disk read.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final baseDir = userDataDirOverride ?? resolveUserDataDirectory();
    _authTomlPath = p.join(baseDir, 'auth.toml');
    await _loadFromAuthToml();
  }

  /// Look up the persisted (or env) key for a provider, applying
  /// the env-var override if the file value is empty. Returns
  /// `null` when nothing is configured.
  String? getApiKey(String providerId) {
    final p = _providers[providerId];
    if (p == null) return null;
    return p.apiKey;
  }

  /// Persist a key for [providerId] and notify subscribers. The
  /// key is written to `auth.toml` (mode `0o600`) and pushed to
  /// the provider so the next call picks it up immediately.
  Future<void> setApiKey(String providerId, String key) async {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'API key must not be empty');
    }
    final p = _providers[providerId];
    if (p == null) {
      throw ArgumentError.value(
        providerId,
        'providerId',
        'No web provider registered with that id',
      );
    }
    p.setApiKey(key);
    await _persist();
    _changes.add(null);
  }

  /// Remove the key for [providerId] and notify subscribers.
  Future<void> removeApiKey(String providerId) async {
    final p = _providers[providerId];
    if (p == null) {
      throw ArgumentError.value(
        providerId,
        'providerId',
        'No web provider registered with that id',
      );
    }
    p.setApiKey(null);
    await _persist();
    _changes.add(null);
  }

  /// Close the underlying stream. Call from app shutdown.
  Future<void> dispose() async {
    await _changes.close();
  }

  // ──────────────────────── Persistence ────────────────────────

  /// Read `auth.toml` and apply persisted keys to providers.
  /// Each provider looks up its own field via [keyEnvFieldName].
  /// Lines we don't recognize are left in place — we only
  /// rewrite the file on the next `setApiKey` / `removeApiKey`.
  Future<void> _loadFromAuthToml() async {
    final path = _authTomlPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      var anyLoaded = false;
      for (final provider in _providers.values) {
        final fieldName = _keyEnvFieldName(provider.id);
        final match = RegExp(
          '^\\s*${RegExp.escape(fieldName)}\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"\\s*\$',
          multiLine: true,
        ).firstMatch(content);
        if (match != null) {
          provider.setApiKey(_unescapeToml(match.group(1)!));
          anyLoaded = true;
        }
      }
      if (anyLoaded) {
        // Notify subscribers so listeners — most importantly
        // the chat panel's `_webProviderChangesSub` — can
        // re-evaluate tool availability. `setApiKey` /
        // `removeApiKey` fire this for runtime mutations, but
        // the load-from-disk path is the *first* place the key
        // shows up in memory and would otherwise stay invisible
        // to listeners. Symptom: a cold start with a persisted
        // key in `auth.toml` would have `websearch` permanently
        // missing from the LLM's tool list, because
        // `registerWebTools` ran before `initialize()` resolved.
        _changes.add(null);
      }
    } on FileSystemException {
      // Permission errors / corrupt file — ignore, treat as
      // unconfigured.
    }
  }

  /// Rewrite `auth.toml` with the current in-memory key state.
  /// All other content (LLM-provider keys, `lastUsedModel`, …)
  /// is preserved byte-for-byte.
  Future<void> _persist() async {
    final path = _authTomlPath;
    if (path == null) return;
    final file = File(path);
    String existing = '';
    if (await file.exists()) {
      existing = await file.readAsString();
    } else {
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
    }

    // Strip only the top-level key lines we own.
    final ownedFieldNames = _providers.values
        .map((p) => _keyEnvFieldName(p.id))
        .toSet();
    final stripped = existing
        .split('\n')
        .where((line) {
          final trimmed = line.trimLeft();
          for (final field in ownedFieldNames) {
            if (trimmed.startsWith('$field =')) return false;
          }
          return true;
        })
        .join('\n');

    final additions = StringBuffer();
    for (final provider in _providers.values) {
      final key = provider.apiKey;
      if (key == null || key.isEmpty) continue;
      additions.write(
        '${_keyEnvFieldName(provider.id)} = ${_tomlEscape(key)}\n',
      );
    }

    String next;
    if (additions.isEmpty) {
      next = stripped;
    } else {
      if (stripped.trim().isEmpty) {
        next = additions.toString();
      } else {
        next = stripped.endsWith('\n')
            ? '$stripped${additions.toString()}'
            : '$stripped\n${additions.toString()}';
      }
    }

    await file.writeAsString(next);
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {
      // chmod may not be available (e.g. Windows); ignore.
    }
  }

  /// The env-var-style key name we persist under in `auth.toml`.
  /// Mirrors the convention for LLM-provider keys
  /// (`CRUX_API_KEY_<NAME>`) but kept distinct from that
  /// namespace to avoid collision: web providers use their
  /// own documented env-var name (e.g. `TINYFISH_API_KEY`).
  /// New providers should override this to return their
  /// canonical env var.
  String _keyEnvFieldName(String providerId) {
    switch (providerId) {
      case 'tinyfish':
        return 'TINYFISH_API_KEY';
      default:
        // Generic fallback for new providers without an
        // override. Providers are encouraged to declare their
        // own canonical name.
        return '${providerId.toUpperCase()}_API_KEY';
    }
  }

  static String _tomlEscape(String s) {
    final escaped = s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\b', '\\b')
        .replaceAll('\f', '\\f')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }

  static String _unescapeToml(String s) {
    final buf = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == r'\' && i + 1 < s.length) {
        final next = s[i + 1];
        switch (next) {
          case 'b':
            buf.write('\b');
            break;
          case 'f':
            buf.write('\f');
            break;
          case 'n':
            buf.write('\n');
            break;
          case 'r':
            buf.write('\r');
            break;
          case 't':
            buf.write('\t');
            break;
          case '"':
            buf.write('"');
            break;
          case '\\':
            buf.write('\\');
            break;
          default:
            buf.write(next);
        }
        i += 2;
      } else {
        buf.write(c);
        i++;
      }
    }
    return buf.toString();
  }
}

import 'dart:io';

/// Detected system HTTP/HTTPS proxy configuration.
///
/// At most one of [httpUrl] / [httpsUrl] will be non-null; in most real
/// deployments (Clash, Surge, mitmproxy, Charles, ...) both fields point
/// at the same listening port, because the local proxy accepts both HTTP
/// and HTTPS traffic through the same socket.
///
/// [noProxy] is the bypass list (`NO_PROXY` / `no_proxy` env var, or
/// `ExceptionsList` from `scutil --proxy`, or `ProxyOverride` from the
/// Windows registry). Entries support:
/// - `*` — match every host
/// - `<local>` — match hostnames without a dot (curl / Go semantics)
/// - `example.com` — exact match
/// - `.example.com` / `example.com` — match the host and any subdomain
///   (the leading dot is optional but accepted)
/// - Plain IPs — exact match
/// - CIDR (`192.168.0.0/16`) is intentionally not supported; the common
///   bypass entries from the OS GUI use bare hostnames.
class SystemProxy {
  /// Proxy URL for `http://` requests, e.g. `http://127.0.0.1:7897`.
  final String? httpUrl;

  /// Proxy URL for `https://` requests. Most local proxies use the same
  /// URL for both schemes; this is held separately so a deployment with
  /// scheme-split proxies (uncommon) still works.
  final String? httpsUrl;

  /// Hosts that should be reached directly, bypassing the proxy.
  final List<String> noProxy;

  const SystemProxy({
    this.httpUrl,
    this.httpsUrl,
    this.noProxy = const [],
  });

  bool get isEmpty => httpUrl == null && httpsUrl == null;
  bool get isNotEmpty => !isEmpty;

  /// Returns the `HttpClient.findProxy` return value for [uri].
  ///
  /// - `DIRECT` for hosts in the [noProxy] bypass list.
  /// - `PROXY host:port` for the scheme that has a URL configured.
  /// - `DIRECT` if no proxy is configured for the requested scheme.
  String findProxyFor(Uri uri) {
    final host = uri.host;
    if (host.isNotEmpty &&
        _matchesNoProxy(host.toLowerCase(), noProxy)) {
      return 'DIRECT';
    }
    final url = uri.scheme == 'https' ? httpsUrl : httpUrl;
    if (url == null) return 'DIRECT';
    final hostPort = _hostPortFromUrl(url);
    if (hostPort == null) return 'DIRECT';
    return 'PROXY $hostPort';
  }

  @override
  String toString() {
    final parts = <String>[];
    if (httpUrl != null) parts.add('http=$httpUrl');
    if (httpsUrl != null) parts.add('https=$httpsUrl');
    if (noProxy.isNotEmpty) parts.add('noProxy=$noProxy');
    return 'SystemProxy(${parts.join(', ')})';
  }
}

String? _hostPortFromUrl(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null) return null;
  if (parsed.host.isEmpty) return null;
  if (parsed.hasPort) return '${parsed.host}:${parsed.port}';
  return parsed.host;
}

/// Case-insensitive match of [hostLower] against any entry in [noProxy].
/// See [SystemProxy] for the supported entry shapes.
bool _matchesNoProxy(String hostLower, List<String> noProxy) {
  if (noProxy.isEmpty) return false;
  for (final raw in noProxy) {
    final entry = raw.trim().toLowerCase();
    if (entry.isEmpty) continue;
    if (entry == '*') return true;
    if (entry == '<local>') {
      // curl / Go: <local> matches every hostname that does NOT contain
      // a dot, i.e. hostnames resolved through the local resolver.
      if (!hostLower.contains('.')) return true;
      continue;
    }
    // Normalize wildcarded forms: `*.example.com` and `.example.com`
    // are both equivalent to "example.com and any subdomain". After
    // normalization we do an exact match and a suffix match.
    var bare = entry;
    if (bare.startsWith('*.')) bare = bare.substring(2);
    if (bare.startsWith('.')) bare = bare.substring(1);
    if (bare.isEmpty) continue;
    if (hostLower == bare) return true;
    if (hostLower.endsWith('.$bare')) return true;
  }
  return false;
}

/// Detects the HTTP/HTTPS proxy configured by the OS or by environment
/// variables. The result is cached for the lifetime of the process.
///
/// Detection order (highest priority first):
/// 1. **Environment variables** — `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`
///    and `NO_PROXY` / `no_proxy` (case-insensitive; uppercase wins on
///    conflict). These are the most explicit, and many CI environments
///    set them.
/// 2. **OS-level configuration** — fills in anything missing from #1:
///    - macOS: `scutil --proxy`
///    - Linux: GNOME `gsettings get org.gnome.system.proxy ...`
///    - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet
///      Settings` (the registry key the IE settings panel writes).
///
/// Returns `null` if no proxy is detected anywhere — callers should
/// treat `null` as "no fallback available" and not retry the request.
class SystemProxyDetector {
  static SystemProxy? _cached;
  static SystemProxy? _testingOverride;
  static bool _hasTestingOverride = false;

  /// Returns the detected system proxy, or `null` if none.
  ///
  /// The result is cached; the first call shells out to the OS helper
  /// (scutil / gsettings / reg). Subsequent calls return the cached
  /// value. Use [resetForTesting] in tests to force re-detection.
  static SystemProxy? detect() {
    if (_hasTestingOverride) return _testingOverride;
    if (_cached != null) return _cached;
    final detected = _detect(Platform.environment);
    if (detected != null && detected.isNotEmpty) {
      _cached = detected;
    }
    return _cached;
  }

  /// Clears the cache and any test override. Tests use this to force
  /// re-detection after mutating [Platform.environment] (e.g. via
  /// `withEnvironment` from `package:test`).
  static void resetForTesting() {
    _cached = null;
    _testingOverride = null;
    _hasTestingOverride = false;
  }

  /// Forces [detect] to return [proxy] until [resetForTesting] is
  /// called. Pass `null` to simulate "no system proxy configured" —
  /// the override is sticky and supersedes real detection even if
  /// the OS actually has a proxy set.
  static void overrideForTesting(SystemProxy? proxy) {
    _testingOverride = proxy;
    _hasTestingOverride = true;
    _cached = null;
  }

  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  static SystemProxy? _detect(Map<String, String> env) {
    final fromEnv = _detectFromEnv(env);
    final fromOs = _detectFromOs();
    return _merge(fromEnv, fromOs);
  }

  /// Reads `HTTP(S)_PROXY` / `ALL_PROXY` / `NO_PROXY` from [env].
  /// Exposed (internal) so tests can inject a fake environment without
  /// mutating the real [Platform.environment].
  static SystemProxy? _detectFromEnv(Map<String, String> env) {
    String? pick(List<String> names) {
      for (final n in names) {
        final v = env[n];
        if (v != null && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final https = pick(const ['HTTPS_PROXY', 'https_proxy']);
    final http = pick(const ['HTTP_PROXY', 'http_proxy']);
    final all = pick(const ['ALL_PROXY', 'all_proxy']);
    final noProxyRaw = pick(const ['NO_PROXY', 'no_proxy']) ?? '';

    if (https == null && http == null && all == null) return null;

    final noProxy = noProxyRaw
        .split(RegExp(r'[,\s]+'))
        .where((e) => e.isNotEmpty)
        .toList();

    return SystemProxy(
      httpUrl: http ?? all,
      httpsUrl: https ?? all,
      noProxy: noProxy,
    );
  }

  static SystemProxy? _detectFromOs() {
    if (Platform.isMacOS) return _detectFromMacOs();
    if (Platform.isLinux) return _detectFromLinux();
    if (Platform.isWindows) return _detectFromWindows();
    return null;
  }

  // ─── macOS ──────────────────────────────────────────────────────────────

  static SystemProxy? _detectFromMacOs() {
    final result = _runSync('scutil', ['--proxy']);
    if (result == null) return null;
    return _parseScutilOutput(result);
  }

  /// Parse the output of `scutil --proxy`. The format is a plist-style
  /// dictionary, e.g.:
  ///
  ///     <dictionary> {
  ///       HTTPEnable : 1
  ///       HTTPProxy : 127.0.0.1
  ///       HTTPPort : 7897
  ///       HTTPSEnable : 1
  ///       HTTPSProxy : 127.0.0.1
  ///       HTTPSPort : 7897
  ///       ExceptionsList : <array> {
  ///         0 : 127.0.0.1
  ///         1 : 192.168.0.0/16
  ///         ...
  ///       }
  ///       SOCKSEnable : 1
  ///       SOCKSProxy : 127.0.0.1
  ///       SOCKSPort : 7897
  ///     }
  ///
  /// We ignore SOCKS — Dart's [HttpClient.findProxy] supports a
  /// `SOCKS host:port` form, but every local proxy on macOS that
  /// users run also exposes an HTTP/HTTPS listener, and the LLM/web
  /// stacks we talk to are all plain HTTPS, so the HTTP(S) entries
  /// are what we want.
  static SystemProxy? _parseScutilOutput(String output) {
    bool? httpEnable, httpsEnable;
    String? httpHost, httpsHost;
    int? httpPort, httpsPort;
    final exceptions = <String>[];

    final lines = output.split('\n');
    var inArray = false;
    String? arrayKey;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('<array>')) {
        inArray = true;
        continue;
      }
      if (line.startsWith('</array>')) {
        inArray = false;
        arrayKey = null;
        continue;
      }
      if (inArray) {
        // <indent>0 : <value>
        final colon = line.indexOf(':');
        if (colon > 0 && arrayKey == 'ExceptionsList') {
          final v = line.substring(colon + 1).trim();
          if (v.isNotEmpty) exceptions.add(v);
        }
        continue;
      }

      // <key> : <value>
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();

      switch (key) {
        case 'HTTPEnable':
          httpEnable = value == '1';
        case 'HTTPSEnable':
          httpsEnable = value == '1';
        case 'HTTPProxy':
          httpHost = value.isEmpty ? null : value;
        case 'HTTPSProxy':
          httpsHost = value.isEmpty ? null : value;
        case 'HTTPPort':
          httpPort = int.tryParse(value);
        case 'HTTPSPort':
          httpsPort = int.tryParse(value);
        case 'ExceptionsList':
          arrayKey = 'ExceptionsList';
      }
    }

    String? httpUrl;
    if (httpEnable == true && httpHost != null && httpPort != null) {
      httpUrl = 'http://$httpHost:$httpPort';
    }
    String? httpsUrl;
    if (httpsEnable == true && httpsHost != null && httpsPort != null) {
      // Use the http:// scheme in the proxy URL — the proxy itself
      // accepts CONNECT for HTTPS, the URL just describes the
      // hop-to-the-proxy connection.
      httpsUrl = 'http://$httpsHost:$httpsPort';
    }

    if (httpUrl == null && httpsUrl == null) return null;
    return SystemProxy(
      httpUrl: httpUrl,
      httpsUrl: httpsUrl,
      noProxy: exceptions,
    );
  }

  // ─── Linux (GNOME) ──────────────────────────────────────────────────────

  static SystemProxy? _detectFromLinux() {
    // Most desktop distros run GNOME. Other desktops (KDE, XFCE, ...)
    // also proxy through the same `HTTP_PROXY` env var convention,
    // which is already covered by [_detectFromEnv].
    final mode = _gsettingsGet('org.gnome.system.proxy', 'mode');
    if (mode == null || mode == "'none'") return null;

    if (mode == "'manual'") {
      final httpHost = _gsettingsGet('org.gnome.system.proxy.http', 'host');
      final httpPort = _gsettingsGet('org.gnome.system.proxy.http', 'port');
      final httpsHost =
          _gsettingsGet('org.gnome.system.proxy.https', 'host');
      final httpsPort =
          _gsettingsGet('org.gnome.system.proxy.https', 'port');
      final ignore = _gsettingsGet('org.gnome.system.proxy', 'ignore-hosts');

      String? httpUrl;
      if (httpHost != null && httpPort != null) {
        httpUrl = 'http://${_unquote(httpHost)}:${_unquote(httpPort)}';
      }
      String? httpsUrl;
      if (httpsHost != null && httpsPort != null) {
        httpsUrl = 'http://${_unquote(httpsHost)}:${_unquote(httpsPort)}';
      }

      if (httpUrl == null && httpsUrl == null) return null;
      return SystemProxy(
        httpUrl: httpUrl,
        httpsUrl: httpsUrl,
        noProxy: _parseGsettingsArray(ignore),
      );
    }

    // 'auto' mode (PAC URL) is intentionally skipped: we'd have to fetch
    // and evaluate the PAC file to know the per-host proxy, which is
    // out of scope for a single retry.
    return null;
  }

  /// Returns the raw stdout of `gsettings get <schema> <key>`, with the
  /// trailing newline stripped. `null` if gsettings isn't installed or
  /// the key has no value.
  static String? _gsettingsGet(String schema, String key) {
    final result = _runSync('gsettings', ['get', schema, key]);
    if (result == null) return null;
    final trimmed = result.trim();
    if (trimmed.isEmpty) return null;
    // gsettings prints empty arrays as either `[]` or `@as []`.
    if (trimmed == '[]' || trimmed == '@as []') return null;
    return trimmed;
  }

  /// Parses a gsettings array literal. Examples we accept:
  ///   ['localhost', '127.0.0.1', '.local']
  ///   ["foo", "bar"]
  static List<String> _parseGsettingsArray(String? gsettingsValue) {
    if (gsettingsValue == null) return const [];
    if (gsettingsValue == '[]' || gsettingsValue == '@as []') {
      return const [];
    }
    if (!gsettingsValue.startsWith('[') ||
        !gsettingsValue.endsWith(']')) {
      return const [];
    }
    final body = gsettingsValue.substring(
      1,
      gsettingsValue.length - 1,
    );
    final out = <String>[];
    for (final match in RegExp(r"'([^']*)'").allMatches(body)) {
      out.add(match.group(1)!);
    }
    for (final match in RegExp(r'"([^"]*)"').allMatches(body)) {
      out.add(match.group(1)!);
    }
    return out;
  }

  static String _unquote(String s) {
    if (s.length >= 2) {
      if ((s.startsWith("'") && s.endsWith("'")) ||
          (s.startsWith('"') && s.endsWith('"'))) {
        return s.substring(1, s.length - 1);
      }
    }
    return s;
  }

  // ─── Windows ────────────────────────────────────────────────────────────

  /// The IE settings panel writes the user's proxy configuration to
  /// this key. We read the same key the OS uses.
  static const String _winInternetSettingsKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static SystemProxy? _detectFromWindows() {
    final enableRaw = _regQuery(_winInternetSettingsKey, 'ProxyEnable');
    if (enableRaw == null) return null;
    if (!enableRaw.contains('0x1')) return null;

    final serverRaw = _regQuery(_winInternetSettingsKey, 'ProxyServer');
    if (serverRaw == null) return null;
    final serverValue = _extractRegSzValue(serverRaw, 'ProxyServer');
    if (serverValue == null || serverValue.isEmpty) return null;

    String? httpUrl;
    String? httpsUrl;
    if (serverValue.contains('=')) {
      // Scheme-split: "http=127.0.0.1:7897;https=127.0.0.1:7897;socks=..."
      for (final part in serverValue.split(';')) {
        final eq = part.indexOf('=');
        if (eq < 0) continue;
        final scheme = part.substring(0, eq).trim().toLowerCase();
        final hp = part.substring(eq + 1).trim();
        if (scheme == 'http') httpUrl = 'http://$hp';
        if (scheme == 'https') httpsUrl = 'http://$hp';
        // SOCKS intentionally ignored — see macOS section.
      }
    } else {
      // Single value: applies to all schemes.
      httpUrl = 'http://$serverValue';
      httpsUrl = 'http://$serverValue';
    }

    final overrideRaw = _regQuery(_winInternetSettingsKey, 'ProxyOverride');
    final noProxy = <String>[];
    if (overrideRaw != null) {
      final overrideValue = _extractRegSzValue(overrideRaw, 'ProxyOverride');
      if (overrideValue != null && overrideValue.isNotEmpty) {
        noProxy.addAll(
          overrideValue
              .split(RegExp(r'[;\s]+'))
              .where((e) => e.isNotEmpty && e != '<local>'),
        );
        if (overrideValue.contains('<local>')) {
          noProxy.add('<local>');
        }
      }
    }

    if (httpUrl == null && httpsUrl == null) return null;
    return SystemProxy(
      httpUrl: httpUrl,
      httpsUrl: httpsUrl,
      noProxy: noProxy,
    );
  }

  static String? _regQuery(String key, String valueName) {
    final result = _runSync('reg', [
      'query',
      key,
      '/v',
      valueName,
    ]);
    return result;
  }

  /// `reg query` prints one value per line as:
  ///
  ///         name         REG_type        data...
  ///
  /// We want the trailing data (which may contain spaces).
  static String? _extractRegSzValue(String regOutput, String valueName) {
    for (final raw in regOutput.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith(valueName)) continue;
      // Skip past the name and the REG_* type.
      final tail = line.substring(valueName.length).trim();
      // tail now looks like:  REG_SZ    127.0.0.1:7897
      final spaceAfterType = tail.indexOf(RegExp(r'\s{2,}'));
      if (spaceAfterType < 0) return null;
      return tail.substring(spaceAfterType).trim();
    }
    return null;
  }

  // ─── shared ─────────────────────────────────────────────────────────────

  /// Runs [executable] with [args] synchronously. Returns stdout (with
  /// trailing whitespace stripped), or `null` if the binary isn't
  /// installed or returned non-zero.
  static String? _runSync(String executable, List<String> args) {
    try {
      final result = Process.runSync(executable, args);
      if (result.exitCode != 0) return null;
      return result.stdout.toString();
    } on ProcessException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Combines env-var detection with OS-level detection, taking env
  /// first (it's the more explicit signal).
  static SystemProxy? _merge(SystemProxy? env, SystemProxy? os) {
    if (env == null) return os;
    if (os == null) return env;
    return SystemProxy(
      httpUrl: env.httpUrl ?? os.httpUrl,
      httpsUrl: env.httpsUrl ?? os.httpsUrl,
      noProxy: <String>[...env.noProxy, ...os.noProxy],
    );
  }
}

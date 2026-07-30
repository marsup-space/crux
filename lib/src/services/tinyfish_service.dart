import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/proxy_aware_http.dart';
import '../utils/user_data_directory.dart';

/// Single source of truth for the TinyFish API key and HTTP access.
///
/// Used by the [WebFetchTool] and [WebSearchTool] tools to fetch pages
/// and search the web. The key is persisted in `auth.toml` (alongside
/// the LLM-provider keys) at `~/.config/crux/auth.toml` with `0o600`
/// permissions, and falls back to the `TINYFISH_API_KEY` environment
/// variable when the file is not set.
///
/// The service also implements 429/5xx backoff retry per the TinyFish
/// rate-limit policy: prefer the `Retry-After` response header when
/// present, otherwise exponential backoff (1s, 2s, 4s), max 3
/// attempts. Non-retriable errors (4xx other than 429) propagate
/// immediately so the LLM sees a clear failure message.
class TinyFishService {
  static const String searchEndpoint = 'https://api.search.tinyfish.ai';
  static const String fetchEndpoint = 'https://api.fetch.tinyfish.ai';
  static const String envKeyName = 'TINYFISH_API_KEY';

  /// Maximum number of total attempts per request (initial + retries).
  static const int _maxAttempts = 3;

  /// Backoff schedule for the second and third attempts (first retry
  /// uses [BackoffStep.firstDelaySeconds], etc). Used when the response
  /// has no `Retry-After` header.
  static const List<int> _backoffSeconds = [1, 2, 4];

  String? _apiKey;
  String? _authTomlPath;

  /// The persisted key. `null` when no key is configured.
  String? get apiKey => _apiKey;

  /// True when an API key is available (in-memory or environment).
  bool get isConfigured {
    final k = _effectiveKey();
    return k != null && k.isNotEmpty;
  }

  /// Initialize the service: locate the auth.toml file and load any
  /// persisted key. Safe to call multiple times; only the first call
  /// reads the disk. Always also picks up the `TINYFISH_API_KEY` env
  /// var — the env var takes precedence over the persisted value so
  /// CI / container deployments can override without editing the
  /// file.
  Future<void> initialize() async {
    if (_authTomlPath != null) return;
    _authTomlPath = p.join(resolveUserDataDirectory(), 'auth.toml');
    await _loadFromAuthToml();
  }

  /// Set the API key in memory and persist it to `auth.toml`. The TOML
  /// file is read fresh first so we don't clobber unrelated settings
  /// (`lastUsedModel`, `auxiliaryModel`, other LLM-provider keys).
  /// Creates the user data dir if missing. Best-effort `0o600`
  /// permissions via `chmod` (silently skipped on Windows / when
  /// `chmod` isn't on PATH).
  Future<void> setApiKey(String key) async {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'API key must not be empty');
    }
    _apiKey = key;
    await _persist();
  }

  /// Remove the API key from memory and from `auth.toml`. Idempotent.
  Future<void> removeApiKey() async {
    _apiKey = null;
    await _persist();
  }

  /// Returns the key to use for the next request, preferring the
  /// in-memory value, then the env var, then `null`.
  String? _effectiveKey() {
    if (_apiKey != null && _apiKey!.isNotEmpty) return _apiKey;
    final env = Platform.environment[envKeyName];
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  /// ─────────────────────────── Search ───────────────────────────

  /// Run a web search against TinyFish. Returns parsed [TinyFishSearchResponse].
  /// Throws [TinyFishException] for non-retriable errors or after all
  /// retries are exhausted.
  Future<TinyFishSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    final params = <String, String>{'query': query};
    if (location != null && location.isNotEmpty) params['location'] = location;
    if (language != null && language.isNotEmpty) params['language'] = language;
    if (page != null) params['page'] = '$page';
    if (includeThumbnail) params['include_thumbnail'] = 'true';

    final uri = Uri.parse(searchEndpoint).replace(queryParameters: params);
    final body = await _requestWithRetry('GET', uri, expectJson: true);
    final json = jsonDecode(body) as Map<String, dynamic>;
    return TinyFishSearchResponse.fromJson(json);
  }

  /// ─────────────────────────── Fetch ───────────────────────────

  /// Fetch and extract clean content from up to 10 URLs.
  /// `format` defaults to `markdown` (recommended for LLM consumers).
  /// Throws [TinyFishException] on failure.
  Future<TinyFishFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) async {
    if (urls.isEmpty) {
      throw ArgumentError.value(urls, 'urls', 'must contain at least one URL');
    }
    if (urls.length > 10) {
      throw ArgumentError.value(
        urls,
        'urls',
        'TinyFish Fetch API accepts at most 10 URLs per request',
      );
    }

    final body = <String, dynamic>{
      'urls': urls,
      'format': format,
      'links': links,
      'image_links': imageLinks,
    };
    if (ttl != null) body['ttl'] = ttl;
    if (perUrlTimeoutMs != null) body['per_url_timeout_ms'] = perUrlTimeoutMs;

    final uri = Uri.parse(fetchEndpoint);
    final responseBody = await _requestWithRetry(
      'POST',
      uri,
      expectJson: true,
      jsonBody: body,
    );
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    return TinyFishFetchResponse.fromJson(json);
  }

  /// ──────────────────────── HTTP core ─────────────────────────

  /// Single HTTP request with the 429/5xx backoff loop. The proxy
  /// retry is layered on top by [withProxyRetry] so direct-then-proxy
  /// is tried for every attempt.
  ///
  /// Returns the response body as a UTF-8 string. Throws
  /// [TinyFishException] for non-retriable errors or when all
  /// attempts fail.
  Future<String> _requestWithRetry(
    String method,
    Uri uri, {
    required bool expectJson,
    Map<String, dynamic>? jsonBody,
  }) async {
    final key = _effectiveKey();
    if (key == null) {
      throw const TinyFishException(
        'TinyFish API key not configured. '
        'Run `/web-provider tinyfish key <key>` or '
        'set TINYFISH_API_KEY.',
      );
    }

    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        return await withProxyRetry<String>(
          enabled: isSystemProxyFallbackGloballyEnabled(),
          attempt: (proxy) async {
            final client = HttpClient();
            client.connectionTimeout = const Duration(seconds: 30);
            if (proxy != null) client.findProxy = proxy.findProxyFor;
            try {
              final request = await client.openUrl(method, uri);
              request.headers.set('X-API-Key', key);
              if (expectJson || jsonBody != null) {
                request.headers.set('Content-Type', 'application/json');
              }
              if (jsonBody != null) {
                request.write(jsonEncode(jsonBody));
              }
              final response = await request.close();
              final body = await response.transform(utf8.decoder).join();
              final status = response.statusCode;

              if (status >= 200 && status < 300) {
                return body;
              }

              // Read Retry-After header (seconds or HTTP date) before
              // throwing.
              final retryAfterHeader = response.headers.value('Retry-After');
              final retryAfterSec = _parseRetryAfter(retryAfterHeader);

              // 429 + transient 5xx -> retriable. Anything else -> final.
              final retriable =
                  status == 429 ||
                  status == 502 ||
                  status == 503 ||
                  status == 504;
              throw _HttpStatusException(
                status,
                body,
                retriable: retriable,
                retryAfterSec: retryAfterSec,
              );
            } finally {
              client.close(force: true);
            }
          },
        );
      } on _HttpStatusException catch (e) {
        lastError = e;
        if (!e.retriable) {
          throw TinyFishException(_formatHttpError(e));
        }
        // Honor Retry-After if present, else use the backoff schedule.
        final delaySec = e.retryAfterSec ?? _backoffSeconds[attempt];
        if (attempt < _maxAttempts - 1) {
          await Future.delayed(Duration(seconds: delaySec));
        }
      } on IOException catch (e) {
        // withProxyRetry already handles proxy fallback, so an
        // IOException at this point means the proxy didn't help
        // either. Treat as a final failure.
        throw TinyFishException('Network error talking to TinyFish: $e');
      } on TimeoutException catch (e) {
        throw TinyFishException('Timeout talking to TinyFish: $e');
      }
    }
    throw TinyFishException(
      'TinyFish request failed after $_maxAttempts attempts. '
      'Last error: $lastError',
    );
  }

  /// ──────────────────────── Persistence ────────────────────────

  /// Read `auth.toml` and pick up any persisted `TINYFISH_API_KEY`
  /// at the top level. Doesn't touch the `[apiKeys]` section — the
  /// TinyFish key is stored at the root for clarity.
  Future<void> _loadFromAuthToml() async {
    final path = _authTomlPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      // Cheap parser: we only look for `TINYFISH_API_KEY = "..."`
      // at the top level (not inside [apiKeys]). Same approach as
      // the ProviderService's own auth reading: re-parse the
      // whole file as TOML when present, but here we only need one
      // field, so a regex is enough and avoids depending on a TOML
      // package surface we don't use anywhere else in this file.
      final match = RegExp(
        r'^\s*TINYFISH_API_KEY\s*=\s*"((?:[^"\\]|\\.)*)"\s*$',
        multiLine: true,
      ).firstMatch(content);
      if (match != null) {
        _apiKey = _unescapeToml(match.group(1)!);
      }
    } on FileSystemException {
      // Permission errors / corrupt file — ignore, treat as unconfigured.
    }
  }

  /// Read the existing auth.toml (if any), update only the
  /// TINYFISH_API_KEY line at the top level, and write it back.
  /// Preserves everything else byte-for-byte where possible.
  Future<void> _persist() async {
    final path = _authTomlPath;
    if (path == null) return;
    final file = File(path);
    String existing = '';
    if (await file.exists()) {
      existing = await file.readAsString();
    } else {
      // Ensure the user data dir exists before first write.
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
    }

    // Strip any existing TINYFISH_API_KEY line (top-level only).
    final stripped = existing
        .split('\n')
        .where((line) => !RegExp(r'^\s*TINYFISH_API_KEY\s*=').hasMatch(line))
        .join('\n');

    // Build the new key line. If removing, just write the stripped
    // content; if setting, prepend a fresh line.
    String next;
    if (_apiKey == null || _apiKey!.isEmpty) {
      next = stripped;
    } else {
      final keyLine = 'TINYFISH_API_KEY = ${_tomlEscape(_apiKey!)}';
      // If the file already has content, ensure a leading newline
      // before the new key so it doesn't get fused to a previous
      // last line. If empty, no separator needed.
      if (stripped.trim().isEmpty) {
        next = '$keyLine\n';
      } else {
        next = stripped.endsWith('\n')
            ? '$stripped$keyLine\n'
            : '$stripped\n$keyLine\n';
      }
    }

    await file.writeAsString(next);
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {
      // chmod may not be available (e.g. Windows); ignore.
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

  /// Parse the `Retry-After` header. Returns `null` if absent or
  /// malformed. Supports both delta-seconds (`120`) and HTTP-date
  /// formats, but in practice TinyFish sends the integer form.
  static int? _parseRetryAfter(String? header) {
    if (header == null || header.isEmpty) return null;
    final n = int.tryParse(header.trim());
    if (n != null) return n < 0 ? null : n;
    // HTTP date — try to parse and compute delta. Fall through to
    // null on failure (we'd rather retry with the default backoff
    // than crash on a date format).
    try {
      final date = HttpDate.parse(header);
      final delta = date.difference(DateTime.now()).inSeconds;
      return delta > 0 ? delta : null;
    } catch (_) {
      return null;
    }
  }

  static String _formatHttpError(_HttpStatusException e) {
    // Try to surface a useful message from a JSON error body if
    // present, otherwise fall back to status + a short body excerpt.
    try {
      final json = jsonDecode(e.body) as Map<String, dynamic>;
      final err = json['error'];
      if (err is Map<String, dynamic>) {
        final code = err['code'];
        final msg = err['message'];
        if (msg is String) {
          return 'TinyFish $e: ${code ?? ''} $msg'.trim();
        }
      } else if (err is String) {
        return 'TinyFish $e: $err';
      }
    } catch (_) {
      // Body wasn't JSON, fall through.
    }
    final excerpt = e.body.length > 200
        ? '${e.body.substring(0, 200)}…'
        : e.body;
    return 'TinyFish HTTP $e: $excerpt';
  }
}

/// HTTP status that didn't land in 2xx. Carries whether the call
/// should be retried and the `Retry-After` value, if the server
/// provided one.
class _HttpStatusException implements Exception {
  final int statusCode;
  final String body;
  final bool retriable;
  final int? retryAfterSec;

  _HttpStatusException(
    this.statusCode,
    this.body, {
    required this.retriable,
    this.retryAfterSec,
  });

  @override
  String toString() => 'HTTP $statusCode';
}

/// Public-facing error. The `message` is rendered to the LLM as a
/// tool failure so it can react (back off, give up, try a different
/// approach).
class TinyFishException implements Exception {
  final String message;
  const TinyFishException(this.message);
  @override
  String toString() => message;
}

// ────────────────────────── Response models ──────────────────────────

class TinyFishSearchResult {
  final int position;
  final String siteName;
  final String title;
  final String snippet;
  final String url;
  final String? thumbnailUrl;

  const TinyFishSearchResult({
    required this.position,
    required this.siteName,
    required this.title,
    required this.snippet,
    required this.url,
    this.thumbnailUrl,
  });

  factory TinyFishSearchResult.fromJson(Map<String, dynamic> j) {
    return TinyFishSearchResult(
      position: (j['position'] as num).toInt(),
      siteName: j['site_name'] as String? ?? '',
      title: j['title'] as String? ?? '',
      snippet: j['snippet'] as String? ?? '',
      url: j['url'] as String? ?? '',
      thumbnailUrl: j['thumbnail_url'] as String?,
    );
  }
}

class TinyFishSearchResponse {
  final String query;
  final List<TinyFishSearchResult> results;
  final int totalResults;
  final int page;

  const TinyFishSearchResponse({
    required this.query,
    required this.results,
    required this.totalResults,
    required this.page,
  });

  factory TinyFishSearchResponse.fromJson(Map<String, dynamic> j) {
    final results = (j['results'] as List<dynamic>? ?? [])
        .map((e) => TinyFishSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
    return TinyFishSearchResponse(
      query: j['query'] as String? ?? '',
      results: results,
      totalResults: (j['total_results'] as num?)?.toInt() ?? 0,
      page: (j['page'] as num?)?.toInt() ?? 0,
    );
  }
}

class TinyFishFetchResult {
  final String url;
  final String? finalUrl;
  final String? title;
  final String? description;
  final String? language;
  final String? author;
  final String? publishedDate;
  final String? text;
  final String? format;
  final int? latencyMs;

  const TinyFishFetchResult({
    required this.url,
    this.finalUrl,
    this.title,
    this.description,
    this.language,
    this.author,
    this.publishedDate,
    this.text,
    this.format,
    this.latencyMs,
  });

  factory TinyFishFetchResult.fromJson(Map<String, dynamic> j) {
    return TinyFishFetchResult(
      url: j['url'] as String? ?? '',
      finalUrl: j['final_url'] as String?,
      title: j['title'] as String?,
      description: j['description'] as String?,
      language: j['language'] as String?,
      author: j['author'] as String?,
      publishedDate: j['published_date'] as String?,
      text: j['text'] as String?,
      format: j['format'] as String?,
      latencyMs: (j['latency_ms'] as num?)?.toInt(),
    );
  }
}

class TinyFishFetchError {
  final String url;
  final String error;
  final int? status;

  const TinyFishFetchError({
    required this.url,
    required this.error,
    this.status,
  });

  factory TinyFishFetchError.fromJson(Map<String, dynamic> j) {
    return TinyFishFetchError(
      url: j['url'] as String? ?? '',
      error: j['error'] as String? ?? 'unknown',
      status: (j['status'] as num?)?.toInt(),
    );
  }
}

class TinyFishFetchResponse {
  final List<TinyFishFetchResult> results;
  final List<TinyFishFetchError> errors;

  const TinyFishFetchResponse({required this.results, required this.errors});

  factory TinyFishFetchResponse.fromJson(Map<String, dynamic> j) {
    return TinyFishFetchResponse(
      results: (j['results'] as List<dynamic>? ?? [])
          .map((e) => TinyFishFetchResult.fromJson(e as Map<String, dynamic>))
          .toList(),
      errors: (j['errors'] as List<dynamic>? ?? [])
          .map((e) => TinyFishFetchError.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/proxy_aware_http.dart';
import '../web_service_provider.dart';

/// TinyFish [WebServiceProvider] implementation — supports both web
/// search (`https://api.search.tinyfish.ai`) and page fetch
/// (`https://api.fetch.tinyfish.ai`) with a single API key.
///
/// Search and Fetch are both billed as "Free" on TinyFish's
/// pricing page — no credits consumed, and the free tier
/// allows 30 search req/min and 150 fetch URLs/min. The
/// 429/5xx backoff retry here is sized to fit comfortably
/// under those limits (initial + 2 retries = 3 attempts max).
class TinyFishWebProvider extends WebServiceProvider {
  static const String providerId = 'tinyfish';

  static const String _searchEndpoint = 'https://api.search.tinyfish.ai';
  static const String _fetchEndpoint = 'https://api.fetch.tinyfish.ai';
  static const String _envKeyName = 'TINYFISH_API_KEY';

  /// Maximum number of total attempts per request (initial + retries).
  static const int _maxAttempts = 3;

  /// Backoff schedule for the second and third attempts. Used when
  /// the response has no `Retry-After` header.
  static const List<int> _backoffSeconds = [1, 2, 4];

  /// Environment-var lookup. Default reads [Platform.environment];
  /// tests inject a fake map so they don't need to mutate the
  /// real (unmodifiable) process env.
  final Map<String, String> Function() _envLookup;

  TinyFishWebProvider({Map<String, String> Function()? envLookup})
      : _envLookup = envLookup ?? (() => Platform.environment);

  @override
  String get id => providerId;

  @override
  String get displayName => 'TinyFish';

  @override
  bool get supportsSearch => true;

  @override
  bool get supportsFetch => true;

  @override
  String? get apiKey {
    final mem = super.apiKey;
    if (mem != null && mem.isNotEmpty) return mem;
    final env = _envLookup()[_envKeyName];
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  // ─────────────────────────── Search ───────────────────────────

  @override
  Future<WebSearchResponse> search({
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

    final uri = Uri.parse(_searchEndpoint).replace(queryParameters: params);
    final body = await _requestWithRetry('GET', uri);
    final json = jsonDecode(body) as Map<String, dynamic>;
    return _parseSearchResponse(json);
  }

  // ─────────────────────────── Fetch ───────────────────────────

  @override
  Future<WebFetchResponse> fetch(
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

    final responseBody =
        await _requestWithRetry('POST', Uri.parse(_fetchEndpoint),
            jsonBody: body);
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    return _parseFetchResponse(json);
  }

  // ──────────────────────── HTTP core ─────────────────────────

  /// Single HTTP request with the 429/5xx backoff loop. The
  /// proxy retry is layered on top by [withProxyRetry] so
  /// direct-then-proxy is tried for every attempt.
  Future<String> _requestWithRetry(
    String method,
    Uri uri, {
    Map<String, dynamic>? jsonBody,
  }) async {
    final key = apiKey;
    if (key == null) {
      throw const WebProviderException(
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
              if (jsonBody != null) {
                request.headers.set('Content-Type', 'application/json');
                request.write(jsonEncode(jsonBody));
              }
              final response = await request.close();
              final body = await response.transform(utf8.decoder).join();
              final status = response.statusCode;

              if (status >= 200 && status < 300) {
                return body;
              }

              // Read Retry-After header (seconds or HTTP date)
              // before throwing.
              final retryAfterHeader = response.headers.value('Retry-After');
              final retryAfterSec = _parseRetryAfter(retryAfterHeader);

              // 429 + transient 5xx -> retriable. Anything else
              // -> final.
              final retriable = status == 429 ||
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
          throw WebProviderException(_formatHttpError(e));
        }
        // Honor Retry-After if present, else use the backoff
        // schedule.
        final delaySec = e.retryAfterSec ?? _backoffSeconds[attempt];
        if (attempt < _maxAttempts - 1) {
          await Future.delayed(Duration(seconds: delaySec));
        }
      } on IOException catch (e) {
        // withProxyRetry already handles proxy fallback, so
        // an IOException at this point means the proxy
        // didn't help either. Treat as a final failure.
        throw WebProviderException(
          'Network error talking to TinyFish: $e',
        );
      } on TimeoutException catch (e) {
        throw WebProviderException('Timeout talking to TinyFish: $e');
      }
    }
    throw WebProviderException(
      'TinyFish request failed after $_maxAttempts attempts. '
      'Last error: $lastError',
    );
  }

  // ──────────────────────── Response parsing ────────────────────────

  static WebSearchResponse _parseSearchResponse(Map<String, dynamic> j) {
    final results = (j['results'] as List<dynamic>? ?? [])
        .map((e) => WebSearchResult(
              position: ((e as Map<String, dynamic>)['position'] as num)
                  .toInt(),
              siteName: e['site_name'] as String? ?? '',
              title: e['title'] as String? ?? '',
              snippet: e['snippet'] as String? ?? '',
              url: e['url'] as String? ?? '',
              thumbnailUrl: e['thumbnail_url'] as String?,
            ))
        .toList();
    return WebSearchResponse(
      query: j['query'] as String? ?? '',
      results: results,
      totalResults: (j['total_results'] as num?)?.toInt() ?? 0,
      page: (j['page'] as num?)?.toInt() ?? 0,
    );
  }

  static WebFetchResponse _parseFetchResponse(Map<String, dynamic> j) {
    final results = (j['results'] as List<dynamic>? ?? [])
        .map((e) => WebFetchResult(
              url: (e as Map<String, dynamic>)['url'] as String? ?? '',
              finalUrl: e['final_url'] as String?,
              title: e['title'] as String?,
              description: e['description'] as String?,
              language: e['language'] as String?,
              author: e['author'] as String?,
              publishedDate: e['published_date'] as String?,
              text: e['text'] as String?,
              format: e['format'] as String?,
              latencyMs: (e['latency_ms'] as num?)?.toInt(),
            ))
        .toList();
    final errors = (j['errors'] as List<dynamic>? ?? [])
        .map((e) => WebFetchError(
              code: (e as Map<String, dynamic>)['error'] as String? ??
                  'unknown',
              url: e['url'] as String? ?? '',
              status: (e['status'] as num?)?.toInt(),
            ))
        .toList();
    return WebFetchResponse(results: results, errors: errors);
  }

  // ──────────────────────── Error formatting ────────────────────────

  static String _formatHttpError(_HttpStatusException e) {
    // Try to surface a useful message from a JSON error body
    // if present, otherwise fall back to status + a short
    // body excerpt.
    try {
      final json = jsonDecode(e.body) as Map<String, dynamic>;
      final err = json['error'];
      if (err is Map<String, dynamic>) {
        final code = err['code'];
        final msg = err['message'];
        if (msg is String) {
          return 'TinyFish HTTP $e: ${code ?? ''} $msg'.trim();
        }
      } else if (err is String) {
        return 'TinyFish HTTP $e: $err';
      }
    } catch (_) {
      // Body wasn't JSON, fall through.
    }
    final excerpt = e.body.length > 200
        ? '${e.body.substring(0, 200)}…'
        : e.body;
    return 'TinyFish HTTP $e: $excerpt';
  }

  /// Parse the `Retry-After` header. Returns `null` if absent
  /// or malformed. Supports both delta-seconds (`120`) and
  /// HTTP-date formats, but in practice TinyFish sends the
  /// integer form.
  static int? _parseRetryAfter(String? header) {
    if (header == null || header.isEmpty) return null;
    final n = int.tryParse(header.trim());
    if (n != null) return n < 0 ? null : n;
    // HTTP date — try to parse and compute delta.
    try {
      final date = HttpDate.parse(header);
      final delta = date.difference(DateTime.now()).inSeconds;
      return delta > 0 ? delta : null;
    } catch (_) {
      return null;
    }
  }
}

/// Internal HTTP status exception — carries the status, body,
/// and a flag for whether the call should be retried.
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

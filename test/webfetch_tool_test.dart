import 'dart:async';
import 'dart:io';

import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/services/web_service_provider.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/webfetch_tool.dart';
import 'package:test/test.dart';

/// Test double for a web fetch provider. Lets the test script
/// per-URL responses (success or error) and records every call.
class _ScriptedFetchProvider extends WebServiceProvider {
  _ScriptedFetchProvider({required this.id});

  /// Per-URL scripted outcome. The provider's `fetch` looks up
  /// the requested URL and either returns a [WebFetchResponse]
  /// with a single [WebFetchResult] (success) or with a
  /// [WebFetchError] entry (failure). When the URL isn't in the
  /// map, defaults to a generic success.
  final Map<String, WebFetchResponse> scripted = {};

  final List<({List<String> urls, String format})> calls = [];

  @override
  final String id;

  @override
  String get displayName => 'ScriptedFetch';

  @override
  bool get supportsSearch => false;

  @override
  bool get supportsFetch => true;

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    throw UnimplementedError('not used in webfetch tests');
  }

  @override
  Future<WebFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) async {
    calls.add((urls: List.unmodifiable(urls), format: format));
    // Merge scripted results per URL: each URL gets its own
    // response entry. For tests that script a whole response,
    // use that; otherwise synthesize a generic success.
    if (urls.length == 1 && scripted.containsKey(urls.first)) {
      return scripted[urls.first]!;
    }
    final results = <WebFetchResult>[];
    for (final url in urls) {
      final resp = scripted[url];
      if (resp != null) {
        results.addAll(resp.results);
      } else {
        results.add(
          WebFetchResult(
            url: url,
            finalUrl: url,
            title: 'Default Title',
            text: 'Default body for $url',
            format: format,
          ),
        );
      }
    }
    return WebFetchResponse(results: results, errors: const []);
  }
}

/// Test double that always throws — exercises error paths.
class _ThrowingFetchProvider extends WebServiceProvider {
  _ThrowingFetchProvider({required this.id, this.error = 'boom'});
  @override
  final String id;
  final String error;

  @override
  String get displayName => 'Throwing';

  @override
  bool get supportsSearch => false;

  @override
  bool get supportsFetch => true;

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<WebFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) async {
    throw WebProviderException(error);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_wf_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ToolContext ctx() => ToolContext(
    sessionId: 1,
    messageId: 1,
    abort: AbortSignal(),
    workingDirectory: tempDir.path,
  );

  WebProviderRegistry registry(WebServiceProvider? provider) {
    final r = WebProviderRegistry(userDataDirOverride: tempDir.path);
    if (provider != null) {
      provider.setApiKey('test-key');
      r.register(provider);
    }
    return r;
  }

  group('WebFetchTool — provider path', () {
    test('renders title, final URL, description, and body in order', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final url = 'https://example.com/page';
      provider.scripted[url] = WebFetchResponse(
        results: [
          WebFetchResult(
            url: url,
            finalUrl: 'https://example.com/canonical',
            title: 'Page Title',
            description: 'A short summary.',
            language: 'en',
            author: 'Alice',
            publishedDate: '2026-01-15',
            text: 'Body text here.',
            format: 'markdown',
            latencyMs: 123,
          ),
        ],
        errors: const [],
      );
      final tool = WebFetchTool(registry(provider));

      final result = await tool.execute({'url': url}, ctx());

      expect(result.title, 'Fetch: $url');
      // Title comes first, then final URL, then meta line, then
      // description, then body.
      final titleIdx = result.output.indexOf('# Page Title');
      final finalUrlIdx = result.output.indexOf(
        'URL: https://example.com/canonical',
      );
      final metaIdx = result.output.indexOf('language: en');
      final descIdx = result.output.indexOf('> A short summary.');
      final bodyIdx = result.output.indexOf('Body text here.');
      expect(titleIdx, greaterThanOrEqualTo(0));
      expect(finalUrlIdx, greaterThan(titleIdx));
      expect(metaIdx, greaterThan(finalUrlIdx));
      expect(descIdx, greaterThan(metaIdx));
      expect(bodyIdx, greaterThan(descIdx));
      expect(result.metadata['provider'], 'tinyfish');
      expect(result.metadata['url'], 'https://example.com/canonical');
      expect(result.metadata['latency_ms'], 123);
      expect(provider.calls, hasLength(1));
      expect(provider.calls.first.urls, [url]);
      expect(provider.calls.first.format, 'markdown');
    });

    test('passes format through to the provider', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));

      await tool.execute({
        'url': 'https://example.com/',
        'format': 'text',
      }, ctx());

      expect(provider.calls.first.format, 'text');
    });

    test('surfaces error from provider when URL is in errors[]', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final url = 'https://example.com/404';
      provider.scripted[url] = WebFetchResponse(
        results: const [],
        errors: [
          WebFetchError(code: 'target_http_error', url: url, status: 404),
        ],
      );
      final tool = WebFetchTool(registry(provider));

      final result = await tool.execute({'url': url}, ctx());

      expect(result.title, 'Error');
      expect(result.output, contains('target_http_error'));
      expect(result.output, contains('(404)'));
      expect(result.output, contains(url));
    });

    test(
      'surfaces WebProviderException directly (no silent fallback)',
      () async {
        final provider = _ThrowingFetchProvider(
          id: 'tinyfish',
          error: 'TinyFish HTTP 503: rate limited',
        );
        final tool = WebFetchTool(registry(provider));

        final result = await tool.execute({
          'url': 'https://example.com/',
        }, ctx());

        expect(result.title, 'Error');
        // The whole point: a provider error must NOT silently
        // fall back to raw HTML. The error message is surfaced
        // verbatim.
        expect(result.output, 'TinyFish HTTP 503: rate limited');
      },
    );

    test('upgrades http:// to https:// before calling the provider', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));

      await tool.execute({'url': 'http://example.com/'}, ctx());

      expect(provider.calls.first.urls, ['https://example.com/']);
    });

    test('rejects missing url', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));
      final result = await tool.execute({}, ctx());
      expect(result.title, 'Error');
      expect(result.output, contains('Missing required parameter: url'));
      expect(provider.calls, isEmpty);
    });
  });

  group('WebFetchTool — raw fallback path', () {
    // The raw fallback path is hard to unit-test without a real
    // server. We exercise the *negative* case: that the raw
    // path is reachable (not blocked) when no provider is
    // configured. The provider is mocked to return isConfigured
    // = false by being absent from the registry.
    //
    // We don't run an actual HTTP request in tests — the
    // fallback is exercised by sending a request to
    // httpstat.us / a non-existent local address, then checking
    // that the failure mode is a network error (not a
    // "provider not configured" error). If a real network
    // request succeeds the test still passes — it just won't
    // assert anything content-specific.

    test(
      'uses raw path when no provider is configured (network failure mode)',
      () async {
        // Pre-set a non-routable URL to avoid hitting the
        // network. 127.0.0.1 on a closed port gives a quick
        // ECONNREFUSED.
        final tool = WebFetchTool(registry(null));
        final result = await tool.execute({
          'url': 'http://127.0.0.1:1/never-listens',
        }, ctx());
        // We expect either a network error (preferred) or a
        // successful fetch. What we DON'T expect is the
        // "provider not configured" message — that's the
        // provider path's failure mode.
        expect(result.output, isNot(contains('provider')));
        // Allow either a fetch success or a network failure.
        expect(
          result.title == 'Error' || result.title.startsWith('Fetch:'),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('blocks cloud-metadata endpoint before any network I/O', () async {
      final tool = WebFetchTool(registry(null));
      final result = await tool.execute({
        'url': 'http://169.254.169.254/latest/meta-data',
        'format': 'raw',
      }, ctx());
      expect(result.title, 'Error');
      expect(result.output, contains('SSRF protection'));
      expect(result.output, contains('169.254.0.0/16'));
    });

    test('blocks metadata endpoint on the https path too', () async {
      final tool = WebFetchTool(registry(null));
      final result = await tool.execute({
        'url': 'https://169.254.169.254/',
      }, ctx());
      expect(result.title, 'Error');
      expect(result.output, contains('SSRF protection'));
    });
  });

  group('WebFetchTool — intranet routing', () {
    // A cloud provider can never reach loopback/private targets,
    // so such URLs must bypass the provider and go to the local
    // raw fetch (SSRF-guarded) even when a provider is configured.
    test('loopback URL bypasses the configured provider', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));
      final result = await tool.execute({
        'url': 'http://127.0.0.1:1/never-listens',
      }, ctx());
      expect(provider.calls, isEmpty);
      // Local raw fetch was attempted and failed fast on the
      // closed port — a network error, not a provider result.
      expect(result.title, 'Error');
      expect(result.output, contains('Failed to fetch URL'));
    });

    test('private-range URL bypasses the configured provider', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));
      // unroutable test-net-ish private address on a closed port;
      // we only assert the provider was NOT consulted.
      await tool.execute({
        'url': 'http://192.168.0.1:1/never-listens',
        'timeout': 2,
      }, ctx());
      expect(provider.calls, isEmpty);
    });

    test('public URL still goes to the provider', () async {
      final provider = _ScriptedFetchProvider(id: 'tinyfish');
      final tool = WebFetchTool(registry(provider));
      await tool.execute({'url': 'https://example.com/'}, ctx());
      expect(provider.calls, hasLength(1));
    });
  });
}

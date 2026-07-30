import 'dart:async';
import 'dart:io';

import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/services/web_service_provider.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/websearch_tool.dart';
import 'package:test/test.dart';

/// Test double for a web provider that supports search. Records
/// each call so tests can assert on pagination behavior.
class _ScriptedSearchProvider extends WebServiceProvider {
  _ScriptedSearchProvider({required this.id, required this.pageResults});

  /// Per-page scripted result list. Tool loops over pages 0..N
  /// and stops on empty page or when it has enough.
  final List<List<WebSearchResult>> pageResults;

  /// Records every call so tests can assert on inputs and
  /// pagination.
  final List<({String query, int page, String? location, String? language})>
  calls = [];

  @override
  final String id;

  @override
  String get displayName => 'Scripted';

  @override
  bool get supportsSearch => true;

  @override
  bool get supportsFetch => false;

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    calls.add((
      query: query,
      page: page ?? 0,
      location: location,
      language: language,
    ));
    final idx = page ?? 0;
    final results = idx < pageResults.length
        ? pageResults[idx]
        : <WebSearchResult>[];
    return WebSearchResponse(
      query: query,
      results: results,
      totalResults: pageResults.fold<int>(0, (s, p) => s + p.length),
      page: idx,
    );
  }

  @override
  Future<WebFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) {
    throw UnimplementedError('not used in websearch tests');
  }
}

/// Test double for a provider that always throws — exercises
/// the tool's error-translation paths.
class _ThrowingSearchProvider extends WebServiceProvider {
  _ThrowingSearchProvider({required this.id, this.error = 'boom'});

  @override
  final String id;
  final String error;

  @override
  String get displayName => 'Throwing';

  @override
  bool get supportsSearch => true;

  @override
  bool get supportsFetch => false;

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    throw WebProviderException(error);
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
    throw UnimplementedError();
  }
}

WebSearchResult _r(int position, String title, String url, {String? snippet}) {
  return WebSearchResult(
    position: position,
    siteName: 'example.com',
    title: title,
    snippet: snippet ?? 'snippet for $title',
    url: url,
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_ws_');
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

  group('WebSearchTool', () {
    test('returns friendly error when no provider is configured', () async {
      final tool = WebSearchTool(registry(null));
      final result = await tool.execute({'query': 'foo'}, ctx());
      expect(result.title, 'Error');
      expect(result.output, contains('No web search provider is configured'));
      expect(result.output, contains('/web-provider'));
    });

    test('rejects missing query', () async {
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: const [],
      );
      final tool = WebSearchTool(registry(provider));
      final result = await tool.execute({}, ctx());
      expect(result.title, 'Error');
      expect(result.output, contains('Missing required parameter: query'));
      expect(provider.calls, isEmpty);
    });

    test('single-page result renders with title/url/snippet', () async {
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: [
          [
            _r(1, 'First Hit', 'https://a.example/', snippet: 'about a'),
            _r(2, 'Second Hit', 'https://b.example/', snippet: 'about b'),
          ],
        ],
      );
      final tool = WebSearchTool(registry(provider));

      // num_results: 2 → loop exits after page 0 (target met).
      final result = await tool.execute({
        'query': 'foo',
        'num_results': 2,
      }, ctx());

      expect(result.title, 'Web search: foo');
      expect(result.output, contains('Search results for: foo'));
      expect(result.output, contains('1. First Hit'));
      expect(result.output, contains('https://a.example/'));
      expect(result.output, contains('about a'));
      expect(result.output, contains('2 result(s)'));
      expect(result.metadata['provider'], 'tinyfish');
      expect(result.metadata['resultCount'], 2);
      expect(provider.calls, hasLength(1));
      expect(provider.calls.first.query, 'foo');
      expect(provider.calls.first.page, 0);
    });

    test(
      'multi-page pagination stops when target numResults is reached',
      () async {
        final provider = _ScriptedSearchProvider(
          id: 'tinyfish',
          pageResults: [
            // 4 results per page, target = 7, so we need page 0 + page 1.
            List.generate(
              4,
              (i) => _r(i + 1, 'P1-$i', 'https://p1.example/$i'),
            ),
            List.generate(
              4,
              (i) => _r(i + 5, 'P2-$i', 'https://p2.example/$i'),
            ),
            List.generate(
              4,
              (i) => _r(i + 9, 'P3-$i', 'https://p3.example/$i'),
            ),
          ],
        );
        final tool = WebSearchTool(registry(provider));

        final result = await tool.execute({
          'query': 'foo',
          'num_results': 7,
        }, ctx());

        // We pulled 4 + 4 = 8 results, then truncated to 7.
        expect(provider.calls, hasLength(2));
        expect(provider.calls.map((c) => c.page).toList(), [0, 1]);
        expect(result.output, contains('1. P1-0'));
        // 7th entry is P2-2 (position 7 in the batch).
        expect(result.output, contains('7. P2-2'));
        // 8th result should NOT be present (truncated).
        expect(result.output, isNot(contains('8. P2-3')));
        expect(result.metadata['resultCount'], 7);
        expect(result.metadata['truncated'], isTrue);
      },
    );

    test('pagination stops early on empty page', () async {
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: [
          // First page: 3 results. Second page: empty (provider
          // ran out). Third page: would have more, but we never
          // ask.
          List.generate(3, (i) => _r(i + 1, 'P1-$i', 'https://p1.example/$i')),
          const <WebSearchResult>[],
          List.generate(3, (i) => _r(i + 1, 'P3-$i', 'https://p3.example/$i')),
        ],
      );
      final tool = WebSearchTool(registry(provider));

      final result = await tool.execute({
        'query': 'foo',
        'num_results': 50,
      }, ctx());

      expect(provider.calls, hasLength(2));
      expect(provider.calls.map((c) => c.page).toList(), [0, 1]);
      expect(result.metadata['resultCount'], 3);
    });

    test('pagination hard-caps at 5 pages', () async {
      // Six full pages → tool should stop at page 4 (the 5th call)
      // even though there's still more data.
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: List.generate(
          6,
          (p) => List.generate(
            3,
            (i) => _r(i + 1, 'P$p-$i', 'https://p$p.example/$i'),
          ),
        ),
      );
      final tool = WebSearchTool(registry(provider));

      final result = await tool.execute({
        'query': 'foo',
        'num_results': 100,
      }, ctx());

      expect(provider.calls, hasLength(5));
      expect(provider.calls.map((c) => c.page).toList(), [0, 1, 2, 3, 4]);
      // 5 pages * 3 results = 15
      expect(result.metadata['resultCount'], 15);
    });

    test('passes location and language through to the provider', () async {
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: const [],
      );
      final tool = WebSearchTool(registry(provider));

      await tool.execute({
        'query': 'foo',
        'location': 'US',
        'language': 'en',
      }, ctx());

      expect(provider.calls, hasLength(1));
      expect(provider.calls.first.location, 'US');
      expect(provider.calls.first.language, 'en');
    });

    test('include_thumbnail adds thumbnail line to formatted output', () async {
      final provider = _ScriptedSearchProvider(
        id: 'tinyfish',
        pageResults: [
          [
            WebSearchResult(
              position: 1,
              siteName: 'ex.com',
              title: 'T',
              snippet: 's',
              url: 'https://e/',
              thumbnailUrl: 'https://img.example/t.jpg',
            ),
          ],
        ],
      );
      final tool = WebSearchTool(registry(provider));

      final result = await tool.execute({
        'query': 'foo',
        'include_thumbnail': true,
      }, ctx());

      expect(result.output, contains('thumbnail: https://img.example/t.jpg'));
    });

    test('WebProviderException message is surfaced to the LLM', () async {
      final provider = _ThrowingSearchProvider(
        id: 'tinyfish',
        error: 'TinyFish HTTP 503: rate limited',
      );
      final tool = WebSearchTool(registry(provider));

      final result = await tool.execute({'query': 'foo'}, ctx());

      expect(result.title, 'Error');
      expect(result.output, 'TinyFish HTTP 503: rate limited');
    });

    test('generic exception is wrapped as a friendly error', () async {
      // ThrowingSearchProvider throws WebProviderException; for a
      // non-WebProviderException case we use a provider that
      // throws a plain Exception.
      final provider = _GenericThrowSearchProvider(
        id: 'tinyfish',
        error: Exception('socket closed'),
      );
      final tool = WebSearchTool(registry(provider));

      final result = await tool.execute({'query': 'foo'}, ctx());

      expect(result.title, 'Error');
      expect(result.output, contains('Web search failed'));
      expect(result.output, contains('socket closed'));
    });
  });
}

class _GenericThrowSearchProvider extends WebServiceProvider {
  _GenericThrowSearchProvider({required this.id, required this.error});
  @override
  final String id;
  final Object error;

  @override
  String get displayName => 'GenericThrow';

  @override
  bool get supportsSearch => true;

  @override
  bool get supportsFetch => false;

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    throw error;
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
    throw UnimplementedError();
  }
}

import '../services/web_provider_registry.dart';
import '../services/web_service_provider.dart';
import '../models/message.dart';
import 'tool_def.dart';

/// Web search tool — only registered with the LLM when at least
/// one configured [WebServiceProvider] reports `supportsSearch`.
///
/// The tool is provider-agnostic: at execute time it asks
/// [WebProviderRegistry.activeSearchProvider] to handle the call.
/// Today that's TinyFish; future providers (Exa, Brave, …) slot
/// in via [WebServiceProvider] without touching this file.
///
/// Output format: a readable plain-text block of search results,
/// one per line, with `position. title — site_name\n   url\n
/// snippet`. Followed by a small footer with `query`, `page`,
/// `total_results`. The LLM can either quote from the block or
/// use the URLs to follow up with `webfetch`.
///
/// Parameters:
/// - `query` (required): the search query. Operators like
///   `site:example.com` and `-site:foo.com` are passed through
///   verbatim — TinyFish supports them.
/// - `num_results` (optional, default 10): the page size hint
///   passed to the provider. Currently the provider returns up
///   to ~10 results per page; `num_results > 10` triggers a
///   follow-up page fetch.
/// - `location` (optional): ISO 3166-1 alpha-2 country code,
///   e.g. `US`, `GB`, `FR`. Auto-resolves `language` if unset.
/// - `language` (optional): language code, e.g. `en`, `fr`. Auto-
///   resolves `location` if unset.
/// - `include_thumbnail` (optional, default false): when true,
///   the result rows include the thumbnail URL when available.
class WebSearchTool extends ToolDef {
  final WebProviderRegistry registry;

  WebSearchTool(this.registry);

  @override
  String get name => 'websearch';

  @override
  String get description =>
      'Search the web for a query and get back ranked results with '
      'titles, snippets, and source URLs. Use this when the user '
      'asks an open-ended question that needs external / current '
      'information (e.g. "what is X", "latest on Y", comparisons, '
      'facts). Results are LLM-friendly plain text. '
      'CALL MULTIPLE IN PARALLEL — when searching for several '
      'independent topics, issue all the websearch calls in the '
      'same turn rather than sequentially. Aim for at most ~5 '
      'concurrent calls per turn to avoid rate limits.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'The search query string. Supports operators like '
                    '"python tutorial site:docs.python.org" or '
                    '"recipes -site:facebook.com".',
          },
          'num_results': {
            'type': 'integer',
            'description':
                'Target number of results to return (1-50). Provider '
                    'may return fewer. Beyond a single page (~10), '
                    'the tool will automatically follow up with '
                    'additional page requests.',
            'minimum': 1,
            'maximum': 50,
            'default': 10,
          },
          'location': {
            'type': 'string',
            'description':
                'ISO 3166-1 alpha-2 country code for geo-targeted '
                    'results (e.g. "US", "GB", "FR", "DE", "JP"). '
                    'When set without `language`, language auto-'
                    'resolves to the most-used language in that '
                    'country.',
          },
          'language': {
            'type': 'string',
            'description':
                'Language code for result language (e.g. "en", '
                    '"fr", "ja", "zh"). When set without `location`, '
                    'location auto-resolves to the country where '
                    'that language is most used.',
          },
          'include_thumbnail': {
            'type': 'boolean',
            'description':
                'When true, includes a thumbnail URL on each result '
                    'when the provider has one available. Off by '
                    'default to keep the output small.',
            'default': false,
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('Missing required parameter: query');
    }
    final numResults = (args['num_results'] as int?) ?? 10;
    final location = args['location'] as String?;
    final language = args['language'] as String?;
    final includeThumb = args['include_thumbnail'] as bool? ?? false;

    final provider = registry.activeSearchProvider;
    if (provider == null) {
      return ToolResult.error(
        'No web search provider is configured. '
        'Run `/web-provider <name> key <key>` to set one, then retry.',
      );
    }

    try {
      // Pull multiple pages in a loop until we've collected
      // `numResults` results, the provider returns an empty
      // page, or we hit a hard cap (5 pages = ~50 results).
      // The provider's own page size dictates the per-call yield
      // — we just keep asking for the next page.
      const maxPages = 5;
      final all = <WebSearchResult>[];
      int? lastPage;

      for (var page = 0; page < maxPages; page++) {
        final resp = await provider.search(
          query: query,
          location: location,
          language: language,
          page: page,
          includeThumbnail: includeThumb,
        );
        lastPage = resp.page;
        all.addAll(resp.results);
        if (all.length >= numResults) break;
        // Stop early if the provider returned a short / empty
        // page — no point hammering the API.
        if (resp.results.isEmpty) break;
      }

      final truncated = all.length > numResults;
      final picked = truncated ? all.take(numResults).toList() : all;
      final output = _formatResults(
        query: query,
        results: picked,
        page: lastPage,
        totalResults: all.length,
        includeThumbnail: includeThumb,
      );

      return ToolResult(
        title: 'Web search: $query',
        output: output,
        metadata: {
          'provider': provider.id,
          'query': query,
          'resultCount': picked.length,
          if (truncated) 'truncated': true,
        },
      );
    } on WebProviderException catch (e) {
      return ToolResult.error(e.message);
    } catch (e) {
      return ToolResult.error('Web search failed: $e');
    }
  }

  /// Render the search results as plain text. One block per
  /// result, separated by a blank line. Header is the query;
  /// footer is a one-line summary.
  static String _formatResults({
    required String query,
    required List<WebSearchResult> results,
    int? page,
    required int totalResults,
    required bool includeThumbnail,
  }) {
    final buf = StringBuffer()
      ..writeln('Search results for: $query')
      ..writeln();
    for (final r in results) {
      buf
        ..writeln('${r.position}. ${r.title}  —  ${r.siteName}')
        ..writeln('   ${r.url}');
      if (includeThumbnail && r.thumbnailUrl != null) {
        buf.writeln('   thumbnail: ${r.thumbnailUrl}');
      }
      if (r.snippet.isNotEmpty) {
        buf.writeln('   ${r.snippet}');
      }
      buf.writeln();
    }
    if (results.isEmpty) {
      buf.writeln('(no results)');
    } else {
      buf.write('${results.length} result(s)');
      if (totalResults > results.length) {
        buf.write(' (page $page, $totalResults returned)');
      }
      buf.writeln();
    }
    return buf.toString().trimRight();
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final query = (call.input['query'] as String?) ?? '';
    if (isError) return 'websearch {$query} → $pairedResult';
    return 'websearch for {$query}';
  }

  // websearch intentionally has no [extractPruneSummary] override
  // — it inherits the default `null` return. The chat-log spec
  // drops search results from the bottom-of-log section: the
  // query is preserved in the inline `websearch for {$query}`
  // line, and the resumed agent can re-run the search if it
  // needs the results. Search snippets go stale faster than the
  // model's own recall of what it searched for, so dumping
  // them again at compact time adds little value for the token
  // cost.
}

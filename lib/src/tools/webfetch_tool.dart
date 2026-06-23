import 'dart:convert';
import 'dart:io';

import '../services/web_provider_registry.dart';
import '../services/web_service_provider.dart';
import '../utils/proxy_aware_http.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

/// Fetch a URL and return its content.
///
/// Routes through the active [WebServiceProvider] (today: TinyFish)
/// when a key is configured. The provider returns clean, structured
/// content — title, description, and clean markdown — which is
/// dramatically cheaper to feed back to the LLM than a raw HTML
/// dump. We render the response as a readable text block that
/// puts the structured metadata first, then the body, so the
/// model can skim metadata before deciding whether to dig into
/// the full content.
///
/// Falls back to a raw HTML fetch (the historical behavior) when
/// no provider is configured or the configured provider doesn't
/// support fetch. This means `webfetch` always works — users get
/// clean structured content when they've set up TinyFish, and
/// noisy-but-functional raw HTML when they haven't.
///
/// HTTP→HTTPS upgrade, the `format` knob, and the 5MB size cap
/// are preserved in the raw-fallback path. The provider path
/// doesn't need them — TinyFish already returns clean text.
class WebFetchTool extends ToolDef {
  final WebProviderRegistry registry;

  WebFetchTool(this.registry);

  @override
  String get name => 'webfetch';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final url = args['url'] as String? ?? '';
    final lines = '\n'.allMatches(result.output).length + 1;
    final size = result.output.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    final costTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return CollapsedSummary(
      text: '$url: $lines lines, $sizeStr',
      argsTokens: costTokens,
      totalTokens: costTokens,
    );
  }

  @override
  String get description =>
      'Fetch content from URL. Returns structured metadata '
      '(title, description, etc.) and clean content when a web '
      'provider is configured. HTTP auto-upgraded to HTTPS. Large '
      'results (>5MB) return an error rather than being summarized. '
      'CALL MULTIPLE IN PARALLEL — when fetching several independent '
      'URLs, issue all the webfetch calls in the same turn rather '
      'than sequentially. This saves roundtrips. Aim for at most '
      '~5 concurrent calls per turn to avoid rate limits or '
      'upstream overload.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': 'URL to fetch'},
          'format': {
            'type': 'string',
            'enum': ['markdown', 'text', 'html', 'raw'],
            'description':
                'Output format. The web provider is asked for this '
                    'format; the raw-fallback path applies it '
                    'client-side. "raw" always bypasses the web '
                    'provider and returns the unprocessed HTML '
                    'response body. Default: markdown.',
          },
          'timeout': {
            'type': 'integer',
            'description':
                'Timeout in seconds (max 120). Only applies to the '
                    'raw-fallback path; provider requests have their '
                    'own backend timeout.',
          },
        },
        'required': ['url'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final url = args['url'] as String?;
    final format = (args['format'] as String?) ?? 'markdown';
    final timeoutSec = ((args['timeout'] as int?) ?? 30).clamp(1, 120);

    if (url == null || url.isEmpty) {
      return ToolResult.error('Missing required parameter: url');
    }

    // Auto-upgrade http:// → https://.
    var effectiveUrl = url;
    if (effectiveUrl.startsWith('http://')) {
      effectiveUrl = 'https://${effectiveUrl.substring(7)}';
    }

    // `raw` always bypasses the provider — providers (TinyFish
    // and friends) return processed content (markdown/html/
    // json), never unprocessed HTML, so requesting 'raw'
    // through the provider path would either fail or be
    // silently downgraded. Route straight to the raw HTTP
    // fallback regardless of provider configuration.
    if (format == 'raw') {
      return _executeRawFetch(
        effectiveUrl: effectiveUrl,
        format: format,
        timeoutSec: timeoutSec,
      );
    }

    // Provider path: clean, structured, dramatically cheaper to
    // feed back to the LLM than raw HTML. Only one URL per call
    // here — the provider's batch endpoint is for parallel
    // fetches that the LLM is currently doing one at a time
    // anyway. If callers want batching, the orchestrator can
    // add a `urls[]` parameter in the future.
    final provider = registry.activeFetchProvider;
    if (provider != null) {
      try {
        final resp = await provider.fetch(
          [effectiveUrl],
          format: format,
        );
        if (resp.errors.isNotEmpty && resp.results.isEmpty) {
          final e = resp.errors.first;
          return ToolResult.error(
            'Web provider could not fetch $effectiveUrl: '
            '${e.code}${e.status != null ? " (${e.status})" : ""}',
          );
        }
        final r = resp.results.firstWhere(
          (e) => e.url == effectiveUrl,
          orElse: () => resp.results.first,
        );
        // If the URL we asked for landed in `errors` (mixed
        // batch), surface that.
        if (r.text == null) {
          final err = resp.errors.firstWhere(
            (e) => e.url == effectiveUrl,
            orElse: () => const WebFetchError(
              code: 'unknown',
              url: '',
            ),
          );
          return ToolResult.error(
            'Web provider could not fetch $effectiveUrl: '
            '${err.code}${err.status != null ? " (${err.status})" : ""}',
          );
        }
        return ToolResult(
          title: 'Fetch: $effectiveUrl',
          output: _formatFetchedPage(r),
          metadata: {
            'url': r.finalUrl ?? effectiveUrl,
            'format': r.format ?? format,
            'provider': provider.id,
            // 'routing' is read by `_buildToolResultForPersist`
            // and forwarded to `messages.meta` for the
            // chat-history bubble / detail view to render. It
            // is **not** part of the LLM's view of the tool
            // result — the LLM only ever sees `output` above.
            if (r.latencyMs != null) 'latency_ms': r.latencyMs,
          },
        );
      } on WebProviderException catch (e) {
        // Provider path failed — surface a clear error. We do
        // NOT silently fall back to raw here, because the user
        // explicitly opted in to the provider path and the
        // common cause of failure is rate limiting, which
        // retrying in raw mode won't help with (same upstream).
        return ToolResult.error(e.message);
      } catch (e) {
        return ToolResult.error('Web provider fetch failed: $e');
      }
    }

    // No provider configured — raw HTML fallback (the
    // historical behavior). Same as before the provider
    // integration existed.
    return _executeRawFetch(
      effectiveUrl: effectiveUrl,
      format: format,
      timeoutSec: timeoutSec,
    );
  }

  /// Render a [WebFetchResult] as a readable text block. Order:
  /// title → final URL → description → language / author /
  /// published date → body. Empty fields are dropped. We put
  /// the structured fields first so the LLM can decide whether
  /// the page is relevant before scanning the body.
  static String _formatFetchedPage(WebFetchResult r) {
    final buf = StringBuffer();
    final title = r.title;
    if (title != null && title.isNotEmpty) {
      buf.writeln('# $title');
      buf.writeln();
    }
    if (r.finalUrl != null && r.finalUrl != r.url) {
      buf.writeln('URL: ${r.finalUrl}');
      buf.writeln();
    }
    final meta = <String>[];
    if (r.language != null) meta.add('language: ${r.language}');
    if (r.author != null) meta.add('author: ${r.author}');
    if (r.publishedDate != null) meta.add('published: ${r.publishedDate}');
    if (meta.isNotEmpty) {
      buf.writeln(meta.join(' · '));
      buf.writeln();
    }
    if (r.description != null && r.description!.isNotEmpty) {
      buf
        ..writeln('> ${r.description}')
        ..writeln();
    }
    final body = r.text;
    if (body != null && body.isNotEmpty) {
      buf.writeln(body);
    } else {
      buf.writeln('(no content)');
    }
    return buf.toString().trimRight();
  }

  /// The legacy raw-HTML fetch path. Kept for users who haven't
  /// configured any provider — `webfetch` is still useful, just
  /// noisier.
  Future<ToolResult> _executeRawFetch({
    required String effectiveUrl,
    required String format,
    required int timeoutSec,
  }) async {
    return withProxyRetry<ToolResult>(
      enabled: isSystemProxyFallbackGloballyEnabled(),
      attempt: (proxy) async {
        final client = HttpClient();
        client.userAgent = 'Mozilla/5.0 (compatible; CruxBot/1.0)';
        client.connectionTimeout = Duration(seconds: timeoutSec);
        if (proxy != null) {
          client.findProxy = proxy.findProxyFor;
        }
        try {
          final request = await client.getUrl(Uri.parse(effectiveUrl));
          final response = await request.close();

          if (response.statusCode != 200) {
            return ToolResult.error(
              'HTTP ${response.statusCode}: Failed to fetch $effectiveUrl',
            );
          }

          final body = await response.transform(utf8.decoder).join();

          if (body.length > 5 * 1024 * 1024) {
            return ToolResult.error(
              'Response too large (>5MB). Content may be summarized.',
            );
          }

          final content = switch (format) {
            'text' => _stripHtml(body),
            // 'html' and 'raw' both pass the response body
            // through verbatim — 'html' means "give me HTML",
            // 'raw' means "give me whatever bytes you got".
            // The previous `format == 'text' ? _stripHtml(body)
            // : _toMarkdown(body)` ternary silently funneled
            // 'html' (and the new 'raw') through markdown
            // conversion, which was a latent bug.
            'html' || 'raw' => body,
            _ => _toMarkdown(body), // markdown + unknown
          };

          return ToolResult(
            title: 'Fetch: $effectiveUrl',
            output: content,
            metadata: {
              'url': effectiveUrl,
              'format': format,
              'provider': 'raw',
              if (proxy != null) 'routing': 'system-proxy',
            },
          );
        } finally {
          client.close(force: true);
        }
      },
    ).catchError((Object e) {
      return ToolResult.error('Failed to fetch URL: $e');
    });
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _toMarkdown(String html) {
    var md = html;

    md = md.replaceAllMapped(
      RegExp(r'<h1[^>]*>(.*?)</h1>', multiLine: true),
      (m) => '# ${m[1]}\n\n',
    );
    md = md.replaceAllMapped(
      RegExp(r'<h2[^>]*>(.*?)</h2>', multiLine: true),
      (m) => '## ${m[1]}\n\n',
    );
    md = md.replaceAllMapped(
      RegExp(r'<h3[^>]*>(.*?)</h3>', multiLine: true),
      (m) => '### ${m[1]}\n\n',
    );
    md = md.replaceAllMapped(
      RegExp(r'<h4[^>]*>(.*?)</h4>', multiLine: true),
      (m) => '#### ${m[1]}\n\n',
    );
    md = md.replaceAllMapped(
      RegExp(r'<p[^>]*>(.*?)</p>', multiLine: true),
      (m) => '${m[1]}\n\n',
    );
    md = md.replaceAllMapped(
      RegExp(r'<strong[^>]*>(.*?)</strong>', multiLine: true),
      (m) => '**${m[1]}**',
    );
    md = md.replaceAllMapped(
      RegExp(r'<em[^>]*>(.*?)</em>', multiLine: true),
      (m) => '*${m[1]}*',
    );
    md = md.replaceAllMapped(
      RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>', multiLine: true),
      (m) => '[${m[2]}](${m[1]})',
    );
    md = md.replaceAllMapped(
      RegExp(r'<code[^>]*>(.*?)</code>', multiLine: true),
      (m) => '`${m[1]}`',
    );
    md = md.replaceAllMapped(
      RegExp(r'<pre[^>]*>(.*?)</pre>', multiLine: true),
      (m) => '```\n${m[1]}\n```',
    );
    md = md.replaceAllMapped(
      RegExp(r'<li[^>]*>(.*?)</li>', multiLine: true),
      (m) => '- ${m[1]}\n',
    );
    md = md.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    md = md.replaceAll(RegExp(r'<[^>]*>'), '');
    md = md.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    md = md.trim();

    return md;
  }
}

import 'dart:convert';
import 'dart:io';

import '../utils/proxy_aware_http.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

class WebFetchTool extends ToolDef {
  @override
  String get name => 'webfetch';

  @override
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
      'Fetch content from URL. Converts to requested format (markdown '
      'by default). HTTP auto-upgraded to HTTPS. Large results (>5MB) '
      'return an error rather than being summarized. '
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
        'enum': ['markdown', 'text', 'html'],
        'description': 'Output format (default: markdown)',
      },
      'timeout': {
        'type': 'integer',
        'description': 'Timeout in seconds (max 120)',
      },
    },
    'required': ['url'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final url = args['url'] as String?;
    final format = (args['format'] as String?) ?? 'markdown';
    final timeoutSec = ((args['timeout'] as int?) ?? 30).clamp(1, 120);

    if (url == null || url.isEmpty) {
      return ToolResult.error('Missing required parameter: url');
    }

    var effectiveUrl = url;
    if (effectiveUrl.startsWith('http://')) {
      effectiveUrl = 'https://${effectiveUrl.substring(7)}';
    }

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

          final content =
              format == 'text' ? _stripHtml(body) : _toMarkdown(body);

          return ToolResult(
            title: 'Fetch: $effectiveUrl',
            output: content,
            metadata: {
              'url': effectiveUrl,
              'format': format,
              // 'routing' is read by `_buildToolResultForPersist`
              // and forwarded to `messages.meta` for the
              // chat-history bubble / detail view to render. It is
              // **not** part of the LLM's view of the tool result
              // — the LLM only ever sees `output` above.
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

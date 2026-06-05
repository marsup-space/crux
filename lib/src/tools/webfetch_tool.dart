import 'dart:convert';
import 'dart:io';

import 'tool_def.dart';

class WebFetchTool extends ToolDef {
  @override
  String get name => 'webfetch';

  @override
  String get description =>
      '- Fetches content from a specified URL\n'
      '- Takes a URL and optional format as input\n'
      '- Fetches the URL content, converts to requested format (markdown by default)\n'
      '- Returns the content in the specified format\n'
      '- Use this tool when you need to retrieve and analyze web content\n'
      '- IMPORTANT: if another tool is present that offers better web fetching capabilities, '
      'is more targeted to the task, or has fewer restrictions, prefer using that tool instead.\n'
      '- The URL must be a fully-formed valid URL\n'
      '- HTTP URLs will be automatically upgraded to HTTPS\n'
      '- Results may be summarized if the content is very large';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'The URL to fetch content from'},
      'format': {
        'type': 'string',
        'enum': ['markdown', 'text', 'html'],
        'description': 'Format to return content in (default: markdown)',
      },
      'timeout': {
        'type': 'integer',
        'description': 'Optional timeout in seconds (max 120)',
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

    try {
      final client = HttpClient();
      client.userAgent = 'Mozilla/5.0 (compatible; CruxBot/1.0)';
      client.connectionTimeout = Duration(seconds: timeoutSec);

      final request = await client.getUrl(Uri.parse(effectiveUrl));
      final response = await request.close();

      if (response.statusCode != 200) {
        client.close();
        return ToolResult.error(
          'HTTP ${response.statusCode}: Failed to fetch $effectiveUrl',
        );
      }

      final body = await response.transform(utf8.decoder).join();

      if (body.length > 5 * 1024 * 1024) {
        client.close();
        return ToolResult.error(
          'Response too large (>5MB). Content may be summarized.',
        );
      }

      final content = format == 'text' ? _stripHtml(body) : _toMarkdown(body);
      client.close();

      return ToolResult(
        title: 'Fetch: $effectiveUrl',
        output: content,
        metadata: {'url': effectiveUrl, 'format': format},
      );
    } catch (e) {
      return ToolResult.error('Failed to fetch URL: $e');
    }
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

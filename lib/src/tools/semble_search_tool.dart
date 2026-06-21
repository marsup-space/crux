import 'dart:convert';
import 'dart:io';

import '../utils/bundled_executable.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'semble_warmup.dart';
import 'tool_def.dart';

const _defaultTopK = 8;
const _maxSnippetLineLength = 200;

/// Semantic code search via the `semble` CLI (hybrid BM25 + model2vec).
///
/// Use this for CONCEPT questions where the answer isn't a known identifier.
/// For exact symbol or pattern matching, prefer the [GrepTool] instead.
class SembleSearchTool extends ToolDef {
  @override
  String get name => 'semble_search';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final query = args['query'] as String? ?? '';
    final total = result.metadata['totalMatches'] as int? ?? 0;
    final costTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final suffix = result.truncated ? ' [truncated]' : '';
    return CollapsedSummary(
      text: '"$query": $total matches$suffix',
      argsTokens: costTokens,
      totalTokens: costTokens,
    );
  }

  @override
  String get description =>
      'Semantic code search using hybrid BM25 + static embeddings '
      '(via the `semble` CLI). '
      'USE FOR CONCEPT QUESTIONS: "how does authentication work", '
      '"where is YAML parsed", "find code that handles errors". '
      'Returns ranked code snippets (file:line + content) with similarity '
      'scores. '
      'DO NOT USE for exact identifier lookups ("where is FunctionX '
      'defined") or known regex patterns — semantic search is slower and '
      'less precise than grep for symbol names. Use grep for those. '
      'CALL MULTIPLE IN PARALLEL — when investigating several concepts, '
      'issue all the semble_search calls in the same turn rather than '
      'sequentially. Mixing with grep, glob, and read in the same turn is '
      'encouraged when the calls are independent (e.g. semantic search to '
      'narrow down, then grep to find references, then read the relevant '
      'files — issue them together when you already know what you need). '
      'Do NOT shell out to semble via bash to do this — call this tool '
      'directly. Requires `semble` on PATH or in third_party/bin/. '
      'First call on a new directory indexes it (~250ms-12min depending on '
      'size); subsequent queries are sub-second.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'Natural-language query describing the code you want. '
            'Examples: "how does indexing parse source files", '
            '"authentication middleware", "error handling in API layer".',
      },
      'path': {
        'type': 'string',
        'description':
            'Directory to search in (default: working directory). '
            'Indexes are cached per-directory in .semble/.',
      },
      'k': {
        'type': 'integer',
        'description':
            'Max snippets to return (default: 8). '
            'More results = more context but more tokens.',
      },
    },
    'required': ['query'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('Missing required parameter: query');
    }

    final path = resolvePath(
      (args['path'] as String?) ?? ctx.workingDirectory,
      ctx.workingDirectory,
    );
    final k = (args['k'] as int?) ?? _defaultTopK;
    if (k < 1) return ToolResult.error('k must be >= 1');

    // Block on warmup if it's still running. Boot kicks this off
    // fire-and-forget; the agent's first tool call pays the cost.
    await SembleWarmup.instance.awaitReady(path);

    final executable = await resolveBundledExecutable('semble');

    try {
      final result = await Process.run(executable, [
        'search',
        query,
        path,
        '--top-k',
        '$k',
      ]);

      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        if (stderr.isEmpty) {
          return ToolResult.error('semble exited with code ${result.exitCode}');
        }
        return ToolResult.error(
          'semble error: $stderr\n\n'
          'Tip: install avec `pip install semble` (or `uv tool install semble`) '
          'and ensure `semble` is on PATH or symlinked into third_party/bin/.',
        );
      }

      final stdout = result.stdout as String;
      if (stdout.isEmpty) {
        return ToolResult(
          title: 'semble: no matches',
          output: '(no output from semble)',
          metadata: {'totalMatches': 0},
        );
      }

      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(stdout) as Map<String, dynamic>;
      } on FormatException catch (e) {
        return ToolResult.error(
          'Failed to parse semble JSON output: $e\n\n'
          'Raw output (first 500 chars):\n'
          '${stdout.substring(0, stdout.length.clamp(0, 500))}',
        );
      }

      final results =
          (parsed['results'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (results.isEmpty) {
        return ToolResult(
          title: 'semble: no matches',
          output: 'No code matches "$query" in $path',
          metadata: {'totalMatches': 0},
        );
      }

      final lines = <String>[
        '# ${results.length} semantic '
        'match${results.length == 1 ? '' : 'es'} for "$query" '
        '(in $path)',
        '',
      ];
      for (final r in results) {
        final file = r['file_path'] ?? '<unknown>';
        final start = r['start_line'] ?? '?';
        final end = r['end_line'] ?? '?';
        final score = (r['score'] as num?)?.toStringAsFixed(4) ?? '?';
        final content = (r['content'] as String? ?? '').trim();

        lines.add('## $file:$start-$end  (score $score)');
        for (final line in content.split('\n')) {
          if (line.length > _maxSnippetLineLength) {
            lines.add('  ${line.substring(0, _maxSnippetLineLength)}...');
          } else {
            lines.add('  $line');
          }
        }
        lines.add('');
      }

      return ToolResult(
        title: 'semble: ${results.length} matches',
        output: lines.join('\n'),
        metadata: {'totalMatches': results.length},
      );
    } on ProcessException catch (e) {
      return ToolResult.error(
        'Unable to start semble: ${e.message}\n\n'
        'Install avec `pip install semble` (or `uv tool install semble`) '
        'and ensure `semble` is on PATH or symlinked into third_party/bin/. '
        'Set CRUX_THIRD_PARTY_BIN to override the search path.',
      );
    }
  }
}
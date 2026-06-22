import 'dart:convert';
import 'dart:io';

import '../utils/bundled_executable.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'semble_warmup.dart';
import 'tool_def.dart';

const _defaultTopK = 8;
const _maxSnippetLineLength = 200;

/// Semantic code search: finds code by CONCEPT, not exact regex match.
///
/// Use this for "what does X do / how does Y work" questions. For
/// known identifiers or exact patterns, prefer the `grep` tool.
class CodeSearchTool extends ToolDef {
  @override
  String get name => 'code_search';

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
      '🚨 CRITICAL: USE THIS TOOL BEFORE `grep` or `glob` for '
      'codebase exploration. One call returns ranked snippets '
      'across the whole codebase in ~600ms — far faster than '
      'grep+read or glob+read loops. '
      ''
      'Unlike `grep` (literal string match) and `glob` (filename '
      'pattern), code_search is SEMANTIC — it matches code by '
      'CONCEPT, not by substring. Describe what you want in '
      'natural language and get relevant code even when the '
      'exact words don\'t appear in the source. '
      ''
      'CALL MULTIPLE IN PARALLEL — issue all code_search calls '
      'in one turn when investigating independent concepts.';

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
            'Indexes are cached per-directory.',
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
          return ToolResult.error('code_search exited with code ${result.exitCode}');
        }
        return ToolResult.error(
          'code_search error: $stderr\n\n'
          'The underlying search engine is unavailable. '
          'Install it (e.g. `pip install semble`) and ensure the '
          '`semble` binary is on PATH or in third_party/bin/.',
        );
      }

      final stdout = result.stdout as String;
      if (stdout.isEmpty) {
        return ToolResult(
          title: 'code_search: no matches',
          output: '(no output from code_search)',
          metadata: {'totalMatches': 0},
        );
      }

      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(stdout) as Map<String, dynamic>;
      } on FormatException catch (e) {
        return ToolResult.error(
          'Failed to parse code_search output: $e\n\n'
          'Raw output (first 500 chars):\n'
          '${stdout.substring(0, stdout.length.clamp(0, 500))}',
        );
      }

      final results =
          (parsed['results'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (results.isEmpty) {
        return ToolResult(
          title: 'code_search: no matches',
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
        title: 'code_search: ${results.length} matches',
        output: lines.join('\n'),
        metadata: {'totalMatches': results.length},
      );
    } on ProcessException catch (e) {
      return ToolResult.error(
        'Unable to start code_search: ${e.message}\n\n'
        'Install the underlying search engine (e.g. `pip install semble`) '
        'and ensure its binary is on PATH or in third_party/bin/. '
        'Set CRUX_THIRD_PARTY_BIN to override the search path.',
      );
    }
  }
}
import 'dart:convert';
import 'dart:io';

import '../utils/bundled_executable.dart';
import '../models/message.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'semble_warmup.dart';
import 'tool_def.dart';

const _defaultTopK = 8;
const _maxSnippetLineLength = 200;

/// Semantic "find code similar to a known location" search.
///
/// Given a `file:line` anchor (typically returned by
/// [SemanticSearchTool] or a previous `read`), find OTHER code
/// in the codebase that is semantically similar — by MEANING,
/// not by substring. Useful for "I just saw how X is done
/// here — show me all the other places that do something like
/// this" exploration.
class FindSimilarCodeTool extends ToolDef {
  @override
  String get name => 'find_similar_code';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final file = args['file'] as String? ?? '';
    final line = args['line'] as int? ?? 0;
    final total = result.metadata['totalMatches'] as int? ?? 0;
    final costTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final suffix = result.truncated ? ' [truncated]' : '';
    return CollapsedSummary(
      text: '$file:$line → $total matches$suffix',
      argsTokens: costTokens,
      totalTokens: costTokens,
    );
  }

  @override
  String get description =>
      '🚨 CRITICAL: USE THIS TOOL when you have a code location '
      '(file + line) and want to find OTHER code SIMILAR to it. '
      'One call returns ranked similar snippets across the whole '
      'codebase in ~600ms — far faster than re-reading nearby '
      'files and grepping for patterns. '
      ''
      'Unlike `grep` (literal string match), find_similar_code '
      'is SEMANTIC — it matches by MEANING, not substring. Give '
      'it a file:line anchor and get back code that does similar '
      'things, even when the exact words differ. '
      ''
      'Typical flow: `semantic_search` → `read` to inspect the '
      'best match → `find_similar_code` to discover the rest of '
      'the patterns like it. '
      ''
      'CALL MULTIPLE IN PARALLEL — issue all find_similar_code '
      'calls in one turn when investigating independent anchors.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'file': {
        'type': 'string',
        'description':
            'File path of the anchor — typically the relative path '
            'shown in a `semantic_search` result (e.g. '
            '"lib/src/services/chat_service.dart"). The path is '
            'resolved against `path` if provided, else against the '
            'working directory.',
      },
      'line': {
        'type': 'integer',
        'description':
            'Line number (1-indexed) of the anchor inside `file`. '
            'Must point at a real line of source — the engine '
            'snaps the line to the surrounding chunk.',
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
    'required': ['file', 'line'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final file = args['file'] as String?;
    if (file == null || file.isEmpty) {
      return ToolResult.error('Missing required parameter: file');
    }
    final line = args['line'] as int?;
    if (line == null) {
      return ToolResult.error('Missing required parameter: line');
    }
    if (line < 1) {
      return ToolResult.error('line must be >= 1');
    }

    final path = resolvePath(
      (args['path'] as String?) ?? ctx.workingDirectory,
      ctx.workingDirectory,
    );
    final k = (args['k'] as int?) ?? _defaultTopK;
    if (k < 1) return ToolResult.error('k must be >= 1');

    // Same warmup as semantic_search — the index is shared.
    await SembleWarmup.instance.awaitReady(path);

    final executable = await resolveBundledExecutable('semble');

    try {
      final result = await Process.run(executable, [
        'find-related',
        file,
        '$line',
        path,
        '--top-k',
        '$k',
      ]);

      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        // "No chunk found at file:line" — the file/line didn't
        // snap onto a real source chunk (file moved, line out
        // of range, etc.). Surface a clean, agent-actionable
        // error rather than the raw stderr.
        if (stderr.toLowerCase().contains('no chunk found at')) {
          return ToolResult.error(
            'find_similar_code: no chunk found at $file:$line. '
            'Check that the file path matches one returned by a '
            'previous `semantic_search` or `read` call, and that '
            'the line number is in range.',
          );
        }
        if (stderr.isEmpty) {
          return ToolResult.error('find_similar_code exited with code ${result.exitCode}');
        }
        return ToolResult.error(
          'find_similar_code error: $stderr\n\n'
          'The underlying search engine is unavailable. '
          'Install it (e.g. `pip install semble`) and ensure the '
          '`semble` binary is on PATH or in third_party/bin/.',
        );
      }

      final stdout = result.stdout as String;
      if (stdout.isEmpty) {
        return ToolResult(
          title: 'find_similar_code: no matches',
          output: '(no output from find_similar_code)',
          metadata: {'totalMatches': 0},
        );
      }

      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(stdout) as Map<String, dynamic>;
      } on FormatException catch (e) {
        return ToolResult.error(
          'Failed to parse find_similar_code output: $e\n\n'
          'Raw output (first 500 chars):\n'
          '${stdout.substring(0, stdout.length.clamp(0, 500))}',
        );
      }

      final results =
          (parsed['results'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (results.isEmpty) {
        return ToolResult(
          title: 'find_similar_code: no matches',
          output: 'No code similar to $file:$line in $path',
          metadata: {'totalMatches': 0},
        );
      }

      final lines = <String>[
        '# ${results.length} match'
        '${results.length == 1 ? '' : 'es'} similar to '
        '$file:$line (in $path)',
        '',
      ];
      for (final r in results) {
        final f = r['file_path'] ?? '<unknown>';
        final start = r['start_line'] ?? '?';
        final end = r['end_line'] ?? '?';
        final score = (r['score'] as num?)?.toStringAsFixed(4) ?? '?';
        final content = (r['content'] as String? ?? '').trim();

        lines.add('## $f:$start-$end  (score $score)');
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
        title: 'find_similar_code: ${results.length} matches',
        output: lines.join('\n'),
        metadata: {'totalMatches': results.length},
      );
    } on ProcessException catch (e) {
      return ToolResult.error(
        'Unable to start find_similar_code: ${e.message}\n\n'
        'Install the underlying search engine (e.g. `pip install semble`) '
        'and ensure its binary is on PATH or in third_party/bin/. '
        'Set CRUX_THIRD_PARTY_BIN to override the search path.',
      );
    }
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final query = (call.input['query'] as String?) ?? '';
    if (isError) return 'find_similar_code {$query} → $pairedResult';
    return 'find_similar_code for {$query}';
  }

  // find_similar_code intentionally has no [extractPruneSummary]
  // override — it inherits the default `null` return. Same
  // reasoning as semantic_search: the anchor file path is shown
  // inline (`find_similar_code for {$query}`), the resumed agent
  // can re-run if it needs the matches again, and dumping
  // snippets at compact time adds little for the token cost.
}

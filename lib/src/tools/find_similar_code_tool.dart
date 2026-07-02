import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../services/semble_client.dart';
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

    final anchorPath = p.isAbsolute(file) ? file : p.join(path, file);
    final anchorFile = File(anchorPath);
    if (!anchorFile.existsSync()) {
      return ToolResult.error(
        'find_similar_code: no chunk found at $file:$line. '
        'Check that the file path matches one returned by a '
        'previous `semantic_search` or `read` call.',
      );
    }
    final lineCount = (await anchorFile.readAsLines()).length;
    if (line > lineCount) {
      return ToolResult.error(
        'find_similar_code: no chunk found at $file:$line. '
        'Check that the line number is in range.',
      );
    }

    // Same warmup as semantic_search — the index is shared.
    await SembleWarmup.instance.awaitReady(path);

    try {
      final results = await SembleClient.instance.findRelated(
        file: file,
        line: line,
        path: path,
        topK: k,
      );

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
        final f = r.filePath;
        final start = r.startLine;
        final end = r.endLine;
        final score = r.score.toStringAsFixed(4);
        final content = r.content.trim();

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
    } on Object catch (e) {
      final message = e.toString();
      if (message.toLowerCase().contains('no chunk found at')) {
        return ToolResult.error(
          'find_similar_code: no chunk found at $file:$line. '
          'Check that the file path matches one returned by a '
          'previous `semantic_search` or `read` call, and that '
          'the line number is in range.',
        );
      }
      return ToolResult.error('Unable to run find_similar_code: $e');
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

import '../models/message.dart';
import '../services/semble_client.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'semble_warmup.dart';
import 'tool_def.dart';

const _defaultTopK = 8;
const _maxSnippetLineLength = 200;

/// Semantic code search: finds code by CONCEPT, not by exact regex
/// match. Use this for codebase exploration when you don't already
/// know the exact identifier or file path. For known identifiers
/// or file patterns, prefer `grep` or `glob`.
class SemanticSearchTool extends ToolDef {
  @override
  String get name => 'semantic_search';

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
      '🚨 USE BEFORE `grep` or `glob` for codebase exploration. '
      'Returns ranked snippets in ~600ms.\n'
      '\n'
      'SEMANTIC — matches by concept, not substring. Write a short '
      'structured phrase, not natural language.\n'
      '\n'
      'QUERY RULES:\n'
      '\n'
      '✅ GOOD:\n'
      '  • "<ClassName> <verb> <thing>"\n'
      '  • "<verb> <thing>, <verb> <thing>"\n'
      '  • "<id1> <id2> <id3>"\n'
      '\n'
      '❌ BAD:\n'
      '  • Conversational questions ("how does X?")\n'
      '  • Noun phrases alone ("click handler")\n'
      '  • Filler words ("find me code that…")\n'
      '  • Question + identifier mix\n'
      '\n'
      'CALL MULTIPLE IN PARALLEL for independent concepts. '
      'If first query misses, retry with the class name or split '
      'into 2-3 parallel searches. Use `grep` for "where is X '
      'defined", `find_similar_code` for "find code like this spot".';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'Structured phrase, not natural language. Patterns: '
            '"<ClassName> <verb> <thing>", "<verb> <thing>, <verb> <thing>", '
            'or "<id1> <id2> <id3>". '
            'AVOID conversational questions like "how does X?" — '
            'they route to the system prompt, not the code.',
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

    try {
      final results = await SembleClient.instance.search(
        query,
        path: path,
        topK: k,
      );
      if (results.isEmpty) {
        return ToolResult(
          title: 'semantic_search: no matches',
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
        final file = r.filePath;
        final start = r.startLine;
        final end = r.endLine;
        final score = r.score.toStringAsFixed(4);
        final content = r.content.trim();

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
        title: 'semantic_search: ${results.length} matches',
        output: lines.join('\n'),
        metadata: {'totalMatches': results.length},
      );
    } on Object catch (e) {
      return ToolResult.error('Unable to run semantic_search: $e');
    }
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final query = (call.input['query'] as String?) ?? '';
    if (isError) return 'semantic_search {$query} → $pairedResult';
    return 'semantic_search for {$query}';
  }

  // semantic_search intentionally has no [extractPruneSummary]
  // override — it inherits the default `null` return. The
  // chat-log spec drops search results from the bottom-of-log
  // section: the query IS the intent (already shown inline as
  // `semantic_search for {$query}`), and the resumed agent can
  // re-run the search if it needs the snippets again. Search
  // results go stale faster than the model's own recall of
  // what it searched for, so dumping them again at compact
  // time adds little for the token cost.
}

import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/offload_standin.dart' show lineCountOfArg;
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'matchers/matcher.dart';
import 'matchers/exact_matcher.dart';
import 'matchers/whitespace_matcher.dart';
import 'matchers/indentation_matcher.dart';
import 'tool_def.dart';

class EditTool extends LargePayloadTool with IntentionalTool {
  @override
  List<String> get offloadableArgs => ['oldString', 'newString'];

  @override
  String get name => 'edit';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final oldString = args['oldString'] as String? ?? '';
    final newString = args['newString'] as String? ?? '';
    // _replaceCount is stashed in args by [execute] so the
    // summary can show the *actual* number of replacements
    // (which we only know at execute time, not from the call
    // site of collapsedSummary). When the call hasn't run yet
    // — e.g. the result is being rendered before the tool has
    // actually executed — we fall back to 1, which is correct
    // for the non-replaceAll path.
    final replaceCount = (args['_replaceCount'] as int?) ?? 1;
    final replaceAll = (args['replaceAll'] as bool?) ?? false;
    // The oldString / newString may have been offloaded and
    // replaced with a stand-in pointer; in that case
    // [lineCountOfArg] recovers the line count of the original
    // bytes from the pointer rather than counting the lines of
    // the stand-in metadata string (which would be off by 1).
    final oldLines = lineCountOfArg(oldString);
    final newLines = lineCountOfArg(newString);
    final linesRemoved = oldLines * replaceCount;
    final linesAdded = newLines * replaceCount;
    // Total cost = the full round-trip including the args as they
    // are NOW (stand-ins if compressed, full content if not) +
    // the result. The args are *not* excluded — the strikethrough
    // comparison is honest: both pre and post include the args,
    // and the difference is whether the args are full (pre) or
    // stand-ins (post).
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    // Args-only: same as total but with empty result. The
    // strikethrough pre is also args-only (chat_service computes
    // it at compression time with resultOutput: ''), so this is
    // the apples-to-apples comparison.
    final argsTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: '',
    );
    // The "create file" path (oldString is empty) is special —
    // there's no "removed" to speak of, so the +/- frame doesn't
    // fit. Show the new file's line count as `new file, N lines`
    // so the user can see at a glance how big the brand-new file
    // is, matching the format used by `write` for new files.
    String text;
    if (oldLines == 0) {
      text = 'new file, $newLines lines';
    } else {
      // Prefer the actual replacement count when [execute]
      // stashed it on the args (the typical post-execute
      // rendering path). Fall back to "all" only when the
      // tool hasn't run yet and we genuinely don't know the
      // count — keeping the previous "all replacement" UX
      // for the rare case where someone renders a
      // `replaceAll` call without its result yet.
      final countLabel = args.containsKey('_replaceCount')
          ? '$replaceCount'
          : (replaceAll ? 'all' : '1');
      // Pluralize naturally: 1 → "replacement", anything
      // else (including "all") → "replacements".
      final replacementLabel = countLabel == '1'
          ? '1 replacement'
          : '$countLabel replacements';
      text = '$replacementLabel, +$linesAdded -$linesRemoved lines';
    }
    return CollapsedSummary(
      text: text,
      argsTokens: argsTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  String get description =>
      'Replaces exact text in a file. '
      'Use replaceAll for renaming across file. '
      'After a successful call, any argument that exceeds the offload '
      'threshold is moved from the conversation context to the '
      'offloaded_content table; the result message reports the '
      'composite key for any offloaded argument so it can be '
      'referenced on subsequent turns if needed.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'oldString': {
        'type': 'string',
        'description': 'Text to replace (must differ from newString)',
      },
      'newString': {
        'type': 'string',
        'description': 'Replacement text (must differ from oldString)',
      },
      'replaceAll': {
        'type': 'boolean',
        'description': 'Replace all occurrences (default false)',
      },
      'intent': {
        'type': 'string',
        'description': 'What this edit accomplishes. Be concise.',
      },
    },
    'required': ['filePath', 'oldString', 'newString', 'intent'],
  };

  final FileReadTracker? tracker;
  final List<Matcher> _matchers = [
    ExactMatcher(),
    IndentationMatcher(),
    WhitespaceMatcher(),
  ];

  EditTool({this.tracker});

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final oldString = args['oldString'] as String?;
    final newString = args['newString'] as String?;
    final replaceAll = (args['replaceAll'] as bool?) ?? false;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }
    if (oldString == null) {
      return ToolResult.error('Missing required parameter: oldString');
    }
    if (newString == null) {
      return ToolResult.error('Missing required parameter: newString');
    }
    if (oldString == newString) {
      return ToolResult.error('oldString and newString must be different');
    }

    final resolved = resolvePath(filePath, ctx.workingDirectory);
    final file = File(resolved);
    if (!file.existsSync()) {
      return ToolResult.error(
        'File not found: ${relativePath(resolved, ctx.workingDirectory)}',
      );
    }

    if (tracker != null) {
      final guard = await tracker!.checkWriteGuard(resolved);
      if (guard != null) {
        return ToolResult(
          title: 'Read-before-write guard triggered',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true},
        );
      }
    }

    final bytes = await file.readAsBytes();
    final meta = readFileWithMetadata(bytes);
    final content = meta.content;

    if (oldString.isEmpty) {
      await _writePreservingEncoding(file, newString, meta);
      if (tracker != null) await tracker!.recordRead(resolved, await _mtimeMs(file));
      // Stash the "added" line count so the bubble's
      // collapsedSummary can render "+N lines" next to the
      // token estimate. We use the same stash field as the
      // normal replacement path (_replaceCount) and treat an
      // empty oldString as "0 removed" implicitly via the
      // `oldLines == 0` branch in collapsedSummary.
      args['_replaceCount'] = 1;
      final newLines = lineCountOfArg(newString);
      return _withOffloadNote(
        args,
        ctx,
        ToolResult(
          title: 'Edit file: $resolved',
          output: _successMessage(
            relativePath(resolved, ctx.workingDirectory),
            'Created file with $newLines lines (+$newLines lines)',
            args,
          ),
        ),
      );
    }

    final matchResult = _findMatch(content, oldString, replaceAll);
    if (matchResult == null) {
      return _autoReadResult(
        resolved,
        'The oldString was not found in the file.',
        content,
      );
    }
    if (matchResult.error != null) {
      return _autoReadResult(
        resolved,
        '${matchResult.error}',
        content,
      );
    }
    final matchLen = matchResult.matchLength ?? oldString.length;
    if (_isDisproportionateMatch(oldString, matchLen)) {
      return _autoReadResult(
        resolved,
        'Refusing replacement because the matched span ($matchLen chars) '
        'is much larger than oldString (${oldString.length} chars). '
        'The oldString was too vague and matched a much larger block '
        'than intended.',
        content,
      );
    }

    final newContent = _applyReplacements(
      content,
      matchResult.positions,
      oldString,
      newString,
      replaceAll,
      matchResult.matchLength,
    );
    final normalized = normalizeToLineEnding(newContent, meta.lineEnding);
    await _writePreservingEncoding(file, normalized, meta);

    if (tracker != null) await tracker!.recordRead(resolved, await _mtimeMs(file));

    final count = matchResult.positions.length;
    // Stash the actual replacement count for the bubble's
    // collapsedSummary — we only know it after the matcher
    // ran, and the args we hand to the LLM (and to subsequent
    // turns' collapsedSummary) are the natural place to keep
    // this since the LLM doesn't have to look at it.
    args['_replaceCount'] = count;
    final oldLines = lineCountOfArg(oldString);
    final newLines = lineCountOfArg(newString);
    final linesRemoved = oldLines * count;
    final linesAdded = newLines * count;
    final occLabel = count == 1 ? 'occurrence' : 'occurrences';
    return _withOffloadNote(
      args,
      ctx,
      ToolResult(
        title: 'Edit file: $resolved',
        output: _successMessage(
          relativePath(resolved, ctx.workingDirectory),
          'Replaced $count $occLabel of oldString '
          '(+$linesAdded -$linesRemoved lines)',
          args,
        ),
      ),
    );
  }

  /// Build the first line of the success message. When an intent
  /// was supplied, prefix it so the agent (and the user, on
  /// re-reading) can correlate the result with the planned action.
  String _successMessage(
    String relPath,
    String body,
    Map<String, dynamic> args,
  ) {
    final intent = args['intent'];
    if (intent is String && intent.isNotEmpty) {
      return 'Edit applied to $relPath (intent: \'$intent\'): $body';
    }
    return 'Edit applied to $relPath: $body';
  }

  /// Append the offload note to [result] when at least one of
  /// this tool's arguments will be off-loaded by the chat
  /// service. The note tells the agent the offload happened and
  /// gives it the composite key(s) for future reference, so the
  /// stand-in pointer it sees in the next turn's history is not a
  /// surprise.
  ToolResult _withOffloadNote(
    Map<String, dynamic> args,
    ToolContext ctx,
    ToolResult result,
  ) {
    final offloaded = argsToOffload(args);
    if (offloaded.isEmpty || ctx.callId == null) return result;
    final intent = (this as IntentionalTool).intentFromArgs(args);
    return ToolResult(
      title: result.title,
      output: '${result.output}\n\n${buildOffloadNote(callId: ctx.callId!, offloadedArgs: offloaded, intent: intent)}',
    );
  }

  MatchResult? _findMatch(String content, String oldString, bool replaceAll) {
    for (final matcher in _matchers) {
      final result = matcher.findMatches(content, oldString, replaceAll);
      if (result != null && result.error == null) {
        if (matcher is ExactMatcher) {
          final pos = result.positions.first;
          if (_isMidWhitespaceRun(content, pos)) continue;
        }
        return result;
      }
      if (result != null && result.error != null && matcher is ExactMatcher) {
        return result;
      }
    }
    return null;
  }

  String _applyReplacements(
    String content,
    List<int> positions,
    String oldString,
    String newString,
    bool replaceAll,
    int? matchLength,
  ) {
    final len = matchLength ?? oldString.length;
    if (replaceAll) {
      var result = content;
      for (final pos in positions.reversed) {
        result =
            result.substring(0, pos) + newString + result.substring(pos + len);
      }
      return result;
    }
    final pos = positions.first;
    return content.substring(0, pos) + newString + content.substring(pos + len);
  }

  Future<void> _writePreservingEncoding(
    File file,
    String text,
    FileReadResult meta,
  ) async {
    final body = normalizeToLineEnding(text, meta.lineEnding);
    final encoded = utf8.encode(body);
    if (meta.encoding == 'utf-8-bom') {
      await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...encoded]);
    } else {
      await file.writeAsBytes(encoded);
    }
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }

  /// When the oldString can't be matched, return the file content
  /// so the agent can immediately retry without a manual `read`
  /// round-trip. Same pattern as the read-before-write guard.
  ToolResult _autoReadResult(String filePath, String reason, String content) {
    return ToolResult(
      title: 'Auto-read: $relativePath(filePath, '')',
      output: '[AUTOREAD] No changes were made — $reason\n\n'
          'We re-read the file for you (saved a round trip). '
          'The current content is below; you can call edit again '
          'now without having to call read first.\n\n'
          '$content',
      metadata: {'autoRead': true},
    );
  }

  bool _isMidWhitespaceRun(String content, int pos) {
    if (pos <= 0) return false;
    if (pos >= content.length) return false;
    final at = content[pos];
    final prev = content[pos - 1];
    final atIsWs = at == ' ' || at == '\t';
    final prevIsWs = prev == ' ' || prev == '\t' || prev == '\n' || prev == '\r';
    return atIsWs && prevIsWs;
  }

  /// Reject matches where the span is much larger than oldString.
  /// A fuzzy matcher (Whitespace/Indentation) can collapse a large
  /// block to a short candidate — the replacement would then nuke
  /// far more of the file than intended.  Ported from OpenCode's
  /// `isDisproportionateMatch()`.
  bool _isDisproportionateMatch(String oldString, int matchLen) {
    final oldLines = '\n'.allMatches(oldString).length + 1;
    // For single-line oldString we can't meaningfully compare line
    // counts — whitespace normalization is the whole point of the
    // fuzzy matchers.
    if (oldLines == 1) return false;
    // Estimate how many lines the match span covers, using the
    // oldString's own average line length as a rough ruler.
    final avgLineLen = oldString.length / oldLines;
    final matchLines = (matchLen / avgLineLen).round();
    // Reject when the match spans 3x the lines of oldString AND
    // adds at least 5 extra lines — a clear sign that whitespace
    // normalization collapsed a much larger block than intended.
    if (matchLines >= oldLines * 3 && matchLines >= oldLines + 5) {
      return true;
    }
    // Fallback: also reject when the raw character span is
    // massively out of proportion to oldString.
    return matchLen > oldString.length * 4 &&
        matchLen > oldString.length + 500;
  }
}

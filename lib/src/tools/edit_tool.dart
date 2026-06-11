import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'matchers/matcher.dart';
import 'matchers/exact_matcher.dart';
import 'matchers/whitespace_matcher.dart';
import 'matchers/indentation_matcher.dart';
import 'tool_def.dart';

class EditTool extends ToolDef implements LargePayloadTool {
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
    final replaceAll = (args['replaceAll'] as bool?) ?? false;
    final count = replaceAll ? 'all' : '1';
    final oldLines = '\n'.allMatches(oldString).length + 1;
    final newLines = '\n'.allMatches(newString).length + 1;
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
    return CollapsedSummary(
      text: '$count replacement, $oldLines→$newLines lines',
      argsTokens: argsTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  String get description =>
      'Exact string replacements in files. '
      'Use replaceAll for renaming across file.';

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
        'description': 'What this edit accomplishes.',
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
      final guard = tracker!.checkWriteGuard(resolved);
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
      if (tracker != null) tracker!.recordRead(resolved, await _mtimeMs(file));
      return ToolResult(
        title: 'Edit file: $resolved',
        output: 'Created file with ${newString.length} characters',
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

    if (tracker != null) tracker!.recordRead(resolved, await _mtimeMs(file));

    final count = matchResult.positions.length;
    return ToolResult(
      title: 'Edit file: $resolved',
      output: 'Replaced $count occurrence(s) of oldString',
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
    // matchLen is chars, not lines — for single-line oldString we
    // can't meaningfully compare line counts, so trust the single
    // line width. That's what the fuzzy matchers are for.
    if (oldLines == 1) return false;
    // For multi-line, the matched span must not blow up in line
    // count relative to the oldString.
    final matchLines =
        matchLen.clamp(0, oldLines * 2); // approximate
    if (matchLines >= oldLines + 3 && matchLines >= oldLines * 2) {
      return true;
    }
    return matchLen > (oldString.length + 500).clamp(0, double.infinity) &&
        matchLen > oldString.length * 4;
  }
}

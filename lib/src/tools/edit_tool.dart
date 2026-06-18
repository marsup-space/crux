import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_lock.dart';
import 'file_read_tracker.dart';
import 'matchers/matcher.dart';
import 'matchers/exact_matcher.dart';
import 'matchers/whitespace_matcher.dart';
import 'matchers/indentation_matcher.dart';
import 'tool_def.dart';

class EditTool extends ToolDef with IntentionalTool {
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
    // The replacement count used to be stashed on the input
    // args map (as `_replaceCount`) by execute() and read back
    // here. That had two problems: (1) the args map is the
    // LLM-controlled input — once the model saw the field in
    // conversation history it would occasionally echo it back,
    // sometimes as a string, and the JSON round-trip through
    // SQLite preserved the bad type, crashing this bubble's
    // build on a defensive `as int?` cast. (2) it conflated
    // user input with tool internal state.
    //
    // The count is already in the human-readable output text
    // (`"Replaced N occurrence(s) of oldString ..."`), which
    // is set by execute() and never user-controlled. Parse it
    // out instead. Falls back to 1 when the output doesn't
    // match the expected shape (e.g. legacy or error output).
    final replaceCount = _replaceCountFromOutput(result.output) ??
        (replaceAll ? _allFallbackCount(args) : 1);
    final oldLines = oldString.isEmpty ? 0 : '\n'.allMatches(oldString).length + 1;
    final newLines = newString.isEmpty ? 0 : '\n'.allMatches(newString).length + 1;
    final linesRemoved = oldLines * replaceCount;
    final linesAdded = newLines * replaceCount;
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final argsTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: '',
    );
    String text;
    if (oldLines == 0) {
      text = 'new file, $newLines lines';
    } else {
      final parsedCount = _replaceCountFromOutput(result.output);
      final countLabel = parsedCount != null
          ? '$parsedCount'
          : (replaceAll ? 'all' : '1');
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

  /// Parse the replacement count out of an EditTool success
  /// message. Looks for the canonical
  /// `"Replaced N occurrence(s) of oldString ..."` form that
  /// `_doMutation` emits. Returns null for any other shape
  /// (new-file, auto-read, error, future format changes) so
  /// the caller can pick a sensible fallback.
  static final RegExp _replacedCountPattern =
      RegExp(r'Replaced (\d+) occurrence');

  static int? _replaceCountFromOutput(String output) {
    final match = _replacedCountPattern.firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Used only as a placeholder for the unreplaced count when
  /// the output doesn't carry one and replaceAll is true. The
  /// displayed diff is computed against a single replacement
  /// (since the bubble doesn't actually know N) and the label
  /// collapses to `"all"` so the user sees the qualitative
  /// "multiple replacements" intent. Match prior behavior.
  static int _allFallbackCount(Map<String, dynamic> args) => 1;

  @override
  String get description =>
      'Replaces exact text in a file. '
      'Use replaceAll for renaming across file. '
      'CALL MULTIPLE IN PARALLEL — issue as many edit calls in one '
      'turn as you need, including several against the SAME file. '
      'Same-file edits are serialized internally so all of them apply '
      'in emission order; edits to different files run in parallel. '
      'This saves roundtrips. Mixing edit with read and grep in the '
      'same turn is also encouraged when the calls are independent.';

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

    return fileLock(resolved).run(
      () => _doMutation(
        args: args,
        resolved: resolved,
        file: file,
        oldString: oldString,
        newString: newString,
        replaceAll: replaceAll,
        ctx: ctx,
      ),
    );
  }

  Future<ToolResult> _doMutation({
    required Map<String, dynamic> args,
    required String resolved,
    required File file,
    required String oldString,
    required String newString,
    required bool replaceAll,
    required ToolContext ctx,
  }) async {
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
    final targetLineEnding =
        targetLineEndingFor(resolved, meta.lineEnding);
    final content = targetLineEnding == null
        ? meta.content
        : normalizeToLineEnding(meta.content, targetLineEnding);
    final oldStringForMatch = (targetLineEnding == null || oldString.isEmpty)
        ? oldString
        : normalizeToLineEnding(oldString, targetLineEnding);

    if (oldString.isEmpty) {
      if (targetLineEnding != null) {
        await _writePreservingEncoding(
          file,
          normalizeToLineEnding(newString, targetLineEnding),
          meta,
          overrideLineEnding: targetLineEnding,
        );
      } else {
        await _writePreservingEncoding(file, newString, meta);
      }
      if (tracker != null) {
        await tracker!.recordRead(resolved, await _mtimeMs(file));
      }
      final newLines = newString.isEmpty ? 0 : '\n'.allMatches(newString).length + 1;
      return ToolResult(
        title: 'Edit file: $resolved',
        output: _successMessage(
          relativePath(resolved, ctx.workingDirectory),
          'Created file with $newLines lines (+$newLines lines)',
          args,
        ),
      );
    }

    final matchResult =
        _findMatch(content, oldStringForMatch, replaceAll);
    if (matchResult == null) {
      return _autoReadResult(
        resolved,
        'The oldString was not found in the file.',
        content,
      );
    }
    if (matchResult.error != null) {
      return _autoReadResult(resolved, '${matchResult.error}', content);
    }
    final matchLen = matchResult.matchLength ?? oldStringForMatch.length;
    if (_isDisproportionateMatch(oldStringForMatch, matchLen)) {
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
      oldStringForMatch,
      newString,
      replaceAll,
      matchResult.matchLength,
    );
    if (targetLineEnding != null) {
      final normalized =
          normalizeToLineEnding(newContent, targetLineEnding);
      await _writePreservingEncoding(
        file,
        normalized,
        meta,
        overrideLineEnding: targetLineEnding,
      );
    } else {
      await _writePreservingEncoding(file, newContent, meta);
    }
    if (tracker != null) {
      await tracker!.recordRead(resolved, await _mtimeMs(file));
    }

    final count = matchResult.positions.length;
    final oldLines = oldString.isEmpty ? 0 : '\n'.allMatches(oldString).length + 1;
    final newLines = newString.isEmpty ? 0 : '\n'.allMatches(newString).length + 1;
    final linesRemoved = oldLines * count;
    final linesAdded = newLines * count;
    final occLabel = count == 1 ? 'occurrence' : 'occurrences';
    return ToolResult(
      title: 'Edit file: $resolved',
      output: _successMessage(
        relativePath(resolved, ctx.workingDirectory),
        'Replaced $count $occLabel of oldString '
        '(+$linesAdded -$linesRemoved lines)',
        args,
      ),
    );
  }

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
    FileReadResult meta, {
    String? overrideLineEnding,
  }) async {
    final body = overrideLineEnding == null
        ? normalizeToLineEnding(text, meta.lineEnding)
        : text;
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

  ToolResult _autoReadResult(String filePath, String reason, String content) {
    return ToolResult(
      title: 'Auto-read: $relativePath(filePath, )',
      output:
          '[AUTOREAD] No changes were made — $reason\n\n'
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
    final prevIsWs =
        prev == ' ' || prev == '\t' || prev == '\n' || prev == '\r';
    return atIsWs && prevIsWs;
  }

  bool _isDisproportionateMatch(String oldString, int matchLen) {
    final oldLines = '\n'.allMatches(oldString).length + 1;
    if (oldLines == 1) return false;
    final avgLineLen = oldString.length / oldLines;
    final matchLines = (matchLen / avgLineLen).round();
    if (matchLines >= oldLines * 3 && matchLines >= oldLines + 5) {
      return true;
    }
    return matchLen > oldString.length * 4 && matchLen > oldString.length + 500;
  }
}

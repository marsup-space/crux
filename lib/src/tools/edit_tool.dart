import 'dart:io';

import '../utils/token_estimate.dart';
import 'file_read_tracker.dart';
import 'matchers/matcher.dart';
import 'matchers/exact_matcher.dart';
import 'matchers/whitespace_matcher.dart';
import 'matchers/indentation_matcher.dart';
import 'tool_def.dart';

class EditTool extends ToolDef {
  @override
  String get name => 'edit';

  @override
  String collapsedSummary(Map<String, dynamic> args, ToolResult result) {
    final oldString = args['oldString'] as String? ?? '';
    final newString = args['newString'] as String? ?? '';
    final replaceAll = (args['replaceAll'] as bool?) ?? false;
    final count = replaceAll ? 'all' : '1';
    final oldLines = '\n'.allMatches(oldString).length + 1;
    final newLines = '\n'.allMatches(newString).length + 1;
    final oldTokens = estimateTokens(oldString);
    final newTokens = estimateTokens(newString);
    return '$count replacement, $oldLines→$newLines lines, ~${oldTokens}→~${newTokens}t';
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
    },
    'required': ['filePath', 'oldString', 'newString'],
  };

  final FileReadTracker? tracker;
  final List<Matcher> _matchers = [
    ExactMatcher(),
    WhitespaceMatcher(),
    IndentationMatcher(),
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
      return ToolResult.error('File not found: $resolved');
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

    final content = await file.readAsString();

    if (oldString.isEmpty) {
      await file.writeAsString(newString);
      if (tracker != null) tracker!.recordRead(resolved, await _mtimeMs(file));
      return ToolResult(
        title: 'Edit file: $resolved',
        output: 'Created file with ${newString.length} characters',
      );
    }

    final matchResult = _findMatch(content, oldString, replaceAll);
    if (matchResult == null) {
      return ToolResult.error('oldString not found in content');
    }
    if (matchResult.error != null) {
      return ToolResult.error(matchResult.error!);
    }

    final newContent = _applyReplacements(
      content,
      matchResult.positions,
      oldString,
      newString,
      replaceAll,
    );
    await file.writeAsString(newContent);

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
  ) {
    if (replaceAll) {
      var result = content;
      for (final pos in positions.reversed) {
        result =
            result.substring(0, pos) +
            newString +
            result.substring(pos + oldString.length);
      }
      return result;
    }
    final pos = positions.first;
    return content.substring(0, pos) +
        newString +
        content.substring(pos + oldString.length);
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }
}

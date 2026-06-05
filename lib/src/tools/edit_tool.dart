import 'dart:io';

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
  String get description =>
      'Performs exact string replacements in files. '
      'You must use your Read tool at least once in the conversation before editing. '
      'This tool will error if you attempt an edit without reading the file first. '
      'When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) '
      'as it appears AFTER the line number prefix. '
      'The edit will FAIL if oldString is not found in the file with an error "oldString not found in content". '
      'The edit will FAIL if oldString is found multiple times in the file with an error "Found multiple matches for oldString". '
      'Provide more surrounding lines in oldString to identify the correct match. '
      'Use replaceAll for replacing and renaming strings across the file. '
      'IMPORTANT: DO NOT ADD ANY COMMENTS unless asked.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {
        'type': 'string',
        'description': 'The absolute path to the file to modify',
      },
      'oldString': {
        'type': 'string',
        'description': 'The text to replace (must be different from newString)',
      },
      'newString': {
        'type': 'string',
        'description': 'The replacement text (must differ from oldString)',
      },
      'replaceAll': {
        'type': 'boolean',
        'description': 'Replace all occurrences of oldString (default false)',
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

    final file = File(filePath);
    if (!file.existsSync()) {
      return ToolResult.error('File not found: $filePath');
    }

    if (tracker != null) {
      final guard = tracker!.checkWriteGuard(filePath);
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
      if (tracker != null) tracker!.recordRead(filePath, await _mtimeMs(file));
      return ToolResult(
        title: 'Edit file: $filePath',
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

    if (tracker != null) tracker!.recordRead(filePath, await _mtimeMs(file));

    final count = matchResult.positions.length;
    return ToolResult(
      title: 'Edit file: $filePath',
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
      for (final pos in positions) {
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

import 'dart:io';

import 'file_read_tracker.dart';
import 'tool_def.dart';

class WriteTool extends ToolDef {
  @override
  String get name => 'write';

  @override
  String collapsedSummary(Map<String, dynamic> args, ToolResult result) {
    final filePath = args['filePath'] as String? ?? '';
    final name = filePath.split('/').last;
    return '$name: ok';
  }

  @override
  String get description => 'Writes file, overwriting if exists.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'content': {'type': 'string', 'description': 'Content to write'},
    },
    'required': ['filePath', 'content'],
  };

  final FileReadTracker? tracker;

  WriteTool({this.tracker});

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final content = args['content'] as String?;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }
    if (content == null) {
      return ToolResult.error('Missing required parameter: content');
    }

    final resolved = resolvePath(filePath, ctx.workingDirectory);
    final file = File(resolved);

    if (tracker != null && file.existsSync()) {
      final guard = tracker!.checkWriteGuard(resolved);
      if (guard != null) {
        return ToolResult(
          title: 'Read-before-write guard triggered',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true},
        );
      }
    }

    final parentDir = Directory(
      resolved.substring(0, resolved.lastIndexOf('/')),
    );
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    await file.writeAsString(content);

    if (tracker != null) {
      tracker!.recordRead(resolved, await _mtimeMs(file));
    }

    return ToolResult(
      title: 'Write file: $resolved',
      output: 'Successfully wrote ${content.length} characters to $resolved',
    );
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }
}

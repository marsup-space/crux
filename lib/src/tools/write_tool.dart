import 'dart:io';

import 'file_read_tracker.dart';
import 'tool_def.dart';

class WriteTool extends ToolDef {
  @override
  String get name => 'write';

  @override
  String get description => 'Writes file, overwriting if exists.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {
        'type': 'string',
        'description':
            'The absolute path to the file to write (must be absolute, not relative)',
      },
      'content': {
        'type': 'string',
        'description': 'The content to write to the file',
      },
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
    if (!filePath.startsWith('/')) {
      return ToolResult.error(
        'filePath must be an absolute path, got: $filePath',
      );
    }

    final file = File(filePath);

    if (tracker != null && file.existsSync()) {
      final guard = tracker!.checkWriteGuard(filePath);
      if (guard != null) {
        return ToolResult(
          title: 'Read-before-write guard triggered',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true},
        );
      }
    }

    final parentDir = Directory(
      filePath.substring(0, filePath.lastIndexOf('/')),
    );
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    await file.writeAsString(content);

    if (tracker != null) {
      tracker!.recordRead(filePath, await _mtimeMs(file));
    }

    return ToolResult(
      title: 'Write file: $filePath',
      output: 'Successfully wrote ${content.length} characters to $filePath',
    );
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }
}

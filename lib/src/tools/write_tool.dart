import 'dart:io';

import 'file_read_tracker.dart';
import 'tool_def.dart';

class WriteTool extends ToolDef {
  @override
  String get name => 'write';

  @override
  String get description =>
      'Writes a file to the local filesystem. '
      'This tool will overwrite the existing file if there is one at the provided path. '
      'If this is an existing file, you MUST use the Read tool first to read the file\'s contents. '
      'This tool will fail if you did not read the file first. '
      'NEVER proactively create documentation files (*.md) or README files. '
      'Only create documentation files if explicitly requested by the User. '
      'Only use emojis if the user explicitly requests it. '
      'Avoid writing emojis to files unless asked.';

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

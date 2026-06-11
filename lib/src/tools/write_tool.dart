import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'tool_def.dart';

class WriteTool extends ToolDef implements LargePayloadTool {
  @override
  List<String> get offloadableArgs => ['content'];

  @override
  String get name => 'write';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final content = args['content'] as String? ?? '';
    final lines = '\n'.allMatches(content).length + 1;
    final size = content.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    // Total cost = args (with the *as-persisted* content, which
    // may be a stand-in if offload happened) + the tool's result.
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: content,
    );
    // Args-only cost is what the strikethrough compares against.
    // We compute it on the *as-passed* args, which is the same
    // thing the chat service's preCompressTokens calculation
    // uses (it also runs at the compress boundary, so the args
    // are still full there).
    final argsTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: '',
    );
    return CollapsedSummary(
      text: '$lines lines, $sizeStr',
      argsTokens: argsTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  String get description => 'Writes file, overwriting if exists.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'content': {
        'type': 'string',
        'description': 'Content to write',
      },
      'intent': {
        'type': 'string',
        'description':
            'What this file is for / why you are writing it. Survives '
            'argument compression as semantic context for future turns; '
            'the actual content may be off-loaded and replaced with a '
            'stand-in pointer.',
      },
    },
    'required': ['filePath', 'content', 'intent'],
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

    final parentDir = Directory(file.parent.path);
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    FileReadResult meta;
    if (file.existsSync()) {
      meta = readFileWithMetadata(file.readAsBytesSync());
    } else {
      meta = const FileReadResult(
        content: '',
        encoding: 'utf-8',
        lineEnding: 'lf',
        byteLength: 0,
      );
    }
    final body = normalizeToLineEnding(content, meta.lineEnding);
    final encoded = utf8.encode(body);
    if (meta.encoding == 'utf-8-bom') {
      await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...encoded]);
    } else {
      await file.writeAsBytes(encoded);
    }

    if (tracker != null) {
      tracker!.recordRead(resolved, await _mtimeMs(file));
    }

    return ToolResult(
      title: 'Write file: $resolved',
      output:
          'Successfully wrote ${content.length} characters to ${relativePath(resolved, ctx.workingDirectory)}',
    );
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }
}

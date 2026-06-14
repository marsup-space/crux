import 'dart:io';

import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'tool_def.dart';

const _defaultLimit = 2000;
const _maxLineLength = 2000;

class ReadTool extends ToolDef {
  final FileReadTracker? _tracker;

  ReadTool({FileReadTracker? tracker}) : _tracker = tracker;
  @override
  String get name => 'read';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final lines = '\n'.allMatches(result.output).length + 1;
    final size = result.output.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    final total = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    // `read` isn't a LargePayloadTool, so args-only == total.
    return CollapsedSummary(
      text: '$lines lines, $sizeStr',
      argsTokens: total,
      totalTokens: total,
    );
  }

  @override
  String get description =>
      'Reads file or directory from filesystem. '
      'Returns up to 2000 lines with line number prefixes. '
      'Use offset/limit for later sections.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {
        'type': 'string',
        'description': 'Path to file or directory',
      },
      'offset': {
        'type': 'integer',
        'description': 'Line number to start from (1-indexed)',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max lines to read (default 2000)',
      },
    },
    'required': ['filePath'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final offset = (args['offset'] as int?) ?? 1;
    final limit = (args['limit'] as int?) ?? _defaultLimit;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }

    final path = resolvePath(filePath, ctx.workingDirectory);
    final type = FileSystemEntity.typeSync(path);

    if (type == FileSystemEntityType.notFound) {
      final suggestions = _suggestSimilarFiles(path);
      final relPath = relativePath(path, ctx.workingDirectory);
      final msg = suggestions.isNotEmpty
          ? 'Path not found: $relPath\nSimilar files in the same directory:\n$suggestions'
          : 'Path not found: $relPath';
      return ToolResult.error(msg);
    }

    if (type == FileSystemEntityType.directory) {
      return _readDirectory(path);
    }

    if (type == FileSystemEntityType.file) {
      return _readFile(path, offset, limit, ctx.workingDirectory);
    }

    return ToolResult.error(
      'Cannot read: ${relativePath(path, ctx.workingDirectory)} (FileSystemEntity type: $type)',
    );
  }

  ToolResult _readDirectory(String path) {
    final dir = Directory(path);
    final entries = dir.listSync();
    final sorted = entries.map((e) {
      final name = e.path.split('/').last;
      if (e is Directory) return '$name/';
      return name;
    }).toList();
    sorted.sort();
    final output = sorted.join('\n');
    return ToolResult(title: 'List directory: $path', output: output);
  }

  Future<ToolResult> _readFile(
    String path,
    int offset,
    int limit,
    String workingDirectory,
  ) async {
    final file = File(path);
    final mtimeMs = file.statSync().modified.millisecondsSinceEpoch;
    await _tracker?.recordRead(path, mtimeMs);

    final binaryExts = {
      '.exe',
      '.dll',
      '.so',
      '.dylib',
      '.bin',
      '.obj',
      '.o',
      '.a',
      '.lib',
      '.class',
      '.jar',
      '.war',
      '.pyc',
      '.pyd',
    };
    final ext = path.contains('.') ? '.${path.split('.').last}' : '';
    if (binaryExts.contains(ext.toLowerCase())) {
      return ToolResult.error(
        'Binary file detected: ${relativePath(path, workingDirectory)}. Use bash tool for binary inspection.',
      );
    }

    final imageExts = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.ico',
      '.tiff',
      '.tif',
    };
    if (imageExts.contains(ext.toLowerCase())) {
      return ToolResult.error(
        'Image file: ${relativePath(path, workingDirectory)}. Image preview not yet supported in phase 1.',
      );
    }

    final lines = await file.readAsLines();
    final totalLines = lines.length;

    final startLine = offset.clamp(1, totalLines) - 1;
    final endLine = (startLine + limit).clamp(0, totalLines);

    final selected = lines.sublist(startLine, endLine);
    final numbered = List.generate(selected.length, (i) {
      final line = selected[i];
      final truncatedLine = line.length > _maxLineLength
          ? '${line.substring(0, _maxLineLength)}... [truncated]'
          : line;
      return '${startLine + i + 1}: $truncatedLine';
    }).join('\n');

    final header = totalLines > endLine
        ? '[showing lines ${startLine + 1}-$endLine of $totalLines]'
        : '';

    final output = header.isNotEmpty ? '$header\n$numbered' : numbered;
    return ToolResult(title: 'Read file: $path', output: output);
  }

  String _suggestSimilarFiles(String path) {
    final sep = Platform.pathSeparator;
    final lastSep = path.lastIndexOf(sep);
    if (lastSep == -1) return '';
    final dirPath = path.substring(0, lastSep);
    final target = path.substring(lastSep + 1);
    final prefix = target.toLowerCase().substring(0, target.length.clamp(0, 3));
    if (prefix.isEmpty) return '';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return '';
    final candidates = dir
        .listSync()
        .map((e) => e.path.split(sep).last)
        .where((name) => name.toLowerCase().contains(prefix))
        .take(5)
        .join('\n');
    return candidates;
  }
}

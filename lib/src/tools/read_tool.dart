import 'dart:io';

import 'tool_def.dart';

const _defaultLimit = 2000;
const _maxLineLength = 2000;

class ReadTool extends ToolDef {
  @override
  String get name => 'read';

  @override
  String get description =>
      'Reads a file or directory from the local filesystem. '
      'Returns up to 2000 lines with line number prefixes. '
      'Use offset/limit for later sections.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {
        'type': 'string',
        'description': 'The absolute path to the file or directory to read',
      },
      'offset': {
        'type': 'integer',
        'description': 'The line number to start reading from (1-indexed)',
      },
      'limit': {
        'type': 'integer',
        'description': 'The maximum number of lines to read (defaults to 2000)',
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

    final path = filePath;
    final type = FileSystemEntity.typeSync(path);

    if (type == FileSystemEntityType.notFound) {
      final suggestions = _suggestSimilarFiles(path);
      final msg = suggestions.isNotEmpty
          ? 'Path not found: $path\nSimilar files in the same directory:\n$suggestions'
          : 'Path not found: $path';
      return ToolResult.error(msg);
    }

    if (type == FileSystemEntityType.directory) {
      return _readDirectory(path);
    }

    if (type == FileSystemEntityType.file) {
      return _readFile(path, offset, limit);
    }

    return ToolResult.error(
      'Cannot read: $path (FileSystemEntity type: $type)',
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

  Future<ToolResult> _readFile(String path, int offset, int limit) async {
    final file = File(path);

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
        'Binary file detected: $path. Use bash tool for binary inspection.',
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
        'Image file: $path. Image preview not yet supported in phase 1.',
      );
    }

    final lines = await file.readAsLines();
    final totalLines = lines.length;

    final startLine = offset.clamp(1, totalLines) - 1;
    final endLine = (startLine + limit).clamp(0, totalLines);

    final selected = lines.sublist(startLine, endLine);
    final numbered = selected
        .map((line) {
          final truncatedLine = line.length > _maxLineLength
              ? '${line.substring(0, _maxLineLength)}... [truncated]'
              : line;
          return '${startLine + selected.indexOf(truncatedLine == line ? line : truncatedLine) + 1}: $truncatedLine';
        })
        .join('\n');

    final header = totalLines > endLine
        ? '[showing lines ${startLine + 1}-${endLine} of $totalLines]'
        : '';

    final output = header.isNotEmpty ? '$header\n$numbered' : numbered;
    return ToolResult(title: 'Read file: $path', output: output);
  }

  String _suggestSimilarFiles(String path) {
    final dirPath = path.substring(0, path.lastIndexOf('/'));
    final target = path.split('/').last;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return '';
    final candidates = dir
        .listSync()
        .map((e) => e.path.split('/').last)
        .where(
          (name) =>
              name.toLowerCase().contains(target.toLowerCase().substring(0, 3)),
        )
        .take(5)
        .join('\n');
    return candidates;
  }
}

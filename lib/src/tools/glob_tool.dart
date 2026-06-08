import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';

import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

class GlobTool extends ToolDef {
  @override
  String get name => 'glob';

  @override
  String collapsedSummary(Map<String, dynamic> args, ToolResult result) {
    final pattern = args['pattern'] as String? ?? '';
    final count = '\n'.allMatches(result.output).length + 1;
    final tokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return '"$pattern": $count items, ~${tokens}t';
  }

  @override
  String get description =>
      'Find files by glob pattern. '
      'Returns matching paths sorted by modification time.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'pattern': {'type': 'string', 'description': 'Glob pattern to match'},
      'path': {
        'type': 'string',
        'description': 'Directory to search in (default: cwd)',
      },
    },
    'required': ['pattern'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = args['pattern'] as String?;
    final path = resolvePath(
      (args['path'] as String?) ?? ctx.workingDirectory,
      ctx.workingDirectory,
    );

    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('Missing required parameter: pattern');
    }

    if (Platform.isWindows) {
      return _executeDart(pattern, path, ctx);
    }
    return _executeRipgrep(pattern, path, ctx);
  }

  Future<ToolResult> _executeRipgrep(
    String pattern,
    String path,
    ToolContext ctx,
  ) async {
    final cmdArgs = <String>[
      '--files',
      '--glob',
      pattern,
      '--sort=modified',
      path,
    ];

    try {
      final result = await Process.run('rg', cmdArgs);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        if (output.isEmpty) {
          return ToolResult(
            title: 'Glob: $pattern',
            output: 'No files found matching pattern',
          );
        }
        final lines = output.trim().split('\n');
        final relativeLines = lines
            .map((l) => relativePath(l, ctx.workingDirectory))
            .toList();
        if (relativeLines.length > 100) {
          final kept = relativeLines.take(100).join('\n');
          return ToolResult(
            title: 'Glob: $pattern',
            output: kept + '\n... and ${relativeLines.length - 100} more',
            truncated: true,
          );
        }
        return ToolResult(
          title: 'Glob: $pattern',
          output: relativeLines.join('\n'),
        );
      }
      if (result.exitCode == 1) {
        return ToolResult(
          title: 'Glob: $pattern',
          output: 'No files found matching pattern',
        );
      }
      final stderr = result.stderr as String;
      if (stderr.isNotEmpty) {
        return ToolResult.error('ripgrep error: ${stderr.trim()}');
      }
      return ToolResult.error('ripgrep exited with code ${result.exitCode}');
    } catch (e) {
      return ToolResult.error(
        'ripgrep not available: $e. Install ripgrep or use bash tool.',
      );
    }
  }

  Future<ToolResult> _executeDart(
    String pattern,
    String path,
    ToolContext ctx,
  ) async {
    try {
      final glob = Glob(_normalizePattern(pattern), recursive: true);
      final root = Directory(path);
      if (!await root.exists()) {
        return ToolResult.error('Directory not found: $path');
      }
      final entities = glob.listSync(root: path, followLinks: false);
      final files = <FileSystemEntity>[];
      for (final entity in entities) {
        if (entity is File) files.add(entity);
      }
      files.sort((a, b) {
        final am = a.statSync().modified;
        final bm = b.statSync().modified;
        return bm.compareTo(am);
      });

      if (files.isEmpty) {
        return ToolResult(
          title: 'Glob: $pattern',
          output: 'No files found matching pattern',
        );
      }

      final relative = files
          .map((f) => relativePath(f.path, ctx.workingDirectory))
          .toList();
      if (relative.length > 100) {
        final kept = relative.take(100).join('\n');
        return ToolResult(
          title: 'Glob: $pattern',
          output: kept + '\n... and ${relative.length - 100} more',
          truncated: true,
        );
      }
      return ToolResult(
        title: 'Glob: $pattern',
        output: relative.join('\n'),
      );
    } catch (e) {
      return ToolResult.error('glob failed: $e');
    }
  }

  String _normalizePattern(String pattern) {
    var p = pattern.replaceAll('\\', '/');
    if (Platform.isWindows && !p.contains('/') && !p.contains('*')) {
      p = '**/$p';
    }
    if (Platform.isWindows &&
        p.startsWith('**/') &&
        p.substring(3).contains('/')) {
      p = p.substring(3);
    }
    return p;
  }
}

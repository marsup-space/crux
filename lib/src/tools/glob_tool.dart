import 'dart:io';

import 'tool_def.dart';

class GlobTool extends ToolDef {
  @override
  String get name => 'glob';

  @override
  String get description =>
      '- Fast file pattern matching tool that works with any codebase size\n'
      '- Supports glob patterns like "**/*.js" or "src/**/*.ts"\n'
      '- Returns matching file paths sorted by modification time\n'
      '- Use this tool when you need to find files by name patterns\n'
      '- When you are doing an open-ended search that may require multiple rounds '
      'of globbing and grepping, use the Task tool instead';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description':
            'Glob pattern to match files against (e.g. "**/*.ts", "src/**/*.dart")',
      },
      'path': {
        'type': 'string',
        'description':
            'Directory to search in (defaults to current working directory)',
      },
    },
    'required': ['pattern'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = args['pattern'] as String?;
    final path = (args['path'] as String?) ?? ctx.workingDirectory;

    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('Missing required parameter: pattern');
    }

    final cmdArgs = <String>[];
    cmdArgs.add('--files');
    cmdArgs.add('--glob');
    cmdArgs.add(pattern);
    cmdArgs.add('--sort-path');
    cmdArgs.add(path);

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
        if (lines.length > 100) {
          final kept = lines.take(100).join('\n');
          return ToolResult(
            title: 'Glob: $pattern',
            output: kept + '\n... and ${lines.length - 100} more',
            truncated: true,
          );
        }
        return ToolResult(title: 'Glob: $pattern', output: output.trim());
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
}

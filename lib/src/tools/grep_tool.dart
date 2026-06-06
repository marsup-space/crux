import 'dart:io';

import 'tool_def.dart';

class GrepTool extends ToolDef {
  @override
  String get name => 'grep';

  @override
  String collapsedSummary(Map<String, dynamic> args, ToolResult result) {
    final pattern = args['pattern'] as String? ?? '';
    final matchCount = '\n'.allMatches(result.output).length + 1;
    return '"$pattern": $matchCount matches';
  }

  @override
  String get description =>
      'Search file contents with regex. '
      'Returns file paths and line numbers with matches. '
      'For match counts, use Bash with `rg` directly.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'pattern': {'type': 'string', 'description': 'Regex pattern to search'},
      'path': {
        'type': 'string',
        'description': 'Directory to search in (default: cwd)',
      },
      'include': {'type': 'string', 'description': 'File pattern filter'},
      'caseInsensitive': {
        'type': 'boolean',
        'description': 'Case-insensitive search',
      },
      'context': {
        'type': 'integer',
        'description': 'Context lines around each match',
      },
      'headLimit': {'type': 'integer', 'description': 'Max results to return'},
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
    final include = args['include'] as String?;
    final caseInsensitive = (args['caseInsensitive'] as bool?) ?? false;
    final context = args['context'] as int?;
    final headLimit = args['headLimit'] as int?;

    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('Missing required parameter: pattern');
    }

    final cmdArgs = <String>[];
    cmdArgs.add('--line-number');
    cmdArgs.add('--with-filename');
    cmdArgs.add('--sort-path');

    if (caseInsensitive) cmdArgs.add('-i');
    if (include != null) {
      cmdArgs.add('--glob');
      cmdArgs.add(include);
    }
    if (context != null) {
      cmdArgs.add('-C');
      cmdArgs.add(context.toString());
    }
    if (headLimit != null) {
      cmdArgs.add('-m');
      cmdArgs.add(headLimit.toString());
    }

    cmdArgs.add(pattern);
    cmdArgs.add(path);

    try {
      final result = await Process.run('rg', cmdArgs);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        if (output.isEmpty) {
          return ToolResult(
            title: 'Grep: $pattern',
            output: 'No matches found',
          );
        }
        return ToolResult(title: 'Grep: $pattern', output: output.trim());
      }
      if (result.exitCode == 1) {
        return ToolResult(title: 'Grep: $pattern', output: 'No matches found');
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

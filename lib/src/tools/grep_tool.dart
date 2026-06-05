import 'dart:io';

import 'tool_def.dart';

class GrepTool extends ToolDef {
  @override
  String get name => 'grep';

  @override
  String get description =>
      '- Fast content search tool that works with any codebase size\n'
      '- Searches file contents using regular expressions\n'
      '- Supports full regex syntax (eg. "log.*Error", "function\\s+\\w+", etc.)\n'
      '- Filter files by pattern with the include parameter (eg. "*.js", "*.{ts,tsx}")\n'
      '- Returns file paths and line numbers with at least one match sorted by modification time\n'
      '- Use this tool when you need to find files containing specific patterns\n'
      '- If you need to identify/count the number of matches within files, use the Bash tool with `rg` (ripgrep) directly. '
      'Do NOT use `grep`.\n'
      '- When you are doing an open-ended search that may require multiple rounds of globbing and grepping, '
      'use the Task tool instead';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'The regex pattern to search for in file contents',
      },
      'path': {
        'type': 'string',
        'description':
            'Directory to search in (defaults to current working directory)',
      },
      'include': {
        'type': 'string',
        'description': 'File pattern to include (e.g. "*.js", "*.{ts,tsx}")',
      },
      'caseInsensitive': {
        'type': 'boolean',
        'description': 'Case-insensitive search (-i)',
      },
      'context': {
        'type': 'integer',
        'description': 'Number of lines around each match (-C)',
      },
      'headLimit': {
        'type': 'integer',
        'description': 'Maximum number of results to return',
      },
    },
    'required': ['pattern'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = args['pattern'] as String?;
    final path = (args['path'] as String?) ?? ctx.workingDirectory;
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

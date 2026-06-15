import 'dart:io';

import '../utils/bundled_executable.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

const _maxMatches = 100;
const _maxLineLength = 2000;

class GrepTool extends ToolDef {
  @override
  String get name => 'grep';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final pattern = args['pattern'] as String? ?? '';
    final total = result.metadata['totalMatches'] as int? ?? 0;
    final costTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final suffix = result.truncated ? ' [truncated]' : '';
    return CollapsedSummary(
      text: '"$pattern": $total matches$suffix',
      argsTokens: costTokens,
      totalTokens: costTokens,
    );
  }

  @override
  String get description =>
      'Search file contents with ripgrep regex syntax. '
      'Returns file paths and line numbers with matches, '
      'up to $_maxMatches results. '
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
      'headLimit': {
        'type': 'integer',
        'description': 'Max results to return',
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
    final include = args['include'] as String?;
    final caseInsensitive = (args['caseInsensitive'] as bool?) ?? false;
    final context = args['context'] as int?;
    final headLimit = args['headLimit'] as int?;

    if (pattern == null || pattern.isEmpty) {
      return ToolResult.error('Missing required parameter: pattern');
    }

    return _executeRipgrep(
      pattern: pattern,
      path: path,
      ctx: ctx,
      include: include,
      caseInsensitive: caseInsensitive,
      context: context,
      headLimit: headLimit,
    );
  }

  Future<ToolResult> _executeRipgrep({
    required String pattern,
    required String path,
    required ToolContext ctx,
    String? include,
    bool caseInsensitive = false,
    int? context,
    int? headLimit,
  }) async {
    final cmdArgs = <String>[
      '--no-config',
      '--color=never',
      '--path-separator',
      '/',
    ];
    cmdArgs.add('--line-number');
    cmdArgs.add('--with-filename');
    cmdArgs.add('--sort=path');
    cmdArgs.add('--max-columns');
    cmdArgs.add(_maxLineLength.toString());

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
      final executable = await resolveBundledExecutable(
        Platform.isWindows ? 'rg.exe' : 'rg',
      );
      final result = await Process.run(executable, cmdArgs);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        if (output.isEmpty) {
          return ToolResult(
            title: 'Grep: $pattern',
            output: 'No matches found',
            truncated: false,
            metadata: {'totalMatches': 0, 'truncated': false},
          );
        }
        final relativeOutput = _makePathsRelative(
          output.trim(),
          ctx.workingDirectory,
        );
        return _applyLimits(relativeOutput, pattern);
      }
      if (result.exitCode == 1) {
        return ToolResult(
          title: 'Grep: $pattern',
          output: 'No matches found',
          truncated: false,
          metadata: {'totalMatches': 0, 'truncated': false},
        );
      }
      final stderr = result.stderr as String;
      if (stderr.isNotEmpty) {
        return ToolResult.error('ripgrep error: ${stderr.trim()}');
      }
      return ToolResult.error('ripgrep exited with code ${result.exitCode}');
    } on ProcessException catch (error) {
      return ToolResult.error(
        'Unable to start bundled ripgrep: ${error.message}',
      );
    }
  }

  ToolResult _applyLimits(String output, String pattern) {
    final lines = output.split('\n');
    final totalMatches = lines.length;
    final wasTruncated = totalMatches > _maxMatches;

    final kept = wasTruncated ? lines.sublist(0, _maxMatches) : lines;
    final truncatedLines = kept.map((line) {
      if (line.length > _maxLineLength) {
        return '${line.substring(0, _maxLineLength)}...';
      }
      return line;
    }).join('\n');

    final header = wasTruncated
        ? 'Found $totalMatches matches (showing first $_maxMatches)\n'
        : '';
    final footer = wasTruncated
        ? '\n\n(Results truncated: showing $_maxMatches of $totalMatches matches '
            '${totalMatches - _maxMatches} hidden). '
            'Consider using a more specific path or pattern.)'
        : '';

    return ToolResult(
      title: 'Grep: $pattern',
      output: '$header$truncatedLines$footer',
      truncated: wasTruncated,
      metadata: {'totalMatches': totalMatches, 'truncated': wasTruncated},
    );
  }

  String _makePathsRelative(String output, String workingDirectory) {
    final normalizedWorkingDirectory = workingDirectory.replaceAll('\\', '/');
    final prefix = '$normalizedWorkingDirectory/';
    return output
        .split('\n')
        .map((line) {
          final normalizedLine = line.replaceAll('\\', '/');
          if (normalizedLine.startsWith(prefix)) {
            final colonIdx = line.indexOf(':', prefix.length);
            if (colonIdx != -1) {
              return normalizedLine.substring(prefix.length);
            }
            return normalizedLine.substring(prefix.length);
          }
          return normalizedLine;
        })
        .join('\n');
  }
}

import 'dart:io';

import 'package:glob/glob.dart';

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
    final tokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final suffix = result.truncated ? ' [truncated]' : '';
    return CollapsedSummary(
      text: '"$pattern": $total matches$suffix',
      tokens: tokens,
    );
  }

  @override
  String get description =>
      'Search file contents with regex. '
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

    if (Platform.isWindows) {
      return _executeDart(
        pattern: pattern,
        root: path,
        ctx: ctx,
        include: include,
        caseInsensitive: caseInsensitive,
        context: context,
        headLimit: headLimit,
      );
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
    final cmdArgs = <String>[];
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
      final result = await Process.run('rg', cmdArgs);
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
    } catch (e) {
      return ToolResult.error(
        'ripgrep not available: $e. Install ripgrep or use bash tool.',
      );
    }
  }

  Future<ToolResult> _executeDart({
    required String pattern,
    required String root,
    required ToolContext ctx,
    String? include,
    bool caseInsensitive = false,
    int? context,
    int? headLimit,
  }) async {
    try {
      final RegExp regex;
      try {
        regex = RegExp(pattern, caseSensitive: !caseInsensitive);
      } catch (e) {
        return ToolResult.error('Invalid regex: $e');
      }

      final includeGlob = include != null
          ? Glob(include.replaceAll('\\', '/'), recursive: true)
          : null;

      final rootType = FileSystemEntity.typeSync(root);
      if (rootType == FileSystemEntityType.notFound) {
        return ToolResult.error(
            'Path not found: ${relativePath(root, ctx.workingDirectory)}');
      }

      final Iterable<FileSystemEntity> entries;
      if (rootType == FileSystemEntityType.directory) {
        entries = Directory(root).listSync(recursive: true, followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
      } else {
        entries = [File(root)];
      }

      final lines = <String>[];
      var totalMatches = 0;
      var truncated = false;

      outer:
      for (final entry in entries) {
        if (entry is! File) continue;
        if (includeGlob != null &&
            !includeGlob.matches(entry.path.replaceAll('\\', '/'))) {
          continue;
        }
        String content;
        try {
          content = entry.readAsStringSync();
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
        final relPath = relativePath(entry.path, ctx.workingDirectory);
        final entryLines = content.split('\n');
        for (var i = 0; i < entryLines.length; i++) {
          if (!regex.hasMatch(entryLines[i])) continue;
          if (context != null && context > 0) {
            final start = (i - context).clamp(0, entryLines.length);
            final end = (i + context + 1).clamp(0, entryLines.length);
            for (var j = start; j < end; j++) {
              lines.add('$relPath-${j + 1}-$j-$j:${entryLines[j]}');
            }
          } else {
            lines.add('$relPath-${i + 1}:${entryLines[i]}');
          }
          totalMatches++;
          if (lines.length >= _maxMatches) {
            truncated = true;
            break outer;
          }
        }
      }

      if (totalMatches == 0) {
        return ToolResult(
          title: 'Grep: $pattern',
          output: 'No matches found',
          truncated: false,
          metadata: {'totalMatches': 0, 'truncated': false},
        );
      }

      final kept = lines.map((line) {
        if (line.length > _maxLineLength) {
          return '${line.substring(0, _maxLineLength)}...';
        }
        return line;
      }).join('\n');

      final header = truncated
          ? 'Found at least $totalMatches matches (showing first $_maxMatches)\n'
          : '';
      final footer = truncated
          ? '\n\n(Results truncated: showing $_maxMatches matches. '
              'Consider a more specific path or pattern.)'
          : '';

      return ToolResult(
        title: 'Grep: $pattern',
        output: '$header$kept$footer',
        truncated: truncated,
        metadata: {'totalMatches': totalMatches, 'truncated': truncated},
      );
    } catch (e) {
      return ToolResult.error('grep failed: $e');
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
    final prefix = '$workingDirectory/';
    return output
        .split('\n')
        .map((line) {
          if (line.startsWith(prefix)) {
            final colonIdx = line.indexOf(':', prefix.length);
            if (colonIdx != -1) {
              return line.substring(prefix.length);
            }
            return line.substring(prefix.length);
          }
          return line;
        })
        .join('\n');
  }
}

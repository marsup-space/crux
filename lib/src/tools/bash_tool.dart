import 'dart:io';

import 'tool_def.dart';

const _maxLines = 2000;

class BashTool extends ToolDef {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes bash command with optional timeout. '
      'Prefer bash over multiple tool calls when operations can be chained.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'The command to execute'},
      'timeout': {
        'type': 'integer',
        'description': 'Optional timeout in milliseconds (default 120000)',
      },
    },
    'required': ['command'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final command = args['command'] as String?;
    final timeoutMs = (args['timeout'] as int?) ?? 120000;

    if (command == null || command.isEmpty) {
      return ToolResult.error('Missing required parameter: command');
    }

    try {
      final result =
          await Process.run(
            '/bin/bash',
            ['-c', command],
            workingDirectory: ctx.workingDirectory,
            runInShell: true,
          ).timeout(
            Duration(milliseconds: timeoutMs),
            onTimeout: () {
              return ProcessResult(
                -1,
                -1,
                '',
                'Command timed out after ${timeoutMs}ms',
              );
            },
          );

      final combined = StringBuffer();
      final stderr = result.stderr as String;
      final stdout = result.stdout as String;
      if (stderr.isNotEmpty) {
        combined.writeln(stderr);
      }
      combined.write(stdout);

      var output = combined.toString();
      String? outputPath;
      var truncated = false;

      final lines = output.split('\n');
      if (lines.length > _maxLines) {
        final kept = lines.take(_maxLines).join('\n');
        output = kept;
        truncated = true;
        final tmpFile = File(
          '${Directory.systemTemp.path}/crux_bash_output_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        await tmpFile.writeAsString(combined.toString());
        outputPath = tmpFile.path;
      }

      final exitCode = result.exitCode;
      final suffix = exitCode == 0 ? '' : '\n\n[exit code: $exitCode]';

      return ToolResult(
        title: 'Ran: $command',
        output: output + suffix,
        truncated: truncated,
        outputPath: outputPath,
        metadata: {'exitCode': exitCode},
      );
    } catch (e) {
      return ToolResult.error('Failed to execute command: $e');
    }
  }
}

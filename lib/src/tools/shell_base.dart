import 'dart:io';

import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

const _maxLines = 2000;

class ShellInvocation {
  final String executable;
  final List<String> args;
  final List<String> cleanupPaths;

  const ShellInvocation({
    required this.executable,
    required this.args,
    this.cleanupPaths = const [],
  });
}

abstract class ShellBase extends ToolDef {
  ShellInvocation resolveInvocation(String command);

  Future<ProcessResult> _run(String command, Duration timeout) async {
    final invocation = resolveInvocation(command);
    try {
      return await Process.run(
        invocation.executable,
        invocation.args,
        runInShell: true,
      ).timeout(
        timeout,
        onTimeout: () => ProcessResult(
          -1,
          -1,
          '',
          'Command timed out after ${timeout.inMilliseconds}ms',
        ),
      );
    } finally {
      for (final path in invocation.cleanupPaths) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final command = args['command'] as String?;
    final timeoutMs = (args['timeout'] as int?) ?? 120000;

    if (command == null || command.isEmpty) {
      return ToolResult.error('Missing required parameter: command');
    }

    try {
      final result = await _run(command, Duration(milliseconds: timeoutMs));

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
          '${Directory.systemTemp.path}/crux_${name}_output_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        await tmpFile.writeAsString(combined.toString());
        outputPath = tmpFile.path;
      }

      final exitCode = result.exitCode;

      final tail = StringBuffer();
      if (truncated) {
        tail.writeln(
          '\n[output truncated to $_maxLines lines; full output: $outputPath]',
        );
      }
      if (exitCode != 0) {
        tail.write('\n[exit code: $exitCode]');
      }

      return ToolResult(
        title: 'Ran: $command',
        output: output + tail.toString(),
        truncated: truncated,
        outputPath: outputPath,
        metadata: {'exitCode': exitCode},
      );
    } catch (e) {
      return ToolResult.error('Failed to execute command: $e');
    }
  }

  @override
  String collapsedSummary(Map<String, dynamic> args, ToolResult result) {
    final command = args['command'] as String? ?? '';
    final preview = command.length > 30
        ? '${command.substring(0, 27)}...'
        : command;
    final exitCode = result.metadata['exitCode'];
    final suffix = exitCode != null && exitCode != 0 ? ' [exit $exitCode]' : '';
    final lines = '\n'.allMatches(result.output).length + 1;
    final size = result.output.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    final tokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return '$preview: $lines lines, $sizeStr, ~${tokens}t$suffix';
  }

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'Command to execute'},
      'timeout': {
        'type': 'integer',
        'description': 'Timeout in milliseconds (default 120000)',
      },
    },
    'required': ['command'],
  };
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/bundled_executable.dart';
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

/// Global registry of all running shell processes, keyed by session ID.
/// When the user interrupts a session, all registered processes for that
/// session are killed (including their process groups) so background
/// children don't survive.
class ShellProcessRegistry {
  static final ShellProcessRegistry instance = ShellProcessRegistry._();
  ShellProcessRegistry._();

  final Map<int, Set<_TrackedProcess>> _processes = {};

  /// Register a running [process] for [sessionId]. Returns the same
  /// [process] for convenience.
  Process register(int sessionId, Process process) {
    _processes.putIfAbsent(sessionId, () => {}).add(_TrackedProcess(process));
    return process;
  }

  /// Unregister a [process] from [sessionId] (e.g. when it exits
  /// normally).
  void unregister(int sessionId, Process process) {
    _processes[sessionId]?.removeWhere((t) => t.process == process);
    if (_processes[sessionId]?.isEmpty ?? false) {
      _processes.remove(sessionId);
    }
  }

  /// Kill all processes for [sessionId], including their process groups.
  /// Called when the user interrupts a response.
  void killAll(int sessionId) {
    final tracked = _processes.remove(sessionId);
    if (tracked == null) return;
    for (final t in tracked) {
      _killProcessGroup(t.process);
    }
  }

  /// Kill a process and its entire process group.
  static void _killProcessGroup(Process process) {
    try {
      if (Platform.isWindows) {
        process.kill();
      } else {
        // Send SIGTERM to the process group so child processes are
        // also killed (e.g. a shell pipeline, background jobs).
        // We use the shell `kill` command with negative PGID because
        // Dart's Process.killPid may not support negative PIDs. Never
        // signal Crux's own process group: normally-started Unix
        // children inherit it, and killing that group would deliver
        // SIGTERM back to the TUI.
        final pgid = _getPgid(process.pid);
        final ownPgid = _getPgid(pid);
        if (pgid != null && pgid != ownPgid) {
          Process.runSync('kill', ['-TERM', '--', '-$pgid']);
        }
        // Also kill the process itself as a fallback.
        process.kill();
      }
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  /// Get the process group ID for [pid] using `ps`.
  static int? _getPgid(int pid) {
    if (Platform.isWindows) return null;
    try {
      final result = Process.runSync(
        'ps',
        ['-o', 'pgid=', '-p', '$pid'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final output = (result.stdout as String).trim();
      if (output.isNotEmpty) {
        return int.tryParse(output);
      }
    } catch (_) {}
    return null;
  }
}

class _TrackedProcess {
  final Process process;
  _TrackedProcess(this.process);
}

abstract class ShellBase extends ToolDef with IntentionalTool {
  ShellInvocation resolveInvocation(String command, {String encoding = 'utf8'});

  ShellInvocation _prepareInvocation(ShellInvocation invocation) {
    if (Platform.isWindows) return invocation;

    // Dart's normal Process.start keeps Unix children in Crux's process
    // group. Wrap the shell in a tiny Perl setsid trampoline so timeout /
    // interrupt cleanup can signal the tool's group without signaling Crux.
    final perl = File('/usr/bin/perl').existsSync() ? '/usr/bin/perl' : 'perl';
    return ShellInvocation(
      executable: perl,
      args: [
        '-MPOSIX=setsid',
        '-e',
        r'setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n";',
        invocation.executable,
        ...invocation.args,
      ],
      cleanupPaths: invocation.cleanupPaths,
    );
  }

  /// Run a shell command using [Process.start] so it can be killed
  /// via the [abort] signal. The process is registered in the global
  /// [ShellProcessRegistry] so that an interrupt can kill it and all
  /// its children (including background processes) even if the abort
  /// signal hasn't been polled yet.
  Future<ProcessResult> _run(
    String command,
    Duration timeout, {
    String encoding = 'utf8',
    AbortSignal? abort,
  }) async {
    final invocation = _prepareInvocation(
      resolveInvocation(command, encoding: encoding),
    );
    final sessionId = abort?.sessionId;
    Process? process;
    try {
      final environment = Map<String, String>.from(Platform.environment);
      final bundledBin = await resolveBundledBinDirectory();
      if (bundledBin != null) {
        final separator = Platform.isWindows ? ';' : ':';
        final existingPath = environment['PATH'];
        environment['PATH'] = existingPath == null || existingPath.isEmpty
            ? bundledBin.path
            : '${bundledBin.path}$separator$existingPath';
      }
      process = await Process.start(
        invocation.executable,
        invocation.args,
        environment: environment,
        runInShell: Platform.isWindows,
        mode: ProcessStartMode.normal,
      );

      // Register the process so it can be killed by the global
      // interrupt handler even if the abort signal check hasn't
      // fired yet.
      if (sessionId != null) {
        ShellProcessRegistry.instance.register(sessionId, process);
      }

      // Set up abort watcher: when the abort signal fires, kill the
      // process group. We use a polling check because AbortSignal is
      // synchronous (no stream/listener API).
      Timer? abortCheckTimer;
      Completer<void>? abortCompleter;
      if (abort != null) {
        abortCompleter = Completer<void>();
        abortCheckTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
          if (abort.isAborted) {
            abortCheckTimer?.cancel();
            ShellProcessRegistry._killProcessGroup(process!);
            if (!abortCompleter!.isCompleted) {
              abortCompleter.complete();
            }
          }
        });
      }

      // Collect stdout and stderr.
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final stdoutFuture = process.stdout
          .transform(utf8.decoder)
          .forEach(stdoutBuf.write);
      final stderrFuture = process.stderr
          .transform(utf8.decoder)
          .forEach(stderrBuf.write);

      // Wait for the process to finish, with timeout and abort.
      final exitCodeFuture = process.exitCode;

      int exitCode;
      try {
        // Race: process completion vs timeout vs abort.
        final results = await Future.any<List<dynamic>>([
          exitCodeFuture.then((code) => [code]),
          Future.delayed(timeout, () => [-1]),
          if (abortCompleter != null) abortCompleter.future.then((_) => [-2]),
        ]);

        exitCode = results[0] as int;

        if (exitCode == -1) {
          // Timeout — kill the process group.
          ShellProcessRegistry._killProcessGroup(process);
        }

        // For abort, the abort watcher already killed the process.

        // Wait for stdout/stderr to drain. For timeout/abort, the
        // process is dead so the streams will close quickly. Use a
        // short timeout so we don't hang on misbehaving processes.
        if (exitCode == -1 || exitCode == -2) {
          try {
            exitCode = await process.exitCode.timeout(
              const Duration(seconds: 2),
            );
          } catch (_) {
            exitCode = -1;
          }
        }
        // Always wait for output streams to finish, with a timeout.
        try {
          await Future.wait([
            stdoutFuture,
            stderrFuture,
          ]).timeout(const Duration(seconds: 2));
        } catch (_) {
          // Streams may not close cleanly after kill; that's OK.
        }

        if (results[0] == -1) {
          return ProcessResult(
            process.pid,
            exitCode,
            stdoutBuf.toString(),
            'Command timed out after ${timeout.inMilliseconds}ms\n${stderrBuf.toString()}',
          );
        }

        if (results[0] == -2) {
          return ProcessResult(
            process.pid,
            exitCode,
            stdoutBuf.toString(),
            '[interrupted by user]${stderrBuf.toString().isNotEmpty ? '\n${stderrBuf.toString()}' : ''}',
          );
        }
      } finally {
        abortCheckTimer?.cancel();
      }

      return ProcessResult(
        process.pid,
        exitCode,
        stdoutBuf.toString(),
        stderrBuf.toString(),
      );
    } catch (e) {
      if (process != null && sessionId != null) {
        ShellProcessRegistry._killProcessGroup(process);
      }
      rethrow;
    } finally {
      // Unregister from the registry on any exit (normal, error, or abort).
      if (process != null && sessionId != null) {
        ShellProcessRegistry.instance.unregister(sessionId, process);
      }
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
    final intent = args['intent'] as String?;
    final timeoutMs = (args['timeout'] as int?) ?? 120000;
    final encoding = (args['encoding'] as String?) ?? 'utf8';

    if (command == null || command.isEmpty) {
      return ToolResult.error('Missing required parameter: command');
    }
    if (intent == null || intent.isEmpty) {
      return ToolResult.error('Missing required parameter: intent');
    }

    try {
      final result = await _run(
        command,
        Duration(milliseconds: timeoutMs),
        encoding: encoding,
        abort: ctx.abort,
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
        title: 'Ran: $command (intent: \'$intent\')',
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
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final exitCode = result.metadata['exitCode'];
    final suffix = exitCode != null && exitCode != 0 ? ' [exit $exitCode]' : '';
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
    // `bash` isn't a LargePayloadTool, so args-only == total.
    return CollapsedSummary(
      text: '$lines lines, $sizeStr$suffix',
      argsTokens: total,
      totalTokens: total,
    );
  }

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'Command to execute'},
      'intent': {
        'type': 'string',
        'description':
            'What this command accomplishes / why you are running it. Be concise.',
      },
      'timeout': {
        'type': 'integer',
        'description': 'Timeout in milliseconds (default 120000)',
      },
      'encoding': {
        'type': 'string',
        'description':
            'Output encoding (default utf8). '
            'Also sets shell code page: for cmd, maps to chcp; '
            'for powershell, sets [Console]::OutputEncoding.',
      },
    },
    'required': ['command', 'intent'],
  };
}

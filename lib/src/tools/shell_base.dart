import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/bundled_executable.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'shell_guard.dart';
import 'shell_risk.dart';
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

    // ── Shell-tool fallback guard ─────────────────────────────────
    // Detect bash+cat/sed/rg fallbacks and apply the three-tier
    // escalation (mild / firm / reject). The detector runs BEFORE
    // the subprocess so the reject tier can short-circuit before
    // any work happens. The mild/firm tiers run the command
    // normally and append an embedded reminder to the result.
    //
    // State lives on the session runtime (passed via ToolContext).
    // If no runtime is attached (e.g. a unit-test invocation that
    // synthesises its own ToolContext), the detector still runs
    // with `currentStreak = 0` so it returns a mild verdict and
    // the call runs + appends a reminder — never a hard reject.
    // That keeps the guard harmless in test setups while still
    // correct for production sessions.
    //
    // Env override: `CRUX_DISABLE_SHELL_GUARD=1` short-circuits the
    // detector entirely so users who find the reminder noisy can
    // opt out without code changes.
    final runtime = ctx.sessionRuntime;
    final currentStreak = runtime?.consecutiveShellViolations ?? 0;
    final ShellGuardVerdict? verdict;
    if (_shellGuardDisabled()) {
      verdict = null;
    } else {
      verdict = detectShellGuard(
        command,
        isWindows: Platform.isWindows,
        currentStreak: currentStreak,
      );
    }

    if (verdict != null && verdict.severity == ShellGuardSeverity.reject) {
      // Third (or later) consecutive violation: refuse to execute.
      // Increment the streak so a fourth attempt is also rejected
      // and the user-facing bubble's ordinal ("3rd", "4th", …)
      // stays accurate. Title is `'Error'` so the chat service's
      // existing `_shouldAbortParallelToolSiblings` aborts sibling
      // tool calls in the same round — the LLM should reflect on
      // the rejection before issuing more commands.
      if (runtime != null) {
        runtime.consecutiveShellViolations = verdict.streakAfter;
      }
      return ToolResult(
        title: 'Error',
        output: renderShellGuardRejection(verdict),
        metadata: {
          'shellGuard': true,
          'shellGuardKind': verdict.kind.name,
          'shellGuardSeverity': verdict.severity.name,
          'shellGuardStreakAfter': verdict.streakAfter,
        },
      );
    }

    // ── Shell high-risk guardrail (layers 1+2) ────────────────────
    // Runs AFTER the shell-tool fallback guard above and BEFORE the
    // subprocess. Layer 1 is the pure heuristic pre-screen
    // (`assessShellRiskHeuristic`); layer 2 is the auxiliary model,
    // reached via `ctx.shellRiskEvaluator`. See shell_risk.dart for
    // the tier contract. Two local accumulators carry state into the
    // success path below:
    //
    //   * [shellRiskNote] — a warning line appended to the output
    //     tail when a suspicious command is allowed through
    //     (confirmed bypass / fail-open), same append pattern as the
    //     mild/firm shell-guard reminders.
    //   * [shellRiskMeta] — metadata merged into the successful
    //     ToolResult. Rejections return early with title 'Error',
    //     which carries sibling-abort semantics — desired here: the
    //     model should reflect on a blocked dangerous command before
    //     issuing more tool calls. Deliberately does NOT set
    //     metadata['guardTriggered'], so the chat-log
    //     no-op/compaction branches stay out of this path.
    //
    // Env override: CRUX_DISABLE_SHELL_RISK_GUARD=1 (or 'true') skips
    // the whole block. Read from the RUNTIME environment — unlike
    // `_shellGuardDisabled`'s compile-time String.fromEnvironment,
    // operators expect a plain shell env var to work.
    final confirmed = args['confirmed'] == true;
    String? shellRiskNote;
    Map<String, dynamic>? shellRiskMeta;
    if (!_shellRiskGuardDisabled()) {
      final risk = assessShellRiskHeuristic(
        command,
        isWindows: Platform.isWindows,
      );
      switch (risk.tier) {
        case ShellRiskTier.safe:
          // Zero-overhead fast path: no evaluator call, no metadata.
          break;
        case ShellRiskTier.catastrophic:
          // Hard block with no appeal — `confirmed: true` and the aux
          // model are both irrelevant by design (see the tier-policy
          // notes in shell_risk.dart).
          return ToolResult(
            title: 'Error',
            output: _renderShellRiskCatastrophicRejection(
              command,
              risk.reason ?? 'matched a catastrophic pattern',
            ),
            metadata: {
              'shellRisk': 'blocked-catastrophic',
              'shellRiskReason': risk.reason,
            },
          );
        case ShellRiskTier.suspicious:
          final heuristicReason = risk.reason ?? 'flagged as suspicious';
          if (confirmed) {
            // The user approved THIS exact command out-of-band; the
            // schema description for `confirmed` says so. Run it,
            // but leave a trace in the output.
            shellRiskNote = '\n[shell-risk: confirmed bypass] This command '
                'was flagged as suspicious ($heuristicReason) and executed '
                'only because `confirmed: true` was passed after explicit '
                'user approval.';
            shellRiskMeta = {'shellRisk': 'confirmed-bypass'};
          } else {
            final evaluator = ctx.shellRiskEvaluator;
            if (evaluator == null) {
              // No aux model wired (tests, or a setup without an
              // auxiliary model configured at the executor level) —
              // fail open rather than block work we cannot review.
              shellRiskNote = '\n[shell-risk: fail-open] WARNING — this '
                  'command was flagged as suspicious ($heuristicReason), '
                  'but no auxiliary-model reviewer is configured. It was '
                  'executed without a second opinion.';
              shellRiskMeta = {'shellRisk': 'fail-open'};
            } else {
              ShellRiskVerdict verdict;
              try {
                verdict = await evaluator(
                  command,
                  intent: intent,
                  isWindows: Platform.isWindows,
                  abort: ctx.abort,
                );
              } catch (_) {
                // A throwing evaluator is indistinguishable from
                // "assessment unavailable" — same fail-open policy as
                // the aux service's own timeout/error paths.
                verdict = const ShellRiskVerdict(
                  ShellRiskVerdictKind.unavailable,
                );
              }
              switch (verdict.kind) {
                case ShellRiskVerdictKind.safe:
                  // Clean bill — no output noise, just the metadata.
                  shellRiskMeta = {'shellRisk': 'evaluated-safe'};
                case ShellRiskVerdictKind.unsafe:
                case ShellRiskVerdictKind.uncertain:
                  return ToolResult(
                    title: 'Error',
                    output: _renderShellRiskEscalatedRejection(
                      command: command,
                      heuristicReason: heuristicReason,
                      verdict: verdict,
                    ),
                    metadata: {
                      'shellRisk':
                          verdict.kind == ShellRiskVerdictKind.unsafe
                              ? 'blocked-unsafe'
                              : 'blocked-uncertain',
                      'shellRiskReason': verdict.reason,
                    },
                  );
                case ShellRiskVerdictKind.unavailable:
                  shellRiskNote = '\n[shell-risk: fail-open] WARNING — this '
                      'command was flagged as suspicious ($heuristicReason), '
                      'and the auxiliary-model risk review was unavailable '
                      '(not configured, timed out, or errored). It was '
                      'executed without a second opinion.';
                  shellRiskMeta = {'shellRisk': 'fail-open'};
              }
            }
          }
      }
    }

    // Final abort gate, after all guards and the (possibly slow)
    // aux-model evaluation: an interrupt that arrived anywhere above
    // must stop the command here. `_run`'s own abort watcher polls on
    // a 50ms tick, which a millisecond-scale command would beat, so
    // without this check an aborted-but-fail-open evaluation could
    // still execute.
    if (ctx.abort.isAborted) {
      return ToolResult.error('Aborted before execution');
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

      var finalOutput = output + tail.toString();

      // Shell-tool guard (mild / firm tier): append the embedded
      // reminder so the LLM sees it on the next round. Increment
      // the streak in the same atomic write so a future
      // parallel-call sibling running concurrently can't race the
      // counter (Dart is single-threaded per isolate, so the
      // runtime read+write is safe without a lock).
      Map<String, dynamic>? extraMetadata;
      if (verdict != null) {
        finalOutput = finalOutput + renderShellGuardEmbedded(verdict);
        if (runtime != null) {
          runtime.consecutiveShellViolations = verdict.streakAfter;
        }
        extraMetadata = {
          'shellGuard': true,
          'shellGuardKind': verdict.kind.name,
          'shellGuardSeverity': verdict.severity.name,
          'shellGuardStreakAfter': verdict.streakAfter,
        };
      }

      // High-risk guardrail pass-throughs: append the bypass /
      // fail-open warning and merge the guardrail metadata.
      if (shellRiskNote != null) {
        finalOutput = finalOutput + shellRiskNote;
      }
      if (shellRiskMeta != null) {
        extraMetadata = {...?extraMetadata, ...shellRiskMeta};
      }

      return ToolResult(
        title: 'Ran: $command (intent: \'$intent\')',
        output: finalOutput,
        truncated: truncated,
        outputPath: outputPath,
        metadata: {
          'exitCode': exitCode,
          ...?extraMetadata,
        },
      );
    } catch (e) {
      // Keep the guardrail audit trail (confirmed-bypass / fail-open
      // warning + metadata) even when the subprocess itself failed —
      // losing it would hide that a flagged command was attempted.
      return ToolResult(
        title: 'Error',
        output: 'Failed to execute command: $e${shellRiskNote ?? ''}',
        metadata: {...?shellRiskMeta},
      );
    }
  }

  /// Check the env for the shell-guard opt-out. Exposed as a
  /// separate method (rather than inlined) so tests can stub it
  /// without monkey-patching global state.
  static bool _shellGuardDisabled() {
    try {
      const env = String.fromEnvironment('CRUX_DISABLE_SHELL_GUARD');
      if (env.isEmpty) return false;
      final lower = env.toLowerCase();
      return lower == '1' || lower == 'true' || lower == 'yes';
    } catch (_) {
      return false;
    }
  }

  /// Check the env for the high-risk-guardrail opt-out. Reads the
  /// RUNTIME environment (`Platform.environment`) — a plain shell
  /// env var must work here, unlike the compile-time
  /// `String.fromEnvironment` the fallback guard above uses. The
  /// accepted values match `_shellGuardDisabled`: 1 / true / yes.
  static bool _shellRiskGuardDisabled() {
    try {
      final env = Platform.environment['CRUX_DISABLE_SHELL_RISK_GUARD'];
      if (env == null || env.isEmpty) return false;
      final lower = env.toLowerCase();
      return lower == '1' || lower == 'true' || lower == 'yes';
    } catch (_) {
      return false;
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
      'confirmed': {
        'type': 'boolean',
        'description':
            'Set true only after the user has explicitly approved this '
            'exact command (e.g. via ask://). Skips the auxiliary-model '
            'risk evaluation for suspicious commands. Catastrophic '
            'commands are always blocked regardless.',
      },
    },
    'required': ['command', 'intent'],
  };
}

/// Rejection body for the catastrophic tier of the shell high-risk
/// guardrail: no appeal, no `confirmed` bypass, no aux-model review.
/// Tells the model to stop and hand the decision back to the user.
String _renderShellRiskCatastrophicRejection(
  String command,
  String reason,
) {
  return 'This shell command was BLOCKED by the high-risk command '
      'guardrail.\n'
      '\n'
      '• verdict: CATASTROPHIC (heuristic pattern match — no model '
      'review applies)\n'
      '• reason: $reason\n'
      '• command: ${command.trim()}\n'
      '\n'
      'This block is not negotiable: the command matches a pattern of '
      'irreversible, system-wide damage (wiping the filesystem, '
      'formatting disks, raw device writes, fork bombs, shutting down '
      'the machine). It will not be executed by this tool under any '
      'circumstances — the `confirmed` parameter does not apply here.\n'
      '\n'
      'Do NOT retry this command, and do not attempt variations of it. '
      'Tell the user exactly what was blocked and why, and let them '
      'know that if they truly want to run it, they must execute it '
      'manually in their own terminal.';
}

/// Rejection body for a suspicious command the auxiliary model
/// judged UNSAFE or UNCERTAIN. Teaches the model the appeal path:
/// explain the risk, get explicit user approval, re-send the SAME
/// command with `confirmed: true`.
String _renderShellRiskEscalatedRejection({
  required String command,
  required String heuristicReason,
  required ShellRiskVerdict verdict,
}) {
  final verdictLabel =
      verdict.kind == ShellRiskVerdictKind.unsafe ? 'UNSAFE' : 'UNCERTAIN';
  final verdictReason =
      (verdict.reason == null || verdict.reason!.isEmpty)
          ? 'no reason given'
          : verdict.reason!;
  return 'This shell command was BLOCKED by the high-risk command '
      'guardrail.\n'
      '\n'
      '• heuristic verdict: SUSPICIOUS — $heuristicReason\n'
      '• auxiliary model verdict: $verdictLabel — $verdictReason\n'
      '• command: ${command.trim()}\n'
      '\n'
      'Next step: explain the risk to the user in plain language. If '
      'the user explicitly approves THIS EXACT command (for example '
      'via an ask:// confirmation button), re-send the same command '
      'with `confirmed: true` to skip the auxiliary-model review. Do '
      'not silently retry, and do not rephrase the command to evade '
      'the guardrail.';
}

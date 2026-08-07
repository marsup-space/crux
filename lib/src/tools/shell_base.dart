import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/auxiliary_prompts.dart';
import '../utils/bundled_executable.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'shell_guard.dart';
import 'shell_monitor.dart';
import 'shell_progress_parser.dart';
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
  ///
  /// Two supervision regimes, chosen by whether [monitor] is null:
  ///
  ///   * null (no auxiliary model configured): classic timeout. The
  ///     process races [timeout]; on expiry the process group is
  ///     killed and the result reports the timeout.
  ///   * non-null (auxiliary model configured): the static [timeout]
  ///     is NOT armed. Instead the monitor loop snapshots the process
  ///     at model-scheduled intervals and asks the auxiliary model
  ///     whether it is still making progress, in one continuing
  ///     conversation. A STUCK verdict kills the process group. If
  ///     the monitor itself fails (aux timeout / transport error),
  ///     [timeout] is armed from that moment as a fallback so a dead
  ///     reviewer degrades to classic behaviour instead of running
  ///     forever. See `lib/src/tools/shell_monitor.dart` for the
  ///     contract and the fail-open rationale.
  ///
  /// When [monitorLogSink] is also non-null, the loop emits one
  /// [ShellMonitorEvent] per check (plus run-start and run-finish) so
  /// the run's verdict history lands in `shell_monitor_logs` for
  /// `/d-monitor`. The sink is fail-open: logging never kills the
  /// process.
  ///
  /// When [progressSink] is non-null, the raw output streams are
  /// tapped (read-only — the buffered output returned to the LLM is
  /// untouched) and parsed for progress signals, which are forwarded
  /// as normalized [ShellProgress] snapshots to the vibe progress
  /// box. Unlike the aux-model monitor, this works with or without an
  /// auxiliary model configured. Also fail-open: parsing or sink
  /// errors never affect the command's result.
  Future<ProcessResult> _run(
    String command,
    Duration timeout, {
    String encoding = 'utf8',
    AbortSignal? abort,
    ShellMonitorEvaluator? monitor,
    ShellMonitorLogSink? monitorLogSink,
    ShellProgressSink? progressSink,
    String intent = '',
    String platform = '',
    String shellExecutable = '',
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

      // Collect stdout and stderr, tracking byte counts for the
      // monitor's liveness signal.
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      var totalOutputBytes = 0;

      // ── Live progress extraction ──────────────────────────────
      // Read-only tap on the raw output streams: one parser per
      // stream (so a `\r` meter on stderr never corrupts a partial
      // stdout line), merged before each emit. The buffered output
      // the LLM sees is untouched — this is a pure side channel.
      final runStart = DateTime.now();
      final stdoutProgress =
          progressSink != null ? ShellProgressParser() : null;
      final stderrProgress =
          progressSink != null ? ShellProgressParser() : null;
      String lastProgressSig = '';
      DateTime? lastProgressEmitAt;
      void maybeEmitProgress() {
        if (progressSink == null) return;
        final merged = mergeShellProgress(
          stdoutProgress?.progress,
          stderrProgress?.progress,
        );
        if (merged == null) return;
        // Debounce: only forward when a displayed field changed AND
        // the previous emit is ≥250ms old. The lastLine is part of
        // the signature so a phase-only stream still refreshes the
        // "what is it doing" row live, at a bounded rate.
        final sig =
            '${merged.percent}|${merged.phase}|${merged.ratePerSec}'
            '|${merged.eta}|${merged.current}/${merged.total}|${merged.lastLine}';
        final now = DateTime.now();
        if (sig == lastProgressSig) return;
        if (lastProgressEmitAt != null &&
            now.difference(lastProgressEmitAt!) <
                const Duration(milliseconds: 250)) {
          return;
        }
        lastProgressSig = sig;
        lastProgressEmitAt = now;
        progressSink.update(merged, command: command);
      }

      final stdoutFuture = process.stdout.transform(utf8.decoder).forEach((
        chunk,
      ) {
        totalOutputBytes += chunk.length;
        stdoutBuf.write(chunk);
        if (stdoutProgress != null) {
          stdoutProgress.addChunk(chunk);
          maybeEmitProgress();
        }
      });
      final stderrFuture = process.stderr.transform(utf8.decoder).forEach((
        chunk,
      ) {
        totalOutputBytes += chunk.length;
        stderrBuf.write(chunk);
        if (stderrProgress != null) {
          stderrProgress.addChunk(chunk);
          maybeEmitProgress();
        }
      });

      // Wait for the process to finish, with timeout and abort.
      final exitCodeFuture = process.exitCode;

      // ── Progress monitor (aux-model regime) ───────────────────
      // When [monitor] is set, run the monitor loop alongside the
      // process. It completes [monitorKillCompleter] only when the
      // model returns a STUCK verdict (fail-open: PROGRESS /
      // UNCERTAIN / unavailable all keep the process running). The
      // loop owns the continuing conversation so the model sees its
      // own prior verdicts and the static prefix stays byte-identical
      // for KV cache reuse.
      Completer<String>? monitorKillCompleter;
      Timer? monitorFallbackTimer;
      if (monitor != null) {
        monitorKillCompleter = Completer<String>();
        final monitorMessages = <Map<String, dynamic>>[
          {'role': 'system', 'content': shellMonitorSystemPrompt},
        ];
        final startTime = DateTime.now();
        var checkNumber = 0;
        DateTime? previousCheckTime;
        var previousTotalBytes = 0;

        int elapsedSecs() => DateTime.now().difference(startTime).inSeconds;
        String cappedTail(String buf) {
          if (buf.isEmpty) return '';
          return buf.length <= kMonitorLogTailMaxChars
              ? buf
              : buf.substring(buf.length - kMonitorLogTailMaxChars);
        }

        // Run-start event: lets /d-monitor show "this command was
        // monitored from T+0" even when the run never reaches the
        // first check (short commands finish before
        // kMonitorFirstCheckSeconds and skip the loop entirely).
        monitorLogSink?.log(
          ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0),
        );

        Future<void> monitorLoop() async {
          var nextDelay = const Duration(seconds: kMonitorFirstCheckSeconds);
          while (true) {
            await Future<void>.delayed(nextDelay);
            if (monitorKillCompleter!.isCompleted) return;
            if (abort?.isAborted ?? false) return;

            checkNumber++;
            final now = DateTime.now();
            final elapsed = now.difference(startTime);
            final sincePrevious = previousCheckTime == null
                ? null
                : now.difference(previousCheckTime!);
            final newBytes = totalOutputBytes - previousTotalBytes;
            // ~1KB output tail: the actual evidence for the verdict.
            final stdoutSoFar = stdoutBuf.toString();
            final tail = stdoutSoFar.length <= 1024
                ? stdoutSoFar
                : stdoutSoFar.substring(stdoutSoFar.length - 1024);

            monitorMessages.add({
              'role': 'user',
              'content': buildShellMonitorUserMessage(
                snapshot: ShellMonitorSnapshot(
                  checkNumber: checkNumber,
                  elapsed: elapsed,
                  sincePreviousCheck: sincePrevious,
                  newOutputBytes: newBytes,
                  totalOutputBytes: totalOutputBytes,
                  outputTail: tail,
                ),
                command: checkNumber == 1 ? command : null,
                intent: checkNumber == 1 ? intent : null,
                platform: checkNumber == 1 ? platform : null,
                shell: checkNumber == 1 ? shellExecutable : null,
              ),
            });

            ShellMonitorVerdict verdict;
            try {
              verdict = await monitor(
                monitorMessages,
                abort: abort ?? AbortSignal(),
              );
              // A responsive monitor disarms the failure fallback.
              monitorFallbackTimer?.cancel();
              monitorFallbackTimer = null;
            } catch (e) {
              // A throwing evaluator is indistinguishable from
              // "monitor unavailable" — fail open (keep running) and
              // arm the static-timeout fallback so a permanently-dead
              // reviewer degrades to classic behaviour.
              verdict = const ShellMonitorVerdict(
                ShellMonitorVerdictKind.uncertain,
              );
              monitorLogSink?.log(
                ShellMonitorEvent(
                  checkNumber: checkNumber,
                  elapsedSeconds: elapsedSecs(),
                  newOutputBytes: newBytes,
                  totalOutputBytes: totalOutputBytes,
                  verdict: 'EVAL_ERROR',
                  reason: '$e',
                  outputTail: cappedTail(stdoutBuf.toString()),
                ),
              );
              monitorFallbackTimer ??= Timer(timeout, () {
                if (!monitorKillCompleter!.isCompleted) {
                  monitorLogSink?.log(
                    ShellMonitorEvent(
                      checkNumber: checkNumber,
                      elapsedSeconds: elapsedSecs(),
                      verdict: 'FALLBACK',
                      reason:
                          'progress monitor unavailable; fell back '
                          'to timeout after ${timeout.inMilliseconds}ms',
                    ),
                  );
                  monitorKillCompleter.complete(
                    'progress monitor unavailable; fell back to timeout '
                    'after ${timeout.inMilliseconds}ms',
                  );
                }
              });
              // The synthetic UNCERTAIN verdict above is NOT logged as
              // a check verdict — EVAL_ERROR already recorded what
              // happened, and logging both would double-count the
              // check in /d-monitor's timeline.
              previousCheckTime = now;
              previousTotalBytes = totalOutputBytes;
              nextDelay = Duration(seconds: verdict.intervalSeconds);
              continue;
            }

            // Record the assistant turn so the model sees its own
            // verdict next round (rate-of-progress reasoning).
            monitorMessages.add({
              'role': 'assistant',
              'content': _renderMonitorAssistantTurn(verdict),
            });

            monitorLogSink?.log(
              ShellMonitorEvent(
                checkNumber: checkNumber,
                elapsedSeconds: elapsedSecs(),
                newOutputBytes: newBytes,
                totalOutputBytes: totalOutputBytes,
                verdict: switch (verdict.kind) {
                  ShellMonitorVerdictKind.progress => 'PROGRESS',
                  ShellMonitorVerdictKind.stuck => 'STUCK',
                  ShellMonitorVerdictKind.uncertain => 'UNCERTAIN',
                },
                intervalSeconds: verdict.intervalSeconds,
                reason: verdict.reason,
                outputTail: cappedTail(stdoutBuf.toString()),
              ),
            );

            previousCheckTime = now;
            previousTotalBytes = totalOutputBytes;

            if (verdict.kind == ShellMonitorVerdictKind.stuck) {
              if (!monitorKillCompleter.isCompleted) {
                monitorKillCompleter.complete(
                  verdict.reason ?? 'monitor judged the process stuck',
                );
              }
              return;
            }
            nextDelay = Duration(seconds: verdict.intervalSeconds);
          }
        }

        unawaited(monitorLoop());
      }

      int exitCode;
      int?
      finishExitCode; // mirrors exitCode for the FINISH event; null = killed pre-exit
      String? monitorKillReason;
      try {
        // Race: process completion vs timeout vs abort vs monitor.
        final results = await Future.any<List<dynamic>>([
          exitCodeFuture.then((code) => [code]),
          if (monitor == null) Future.delayed(timeout, () => [-1]),
          if (abortCompleter != null) abortCompleter.future.then((_) => [-2]),
          if (monitorKillCompleter != null)
            monitorKillCompleter.future.then((reason) => [-3, reason]),
        ]);

        exitCode = results[0] as int;

        if (exitCode == -1) {
          // Timeout (classic regime) — kill the process group.
          ShellProcessRegistry._killProcessGroup(process);
        } else if (exitCode == -3) {
          // Monitor judged the process STUCK — kill the process group.
          monitorKillReason = results[1] as String;
          ShellProcessRegistry._killProcessGroup(process);
        }

        // For abort, the abort watcher already killed the process.

        // Wait for stdout/stderr to drain. For timeout/abort/monitor,
        // the process is dead so the streams will close quickly. Use a
        // short timeout so we don't hang on misbehaving processes.
        if (exitCode == -1 || exitCode == -2 || exitCode == -3) {
          try {
            exitCode = await process.exitCode.timeout(
              const Duration(seconds: 2),
            );
          } catch (_) {
            exitCode = -1;
          }
        }
        finishExitCode = exitCode;
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

        if (results[0] == -3) {
          return ProcessResult(
            process.pid,
            exitCode,
            stdoutBuf.toString(),
            '[killed by progress monitor: $monitorKillReason]'
            '${stderrBuf.toString().isNotEmpty ? '\n${stderrBuf.toString()}' : ''}',
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
        monitorFallbackTimer?.cancel();
        // Unblock the monitor loop if it is still sleeping so it can
        // observe completion and return without firing a late verdict.
        if (monitorKillCompleter != null && !monitorKillCompleter.isCompleted) {
          monitorKillCompleter.complete('');
        }
        // Run-finish event + flush. Awaited so the batch actually
        // lands before the tool returns; the sink swallows its own
        // DB errors (fail-open), so this can't turn a logging hiccup
        // into a tool failure.
        if (monitorLogSink != null) {
          final code = finishExitCode;
          monitorLogSink.log(
            ShellMonitorEvent(
              checkNumber: -1,
              elapsedSeconds: 0,
              verdict: 'FINISH',
              reason: code == null ? 'killed (no exit code)' : 'exit $code',
            ),
          );
          await monitorLogSink.finish(exitCode: code);
        }
        // Live progress finish: flush the trailing partial line (a
        // `\r` meter's last frame often has no terminator), mark the
        // registry entry done, and hand the caller the compact
        // summary for metadata stamping. Fail-open like the monitor
        // sink — never affects the tool result.
        if (progressSink != null && stdoutProgress != null) {
          stdoutProgress.finish();
          stderrProgress!.finish();
          final summary = _buildProgressSummary(
            stdoutProgress,
            stderrProgress,
            DateTime.now().difference(runStart).inSeconds,
            totalOutputBytes,
            finishExitCode,
          );
          progressSink.finish(exitCode: finishExitCode, summary: summary);
        }
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
            shellRiskNote =
                '\n[shell-risk: confirmed bypass] This command '
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
              shellRiskNote =
                  '\n[shell-risk: fail-open] WARNING — this '
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
                      'shellRisk': verdict.kind == ShellRiskVerdictKind.unsafe
                          ? 'blocked-unsafe'
                          : 'blocked-uncertain',
                      'shellRiskReason': verdict.reason,
                    },
                  );
                case ShellRiskVerdictKind.unavailable:
                  shellRiskNote =
                      '\n[shell-risk: fail-open] WARNING — this '
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
      // When an auxiliary model is configured, hand the run to the
      // progress monitor: the static timeout is NOT armed, the
      // monitor watches the process and kills only on a STUCK
      // verdict. When it is null, _run falls back to classic timeout
      // behaviour. Platform / shell are passed for the monitor's
      // static metadata block (first turn only).
      final invocation = resolveInvocation(command, encoding: encoding);
      final result = await _run(
        command,
        Duration(milliseconds: timeoutMs),
        encoding: encoding,
        abort: ctx.abort,
        monitor: ctx.shellMonitorEvaluator,
        monitorLogSink: ctx.shellMonitorLogSink,
        progressSink: ctx.shellProgressSink,
        intent: intent,
        platform: Platform.operatingSystem,
        shellExecutable: invocation.executable,
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

      // Progress summary for the persisted vibe progress box: present
      // only when the run actually produced detectable progress
      // signals. The sink's summary was set by _run's finish path.
      final progressSummary = ctx.shellProgressSink?.summary;
      if (progressSummary != null) {
        extraMetadata = {...?extraMetadata, 'shellProgress': progressSummary};
      }

      return ToolResult(
        title: 'Ran: $command (intent: \'$intent\')',
        output: finalOutput,
        truncated: truncated,
        outputPath: outputPath,
        metadata: {'exitCode': exitCode, ...?extraMetadata},
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

  /// Build the compact summary stamped into `ToolResult.metadata`
  /// under `'shellProgress'` for the persisted vibe progress box.
  /// Null when neither parser detected a corroborated signal — no
  /// box, no metadata noise.
  static Map<String, dynamic>? _buildProgressSummary(
    ShellProgressParser stdoutParser,
    ShellProgressParser stderrParser,
    int durationSec,
    int bytes,
    int? exitCode,
  ) {
    final out = stdoutParser.progress;
    final err = stderrParser.progress;
    if (out == null && err == null) return null;
    final phase = err?.phase ?? out?.phase;
    final peak = _maxNullable(
      stdoutParser.peakPercent,
      stderrParser.peakPercent,
    );
    return {
      'phase': ?phase,
      'peakPercent': ?peak,
      'durationSec': durationSec,
      'bytes': bytes,
      // Null exit (killed before an exit code) maps to non-zero so
      // the persisted box renders it as a failure, not a success.
      'exitCode': exitCode ?? -1,
    };
  }

  static double? _maxNullable(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  /// Render the compact assistant turn appended to the monitor
  /// conversation after each check. Kept terse on purpose: the
  /// assistant turns are the model's own prior verdicts, and a
  /// compact form keeps the continuing conversation small while
  /// still giving the model the rate-of-progress history it needs
  /// (the per-turn `since_previous_check` in the next user snapshot
  /// supplies the actual elapsed ground truth, so the interval the
  /// model asked for doesn't need to be recoverable from this text).
  static String _renderMonitorAssistantTurn(ShellMonitorVerdict verdict) {
    final word = switch (verdict.kind) {
      ShellMonitorVerdictKind.progress => 'PROGRESS',
      ShellMonitorVerdictKind.stuck => 'STUCK',
      ShellMonitorVerdictKind.uncertain => 'UNCERTAIN',
    };
    final base = '$word ${verdict.intervalSeconds}';
    final reason = verdict.reason;
    return (reason == null || reason.isEmpty) ? base : '$base — $reason';
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
        'description':
            'Timeout in milliseconds (default 120000). When an '
            'auxiliary model is configured, this is a FALLBACK only: '
            'it is not enforced while the auxiliary progress monitor '
            'is responsive, and is armed only if the monitor itself '
            'becomes unavailable. Without an auxiliary model it is a '
            'hard timeout.',
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
String _renderShellRiskCatastrophicRejection(String command, String reason) {
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
  final verdictLabel = verdict.kind == ShellRiskVerdictKind.unsafe
      ? 'UNSAFE'
      : 'UNCERTAIN';
  final verdictReason = (verdict.reason == null || verdict.reason!.isEmpty)
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

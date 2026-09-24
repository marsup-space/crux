import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/auxiliary_prompts.dart';
import '../services/shell_live_registry.dart';
import '../services/shell_monitor_notifier.dart' show ShellMonitorRegistry;
import '../utils/bundled_executable.dart';
import '../utils/setsid_spawn.dart' show resolvePerl, setsidTrampolineScript;
import '../utils/token_estimate.dart'
    show estimateTokens, estimateToolRoundTripTokens;
import 'shell_guard.dart';
import 'shell_monitor.dart';
import 'shell_risk.dart';
import 'tool_def.dart';

/// Shell results are sent back to the model as tool output. A line-only cap
/// is insufficient because a single minified line can be many thousands of
/// tokens, so enforce both a line and character budget.
const _maxLines = 2000;
const _outputHeadLines = _maxLines ~/ 2;
const _outputTailLines = _maxLines - _outputHeadLines;
const _maxOutputChars = 16 * 1024;
// Reserve room for the truncation and exit-status annotations appended after
// this payload is capped, keeping ordinary final tool results within ~4096.
const _maxOutputTokens = 4000;
const _outputHeadChars = 4 * 1024;
const _omissionMarker =
    '[... shell output omitted; see full output file for the middle ...]';
const _outputTailChars =
    _maxOutputChars - _outputHeadChars - _omissionMarker.length - 2;

class _CappedShellOutput {
  final String output;
  final bool truncated;
  final int originalChars;

  const _CappedShellOutput({
    required this.output,
    required this.truncated,
    required this.originalChars,
  });
}

/// Return a bounded view that retains both setup/context at the beginning and
/// the most actionable diagnostics at the end. The raw text is written to a
/// temporary file by the caller when [truncated] is true.
_CappedShellOutput _capShellOutput(String output) {
  final originalChars = output.length;
  final lines = output.split('\n');
  final lineTruncated = lines.length > _maxLines;
  final lineCapped = lineTruncated
      ? [
          ...lines.take(_outputHeadLines),
          _omissionMarker,
          ...lines.skip(lines.length - _outputTailLines),
        ].join('\n')
      : output;

  final tokenTruncated = estimateTokens(lineCapped) > _maxOutputTokens;
  if (lineCapped.length <= _maxOutputChars &&
      !lineTruncated &&
      !tokenTruncated) {
    return _CappedShellOutput(
      output: lineCapped,
      truncated: false,
      originalChars: originalChars,
    );
  }

  if (lineCapped.length <= _maxOutputChars && !tokenTruncated) {
    return _CappedShellOutput(
      output: lineCapped,
      truncated: true,
      originalChars: originalChars,
    );
  }

  final headChars = lineCapped.length < _outputHeadChars
      ? lineCapped.length
      : _outputHeadChars;
  final maxTailChars = lineCapped.length - headChars < _outputTailChars
      ? lineCapped.length - headChars
      : _outputTailChars;
  final head = lineCapped.substring(0, headChars);
  var low = 0;
  var high = maxTailChars;
  while (low < high) {
    final tailChars = (low + high + 1) ~/ 2;
    final candidate =
        '$head\n$_omissionMarker\n'
        '${lineCapped.substring(lineCapped.length - tailChars)}';
    if (estimateTokens(candidate) <= _maxOutputTokens) {
      low = tailChars;
    } else {
      high = tailChars - 1;
    }
  }
  final boundedOutput =
      '$head\n$_omissionMarker\n'
      '${lineCapped.substring(lineCapped.length - low)}';
  return _CappedShellOutput(
    output: boundedOutput,
    truncated: true,
    originalChars: originalChars,
  );
}

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

  /// Kill ONE process and its process group. Public entry for the
  /// live shell view's per-run kill button (via
  /// `ShellMonitorRegistry.killOne`); the group-kill semantics are
  /// identical to [killAll] — children die with the run.
  static void killProcess(Process process) => _killProcessGroup(process);

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
    return ShellInvocation(
      executable: resolvePerl(),
      args: [
        '-MPOSIX=setsid',
        '-e',
        setsidTrampolineScript,
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
  Future<ProcessResult> _run(
    String command,
    Duration timeout, {
    String encoding = 'utf8',
    AbortSignal? abort,
    ShellMonitorEvaluator? monitor,
    ShellMonitorLogSink? monitorLogSink,
    void Function(ShellMonitorNotice notice)? noticeSink,
    String intent = '',
    String platform = '',
    String shellExecutable = '',
    String callId = '',
  }) async {
    final invocation = _prepareInvocation(
      resolveInvocation(command, encoding: encoding),
    );
    final sessionId = abort?.sessionId;
    Process? process;
    // Live-view plumbing declared at function scope so the outer
    // finally can finish the entry on every exit path (the registry
    // singleton and the exit code are both visible there; variables
    // declared inside the try body would not be).
    final liveRegistry = ShellLiveRegistry.instance;
    int? liveFinishExitCode;
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
        // Every ShellInvocation already supplies its own interpreter.
        // A second Windows shell would nest cmd.exe around CmdTool's
        // temporary batch file, which surfaces a "Terminate batch job"
        // prompt when an interrupted run is cleaned up.
        runInShell: false,
        mode: ProcessStartMode.normal,
      );

      // Register the process so it can be killed by the global
      // interrupt handler even if the abort signal check hasn't
      // fired yet. The monitor registry mirrors it so the monitor
      // toast's kill button can query liveness and kill on demand.
      if (sessionId != null) {
        ShellProcessRegistry.instance.register(sessionId, process);
        ShellMonitorRegistry.instance.add(sessionId, process);
      }

      // ── Live shell view registration ─────────────────────────
      // Per-callId entry so the vibe tools box can show a live
      // "intent + elapsed" row and the live fullpane can stream this
      // run's raw output + monitor timeline + a per-run kill button.
      // Pure display side channel: every touch is fail-open and the
      // entry is finished in the finally block below.
      if (sessionId != null && callId.isNotEmpty) {
        try {
          liveRegistry.register(
            sessionId: sessionId,
            callId: callId,
            command: command,
            intent: intent,
            process: process,
          );
        } catch (_) {}
      }
      void tapLiveOutput(String chunk) {
        if (sessionId == null || callId.isEmpty) return;
        try {
          liveRegistry.appendOutput(sessionId, callId, chunk);
        } catch (_) {}
      }

      // Arm-time announcement for the no-aux regime (static timeout
      // applies). The monitor regime announces inside its own block
      // below. Purely informational for the toast channel.
      if (monitor == null) {
        noticeSink?.call(
          ShellMonitorNotice(
            configured: false,
            command: _trimmedDisplayCommand(command),
            intent: intent,
            kind: 'CONFIGURED',
            nextCheckSeconds: timeout.inSeconds,
          ),
        );
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

      final stdoutFuture = process.stdout.transform(utf8.decoder).forEach((
        chunk,
      ) {
        totalOutputBytes += chunk.length;
        stdoutBuf.write(chunk);
        tapLiveOutput(chunk);
      });
      final stderrFuture = process.stderr.transform(utf8.decoder).forEach((
        chunk,
      ) {
        totalOutputBytes += chunk.length;
        stderrBuf.write(chunk);
        tapLiveOutput(chunk);
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
        final monitorKill = Completer<String>();
        monitorKillCompleter = monitorKill;
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

        // Keep the monitor registry's stderr snapshot fresh so a
        // user kill from the toast can quote what the process was
        // last printing to stderr in the post-kill session note.
        void refreshStderrSnapshot() {
          ShellMonitorRegistry.instance.noteStderr(
            process!,
            cappedTail(stderrBuf.toString()),
          );
        }

        refreshStderrSnapshot();

        // Run-start event: lets /d-monitor show "this command was
        // monitored from T+0" even when the run never reaches the
        // first check (short commands finish before
        // kMonitorFirstCheckSeconds and skip the loop entirely).
        monitorLogSink?.log(
          ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0),
        );
        // Arm-time toast announcement: "this shell is now monitored;
        // first check at Ns" in display form. Skipped for an
        // unconfigured run's arm announcement only (handled above).
        noticeSink?.call(
          ShellMonitorNotice(
            configured: true,
            command: _trimmedDisplayCommand(command),
            intent: intent,
            kind: 'CONFIGURED',
            nextCheckSeconds: kMonitorFirstCheckSeconds,
          ),
        );

        Future<void> monitorLoop() async {
          var nextDelay = const Duration(seconds: kMonitorFirstCheckSeconds);
          // Zero-progress escalation state: consecutive checks with 0B
          // new output AND a byte-identical tail (0 = the last check
          // saw progress). See "Zero-progress escalation" in
          // shell_monitor.dart.
          var stallRun = 0;
          var lastStalledTail = '';
          while (true) {
            await Future<void>.delayed(nextDelay);
            if (monitorKill.isCompleted) return;
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

            // ── Zero-progress detection ─────────────────────────
            // Fully stalled = nothing printed since the previous
            // check AND the visible tail unchanged byte-for-byte.
            // Any progress resets the run. (First check has no
            // baseline to compare against.)
            final fullyStalled =
                newBytes == 0 && checkNumber > 1 && tail == lastStalledTail;
            stallRun = fullyStalled ? stallRun + 1 : 0;
            lastStalledTail = tail;
            final escalation = stallEscalationFor(stallRun);
            // Warn the model once the stall is old enough — injected
            // verbatim into the user turn so a cheap model cannot
            // miss it.
            final stallNotice = stallRun >= kMonitorStallWarnChecks
                ? stallNoticeFor(stallRun)
                : null;

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
                stallNotice: stallNotice,
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
              refreshStderrSnapshot();
              noticeSink?.call(
                ShellMonitorNotice(
                  configured: true,
                  command: _trimmedDisplayCommand(command),
                  intent: intent,
                  kind: 'EVAL_ERROR',
                  reason: '$e',
                  elapsedSeconds: elapsedSecs(),
                  newOutputBytes: newBytes,
                  totalOutputBytes: totalOutputBytes,
                  tail: cappedTail(stdoutBuf.toString()),
                ),
              );
              monitorFallbackTimer ??= Timer(timeout, () {
                if (!monitorKill.isCompleted) {
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
                  monitorKill.complete(
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
            refreshStderrSnapshot();
            noticeSink?.call(
              ShellMonitorNotice(
                configured: true,
                command: _trimmedDisplayCommand(command),
                intent: intent,
                kind: switch (verdict.kind) {
                  ShellMonitorVerdictKind.progress => 'PROGRESS',
                  ShellMonitorVerdictKind.stuck => 'STUCK',
                  ShellMonitorVerdictKind.uncertain => 'UNCERTAIN',
                },
                reason: verdict.reason,
                elapsedSeconds: elapsedSecs(),
                nextCheckSeconds: verdict.kind == ShellMonitorVerdictKind.stuck
                    ? null
                    : verdict.intervalSeconds,
                newOutputBytes: newBytes,
                totalOutputBytes: totalOutputBytes,
                tail: cappedTail(stdoutBuf.toString()),
              ),
            );

            previousCheckTime = now;
            previousTotalBytes = totalOutputBytes;

            // ── Zero-progress escalation ────────────────────────
            // After kMonitorStallKillChecks consecutive fully-stalled
            // checks, override whatever the model answered (it has
            // already seen stallRun WARNINGs) and kill. The override
            // is logged + toasted as STUCK with the escalation
            // reason, so /d-monitor and the user both see exactly
            // why.
            if (escalation == StallEscalation.escalate &&
                verdict.kind != ShellMonitorVerdictKind.stuck) {
              final reason =
                  'zero-progress escalation: '
                  '$kMonitorStallKillChecks consecutive checks with 0B '
                  'new output and an unchanged tail (last model verdict: '
                  'PROGRESS/UNCERTAIN) — killing the process group';
              // Append the override as an assistant turn so the
              // conversation stays consistent if further checks were
              // to happen (they won't — we return below).
              monitorMessages.add({
                'role': 'assistant',
                'content': 'STUCK — $reason',
              });
              monitorLogSink?.log(
                ShellMonitorEvent(
                  checkNumber: checkNumber,
                  elapsedSeconds: elapsedSecs(),
                  newOutputBytes: newBytes,
                  totalOutputBytes: totalOutputBytes,
                  verdict: 'STUCK',
                  reason: reason,
                  outputTail: cappedTail(stdoutBuf.toString()),
                ),
              );
              refreshStderrSnapshot();
              noticeSink?.call(
                ShellMonitorNotice(
                  configured: true,
                  command: _trimmedDisplayCommand(command),
                  intent: intent,
                  kind: 'STUCK',
                  reason: reason,
                  elapsedSeconds: elapsedSecs(),
                  newOutputBytes: newBytes,
                  totalOutputBytes: totalOutputBytes,
                  tail: cappedTail(stdoutBuf.toString()),
                ),
              );
              if (!monitorKill.isCompleted) {
                monitorKill.complete(reason);
              }
              return;
            }

            if (verdict.kind == ShellMonitorVerdictKind.stuck) {
              if (!monitorKill.isCompleted) {
                monitorKill.complete(
                  verdict.reason ?? 'monitor judged the process stuck',
                );
              }
              return;
            }
            // While the process is fully stalled, don't trust the
            // model's interval pricing (a long "steady phase" quote is
            // exactly the failure mode) — force short re-checks. The
            // stall counter resets on any progress, restoring the
            // model's cadence.
            nextDelay = Duration(
              seconds: fullyStalled
                  ? kMonitorStallCheckIntervalSeconds
                  : verdict.intervalSeconds,
            );
          }
        }

        unawaited(monitorLoop());
      }

      int exitCode;
      int? finishExitCode; // mirrors exitCode for the FINISH event; null = killed pre-exit
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
        liveFinishExitCode = exitCode;
        // Always wait for output streams to finish, with a timeout.
        try {
          await Future.wait([stdoutFuture, stderrFuture])
              .timeout(const Duration(seconds: 2));
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
      // Unregister from the registry on any exit (normal, error, or
      // abort). The monitor-toast mirror forgets it too, so the
      // standing toast's kill button can no longer fire on a dead
      // process.
      if (process != null && sessionId != null) {
        ShellProcessRegistry.instance.unregister(sessionId, process);
        ShellMonitorRegistry.instance.remove(sessionId, process);
      }
      // Live view teardown: mark the per-call entry finished so the
      // tools-box row and an open fullpane flip to their final state.
      // Null exit = killed before an exit code could be read. The
      // entry lingers for the registry's TTL, then prunes.
      if (sessionId != null && callId.isNotEmpty) {
        try {
          liveRegistry.finish(sessionId, callId, exitCode: liveFinishExitCode);
        } catch (_) {}
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
    // ── Plan-mode shell guard ─────────────────────────────────────
    // Best-effort, documented as heuristic (not a sandbox): while plan
    // mode is active, mutating shell commands that target non-plan
    // files are rejected outright. Runs BEFORE the fallback guard so a
    // plan-mode block doesn't consume the drift streak.
    final planDocPath = runtime?.planDocPath;
    final planApproved = runtime?.planApproved ?? false;
    if (planDocPath != null && !planApproved && !_shellGuardDisabled()) {
      final planViolation = detectPlanModeShellViolation(
        command,
        planDocPath: planDocPath,
        workingDirectory: ctx.workingDirectory,
        isWindows: Platform.isWindows,
      );
      if (planViolation != null) {
        return ToolResult(
          title: 'Error',
          output: planViolation,
          metadata: {'shellGuard': true, 'shellGuardKind': 'planMode'},
        );
      }
    }

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
        noticeSink: ctx.shellMonitorNoticeSink,
        intent: intent,
        platform: Platform.operatingSystem,
        shellExecutable: invocation.executable,
        callId: ctx.callId ?? '',
      );

      final combined = StringBuffer();
      final stderr = result.stderr as String;
      final stdout = result.stdout as String;
      if (stderr.isNotEmpty) {
        combined.writeln(stderr);
      }
      combined.write(stdout);

      final rawOutput = combined.toString();
      final cappedOutput = _capShellOutput(rawOutput);
      var output = cappedOutput.output;
      String? outputPath;
      final truncated = cappedOutput.truncated;
      if (truncated) {
        final tmpFile = File(
          '${Directory.systemTemp.path}/crux_${name}_output_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        await tmpFile.writeAsString(rawOutput);
        outputPath = tmpFile.path;
      }

      final exitCode = result.exitCode;

      final tail = StringBuffer();
      if (truncated) {
        tail.writeln(
          '\n[output truncated from ${cappedOutput.originalChars} chars '
          'to at most $_maxOutputChars chars / $_maxOutputTokens estimated '
          'tokens / $_maxLines lines; '
          'full output: $outputPath]',
        );
      }
      if (exitCode != 0) {
        tail.write('\n[exit code: $exitCode]');
      }

      var finalOutput = output + tail.toString();

      // Human-in-the-loop: the user may have killed this process via
      // the monitor toast's kill button. If so, annotate the result
      // so the AGENT knows the shell didn't finish normally and can
      // continue from the partial output instead of retrying the
      // whole command. Take-and-clear: the note is consumed exactly
      // once. The registry keys by the spawned Process's OS pid,
      // which `ProcessResult.pid` carries — no object identity needed
      // across the `_run` boundary.
      final killNote = ShellMonitorRegistry.instance.takeKillNote(result.pid);
      if (killNote != null) {
        finalOutput = '$finalOutput\n[$killNote]';
      }

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
          'originalOutputChars': cappedOutput.originalChars,
          'returnedOutputChars': output.length,
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

  /// Friendly display form of a command for the toast channel: trim
  /// absolute bundled-executable prefix paths (they leak noise into
  /// a one-row toast) and cap to one line. Mirrors the formatter in
  /// `/d-monitor`'s renderer.
  static String _trimmedDisplayCommand(String command) {
    var c = command.trim();
    final i = c.indexOf(' Crux_');
    if (i != -1) c = c.substring(i + 1);
    final j = c.indexOf(' crux_');
    if (j != -1) c = c.substring(j + 1);
    final k = c.indexOf('/crux/');
    if (k != -1) c = c.substring(k + '/crux/'.length);
    final lines = c.split('\n');
    if (lines.length > 1) c = '${lines.first.trim()} …';
    if (c.length > 80) c = '${c.substring(0, 80)}…';
    return c;
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
        'description': 'What this command accomplishes / why you are running it. Be concise.',
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

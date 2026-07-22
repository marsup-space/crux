/// Shared type contract for the shell progress monitor.
///
/// When an auxiliary model is configured, the shell tools (bash /
/// cmd / powershell) do NOT enforce the static `timeout` parameter.
/// Instead a monitor loop inside `shell_base.dart` snapshots the
/// running process at model-scheduled intervals and asks the
/// auxiliary model, via a single continuing conversation, whether
/// the process is making progress. The model sees the command, the
/// stated intent, static metadata (platform, shell), and a per-turn
/// block of dynamic metadata (elapsed time, bytes of new output, an
/// output tail), and replies with one word:
///
///   * `PROGRESS [seconds]` — the process is healthy; look again in
///     `seconds` (model-chosen, clamped by the caller).
///   * `STUCK [seconds]` — the process will not finish on its own
///     (deadlock, waiting on stdin it will never get, fatal error
///     without exit, unrecoverable retry loop). The caller kills the
///     process group. `seconds` is meaningless here and ignored.
///   * `UNCERTAIN [seconds]` — cannot tell. Fail-open: the process
///     keeps running, checked again in `seconds`.
///
/// Fail-open asymmetry vs the pre-execution risk guard
/// (`shell_risk.dart`): that guard is fail-CLOSED (uncertain → do
/// not run, nothing lost yet) because the command hasn't started.
/// The monitor is fail-OPEN (uncertain → keep running) because the
/// process HAS started and a false kill discards real work (a
/// half-written build tree, a partial download). Only an explicit
/// STUCK kills.
///
/// Timeout semantics (see `ShellBase._run`): with the monitor
/// active, the static timeout is not armed at all — a hard kill at
/// a guessed wall-clock deadline is exactly what the monitor
/// replaces (the classic case: a compile the caller guessed would
/// take 5 minutes actually needs 7; the timeout would force a
/// restart, the monitor watches it finish). The static timeout
/// survives only as a *monitor-failure fallback*: if the auxiliary
/// model itself times out or errors, the caller arms the timeout
/// from that moment so a permanently-dead reviewer degrades the
/// run to classic timeout behaviour instead of running forever.
library;

import 'tool_def.dart' show AbortSignal;

/// The monitor's judgement for one check.
enum ShellMonitorVerdictKind {
  /// Process is healthy; check again after [ShellMonitorVerdict.intervalSeconds].
  progress,

  /// Process will not finish on its own; the caller kills it.
  stuck,

  /// Cannot tell; fail-open (keep running), check again after
  /// [ShellMonitorVerdict.intervalSeconds].
  uncertain,
}

/// Parsed verdict from the auxiliary model.
class ShellMonitorVerdict {
  final ShellMonitorVerdictKind kind;

  /// Seconds until the next check, as the model requested (already
  /// clamped to [kMonitorMinIntervalSeconds]–[kMonitorMaxIntervalSeconds]
  /// by the parser). Ignored when [kind] is
  /// [ShellMonitorVerdictKind.stuck].
  final int intervalSeconds;

  /// Optional free-text reason the model appended after the verdict
  /// token. Surfaced to the user on a STUCK kill.
  final String? reason;

  const ShellMonitorVerdict(
    this.kind, {
    this.intervalSeconds = kMonitorDefaultIntervalSeconds,
    this.reason,
  });
}

/// Hard bounds for the model-chosen next-check interval. The model
/// is asked to price the interval from evidence (a linking step
/// deserves 10s, a 1500-crate compile deserves 60–120s), but it can
/// be wrong in both directions: too small burns tokens on a cheap
/// model every few seconds, too large defeats the purpose of
/// monitoring. Clamped here, centrally, so the parser and the loop
/// agree.
const int kMonitorMinIntervalSeconds = 5;
const int kMonitorMaxIntervalSeconds = 600;

/// Fallback when the model omits the interval or emits an
/// unparseable one. 30s matches the "uniform periodic check"
/// cadence this design replaced.
const int kMonitorDefaultIntervalSeconds = 30;

/// How long after process start the FIRST check fires. Short
/// commands (the common case: `ls`, `git status`, `echo`) finish
/// before this and never touch the monitor at all — the monitor
/// only pays for itself on genuinely long-running work.
const int kMonitorFirstCheckSeconds = 20;

/// A point-in-time snapshot of the running process, taken by the
/// monitor loop just before asking the auxiliary model. Pure data;
/// the loop fills it, [buildShellMonitorUserMessage] renders it.
class ShellMonitorSnapshot {
  /// 1-based ordinal of this check (first check is 1).
  final int checkNumber;

  /// Wall-clock time since the process was spawned.
  final Duration elapsed;

  /// Wall-clock time since the previous check. Null on the first
  /// check (rendered as `—`).
  final Duration? sincePreviousCheck;

  /// Bytes of stdout+stderr produced since the previous check. The
  /// cheap liveness signal: growing means the process is almost
  /// certainly alive, so the model can answer PROGRESS cheaply.
  final int newOutputBytes;

  /// Total bytes of stdout+stderr since spawn.
  final int totalOutputBytes;

  /// The last ~1KB of combined output — the actual evidence. A
  /// `Password:` prompt, a `[y/n]` blocker, a retry loop, or a
  /// fatal error that didn't kill the process all live here.
  final String outputTail;

  const ShellMonitorSnapshot({
    required this.checkNumber,
    required this.elapsed,
    required this.sincePreviousCheck,
    required this.newOutputBytes,
    required this.totalOutputBytes,
    required this.outputTail,
  });
}

/// Render the user turn the auxiliary model sees for one monitor
/// check. The first check carries the STATIC metadata block
/// (command, intent, platform, shell) that never changes mid-run —
/// repeating it every turn would waste tokens and break the byte-
/// identical prefix the continuing conversation relies on for KV
/// cache reuse. Subsequent turns carry only the per-turn dynamic
/// block.
///
/// `elapsed` and `sincePreviousCheck` are passed on EVERY turn, on
/// purpose: in a continuing conversation the model would otherwise
/// have to reconstruct absolute time by summing its own requested
/// intervals, which is error-prone (timers and check latency make
/// requested ≠ actual). Explicit ground truth keeps the quiet-
/// duration reasoning unambiguous.
String buildShellMonitorUserMessage({
  required ShellMonitorSnapshot snapshot,
  String? command,
  String? intent,
  String? platform,
  String? shell,
}) {
  final buf = StringBuffer();
  final isFirst = snapshot.checkNumber == 1;
  if (isFirst) {
    buf.writeln('Command: ${command ?? ""}');
    buf.writeln('Intent: ${intent ?? ""}');
    buf.writeln(
      'Platform: ${platform ?? "unknown"} (shell: ${shell ?? "unknown"})',
    );
    buf.writeln();
  }
  buf.writeln('[check #${snapshot.checkNumber}]');
  buf.writeln('elapsed: ${_formatDuration(snapshot.elapsed)}');
  buf.writeln(
    'since_previous_check: '
    '${snapshot.sincePreviousCheck == null ? "—" : _formatDuration(snapshot.sincePreviousCheck!)}',
  );
  buf.writeln(
    'output_since_previous_check: '
    '${_formatBytes(snapshot.newOutputBytes)} (total: ${_formatBytes(snapshot.totalOutputBytes)})',
  );
  buf.writeln('output_tail:');
  buf.write(
    snapshot.outputTail.isEmpty ? '(no output yet)' : snapshot.outputTail,
  );
  return buf.toString();
}

/// Render a compact `1m 5s` / `20s` duration for the per-turn
/// metadata block. Seconds-only for short runs, minutes+seconds
/// once a run crosses a minute, hours+minutes for very long runs
/// (seconds stop mattering to the verdict there).
String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = d.inMinutes;
  final seconds = totalSeconds % 60;
  if (minutes < 60) return '${minutes}m ${seconds}s';
  final hours = d.inHours;
  final remMinutes = minutes % 60;
  return '${hours}h ${remMinutes}m';
}

/// Compact byte formatting for the metadata block.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// The signature `ToolContext.shellMonitorEvaluator` and
/// `ShellBase` use for one monitor check. The evaluator owns the
/// whole continuing-conversation turn: the caller passes the FULL
/// message list (system prompt + static first turn + the running
/// history of prior user snapshots and assistant verdicts), the
/// evaluator appends the new user turn, streams the auxiliary
/// model's reply, and returns the parsed verdict. Keeping the
/// message list in the caller (not the service) lets the monitor
/// loop in `shell_base.dart` own conversation state across checks
/// without the service holding per-process state.
///
/// [messages] is the conversation so far, in the wire format
/// `_streamAuxiliaryCall` already accepts (role/content maps).
/// [abort] lets the evaluator cancel the underlying HTTP stream if
/// the user interrupts mid-check.
typedef ShellMonitorEvaluator =
    Future<ShellMonitorVerdict> Function(
      List<Map<String, dynamic>> messages, {
      required AbortSignal abort,
    });

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
/// deserves 15s, a 1500-crate compile deserves 60–120s), but it can
/// be wrong in both directions: too small burns tokens on a cheap
/// model every few seconds, too large defeats the purpose of
/// monitoring. Clamped here, centrally, so the parser and the loop
/// agree.
const int kMonitorMinIntervalSeconds = 15;
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

/// Hard cap on the persisted output tail. The snapshot itself sends
/// ~1KB of tail to the model; the log keeps a slightly larger 2KB
/// window so a post-mortem can see a bit more context (e.g. the
/// start of a `Password:` prompt that straddles the 1KB boundary)
/// without letting a chatty process grow the DB row unboundedly.
const int kMonitorLogTailMaxChars = 2048;

// ── Zero-progress escalation ("option B") ─────────────────────────
// The monitor is fail-open by design, which lets a fully-silent
// process run for tens of minutes: each check sees 0B new output and
// a byte-identical tail, yet the model keeps answering PROGRESS /
// UNCERTAIN (never guess STUCK). These constants bound that failure
// mode from the LOOP side: after enough consecutive fully-stalled
// checks the user turn carries an explicit WARNING, the check
// interval is forced short (the model's long "steady phase" pricing
// is exactly what we no longer trust during a stall), and after
// [kMonitorStallKillChecks] stalled checks the loop escalates to
// STUCK itself, overriding the model's verdict.
//
// "Fully stalled" = 0B new output since the previous check AND a
// byte-identical output tail — silence, not slow progress. A healthy
// compile that prints per-crate lines resets the counter on every
// check.

/// Consecutive fully-stalled checks before the user turn carries the
/// stall WARNING (telling the model a STUCK answer is appropriate).
///
/// Mutable (not `const`) so tests can tighten the thresholds and run
/// the escalation in seconds; production code must treat these as
/// effectively-final. Same test-tunability precedent as
/// `ChatTurnExecutor.debugRetryBudgetOverride`.
int kMonitorStallWarnChecks = 3;

/// Consecutive fully-stalled checks after which the loop escalates
/// to STUCK itself, overriding a PROGRESS/UNCERTAIN verdict. With
/// the forced stall interval below this tolerates roughly
/// `(kMonitorStallKillChecks - 1) × kMonitorStallCheckIntervalSeconds`
/// (~2m20s at the defaults) of continuous silence before killing.
///
/// Mutable for tests — see [kMonitorStallWarnChecks].
int kMonitorStallKillChecks = 8;

/// Interval forced between checks while the process is fully
/// stalled, overriding the model's chosen interval.
///
/// Mutable for tests — see [kMonitorStallWarnChecks].
int kMonitorStallCheckIntervalSeconds = 20;

/// The zero-progress escalation decision for a check whose stall run
/// is [stallRun] consecutive fully-stalled checks (0 when the check
/// saw progress). Pure so tests can exercise thresholds without
/// waiting out real timers; the loop in `shell_base.dart` maps the
/// verdict onto warning injection, forced intervals, and the
/// override-to-STUCK escalation.
enum StallEscalation {
  /// Normal check — no stall handling.
  none,

  /// Stalled long enough to warn the model in the next user turn and
  /// force a short check interval.
  warn,

  /// Override the model's verdict with STUCK and kill.
  escalate,
}

StallEscalation stallEscalationFor(int stallRun) {
  if (stallRun >= kMonitorStallKillChecks) return StallEscalation.escalate;
  if (stallRun >= kMonitorStallWarnChecks) return StallEscalation.warn;
  return StallEscalation.none;
}

/// The English WARNING injected into the monitor conversation's user
/// turn once the stall reaches the warn threshold. Wire-format text
/// (the aux model's input), not UI chrome — deliberately direct so a
/// cheap model cannot miss it.
String stallNoticeFor(int stallRun) =>
    'WARNING: $stallRun consecutive checks show 0B new output and an '
    'unchanged output tail. If this quiet phase is not plausible for '
    'the command given its elapsed time and platform, answer STUCK — '
    'continuing checks add no information.';

/// One monitor event, emitted by the monitor loop and consumed by
/// the [ShellMonitorLogSink] wired into the shell tools. Pure data —
/// the sink owns persistence and batching.
class ShellMonitorEvent {
  /// 1-based check ordinal. `0` is the run-start event (emitted when
  /// the monitor arms, before any check has fired).
  final int checkNumber;

  /// Wall-clock seconds since the process was spawned.
  final int elapsedSeconds;

  /// Bytes of stdout+stderr produced since the previous check. Null
  /// on the run-start event.
  final int? newOutputBytes;

  /// Total bytes of stdout+stderr so far. Null on the run-start event.
  final int? totalOutputBytes;

  /// The verdict word as the model emitted it (`PROGRESS` / `STUCK` /
  /// `UNCERTAIN`). Null on events that have no verdict: run-start,
  /// evaluator-threw (logged as `EVAL_ERROR`), monitor-unavailable
  /// timeout fallback (logged as `FALLBACK`), and run-finish (logged
  /// as `FINISH`).
  final String? verdict;

  /// Model-chosen next-check interval in seconds. Null when the
  /// event carries no interval.
  final int? intervalSeconds;

  /// Free-text detail: the model's reason on verdicts, the exception
  /// text on `EVAL_ERROR`, the fallback note on `FALLBACK`, the exit
  /// code on `FINISH`.
  final String? reason;

  /// Output tail captured at this event (already capped to
  /// [kMonitorLogTailMaxChars]). Null on run-start and run-finish.
  final String? outputTail;

  const ShellMonitorEvent({
    required this.checkNumber,
    required this.elapsedSeconds,
    this.newOutputBytes,
    this.totalOutputBytes,
    this.verdict,
    this.intervalSeconds,
    this.reason,
    this.outputTail,
  });
}

/// Human-readable announcement / per-check report published to the
/// toast channel (see `shell_monitor_notifier.dart`). Pure data: the
/// tool layer fills it from evidence it already holds; the chat panel
/// formats the user-visible copy via `Strings`. No display strings
/// live here — the toast must localize, so all wording happens at the
/// wiring site (the panel).
class ShellMonitorNotice {
  /// True when the run is supervised by the auxiliary-model monitor.
  /// False means no aux model is configured and the run competes with
  /// the classic static timeout instead.
  final bool configured;

  /// The command in display form (bundled-executable prefix paths
  /// already trimmed by the loop). Secondary subject on the toast —
  /// shown only when [intent] is empty.
  final String command;

  /// What the LLM said this command is for (the shell tool's `intent`
  /// argument). PRIMARY subject on the toast: a human phrase like
  /// "install dependencies" beats `/usr/bin/dart pub get`.
  final String intent;

  /// Machine-readable event kind:
  ///
  ///   * `CONFIGURED` — run-start announcement
  ///   * `PROGRESS` / `STUCK` / `UNCERTAIN` — the aux model's verdict
  ///   * `EVAL_ERROR` — the evaluator threw; fail-open (keeps running)
  ///   * `FALLBACK` — the monitor died; static timeout armed
  final String kind;

  /// Free-text detail: the model's reason on a verdict, the exception
  /// text on `EVAL_ERROR`, the fallback note on `FALLBACK`. Raw
  /// evidence — the panel appends it to the detail row as-is.
  final String? reason;

  /// Wall-clock seconds since the process spawned. 0 on the
  /// run-start announcement.
  final int elapsedSeconds;

  /// Seconds until the next check (the model's own choice, clamped;
  /// `kMonitorFirstCheckSeconds` on the arm announcement). Null when
  /// not applicable (STUCK, FALLBACK).
  final int? nextCheckSeconds;

  /// Bytes of stdout+stderr produced since the previous check. Null
  /// on the run-start announcement.
  final int? newOutputBytes;

  /// Total bytes of stdout+stderr so far. Null on the run-start
  /// announcement.
  final int? totalOutputBytes;

  /// The last meaningful line of the output tail — evidence backing
  /// the verdict. Null when the process has printed nothing (yet).
  final String? tail;

  const ShellMonitorNotice({
    required this.configured,
    required this.command,
    this.intent = '',
    required this.kind,
    this.reason,
    this.elapsedSeconds = 0,
    this.nextCheckSeconds,
    this.newOutputBytes,
    this.totalOutputBytes,
    this.tail,
  });

  /// The toast meaningfulness gate: the run-start announcement for an
  /// unconfigured run carries zero novelty (the bubble progress box
  /// already shows a plain long-running command) — skip it to avoid
  /// toast spam. Everything else — armed, per-check verdicts, errors,
  /// fallbacks — is exactly the transparency the toast channel
  /// exists for.
  bool get isMeaningful => configured || kind != 'CONFIGURED';
}

/// Cap for the toast's evidence line: one trimmed output line, so
/// long meters collapse to their tail.
const int kMonitorNoticeTailMaxChars = 80;

/// Pick the last non-blank line of a monitor output tail and clamp it
/// to [kMonitorNoticeTailMaxChars] (leading with an ellipsis when
/// clamped). Used by the chat panel to build the toast's evidence row.
String mkMonitorTail(String tail) {
  final lines = tail
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';
  var line = lines.last;
  if (line.length > kMonitorNoticeTailMaxChars) {
    line = '…${line.substring(line.length - kMonitorNoticeTailMaxChars)}';
  }
  return line;
}

/// Receives monitor events for one shell run. Wired from the chat
/// executor down to the monitor loop via `ToolContext` / `ShellBase`.
/// Null in tests and in setups without persistence — a null sink
/// disables logging entirely (no-op, zero overhead).
///
/// The monitor loop calls [log] after every event; implementations
/// must NOT throw (the loop is fail-open — a logging failure must
/// never kill the monitored process). The loop also guarantees
/// [log] is only ever called from the monitor's own async context,
/// so implementations that append to an in-memory list and flush on
/// [finish] need no locking.
abstract class ShellMonitorLogSink {
  /// The command being monitored (first event payload), so the sink
  /// can stamp it on every persisted row without the loop repeating
  /// it per event.
  String get command;

  /// The intent string the LLM passed to the shell tool.
  String get intent;

  /// Record one event. Implementations may batch; [finish] is the
  /// flush point.
  void log(ShellMonitorEvent event);

  /// The run is over (process exited, killed, or the monitor loop
  /// was torn down). Flush any batched events. [exitCode] is the
  /// process exit code, or null if the process was killed before an
  /// exit code could be read.
  Future<void> finish({int? exitCode});
}

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
///
/// [stallNotice] carries the zero-progress WARNING once the process
/// has been fully silent for [kMonitorStallWarnChecks] consecutive
/// checks — see "Zero-progress escalation" above.
String buildShellMonitorUserMessage({
  required ShellMonitorSnapshot snapshot,
  String? command,
  String? intent,
  String? platform,
  String? shell,
  String? stallNotice,
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
  if (stallNotice != null) {
    buf.writeln(stallNotice);
  }
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
typedef ShellMonitorEvaluator = Future<ShellMonitorVerdict> Function(
  List<Map<String, dynamic>> messages, {
  required AbortSignal abort,
});

/// Per-call live shell registry: the delivery channel between the
/// shell tools (which spawn and tap the process) and the vibe UI's
/// executing-shell row + live fullpane.
///
/// Sibling of `ShellProgressRegistry` (which carries *parsed progress
/// meters* only when the command's output contains progress signals).
/// This registry carries the RAW evidence for EVERY shell run:
///
///   * command + intent (so the tools box can show "what is running"
///     instead of an opaque `bash x4`),
///   * a rolling output tail (~64KB) updated from the same read-only
///     stream tap the progress parser uses — the buffer never feeds
///     back into the tool result the LLM sees,
///   * the aux-model monitor notices as they fire (the live
///     fullpane's check timeline),
///   * the spawned [Process] reference so the fullpane's kill button
///     can terminate exactly THIS run (not the whole session),
///   * finish state (exit code / killed).
///
/// Lifecycle: `ShellBase._run` registers on process spawn and marks
/// finished in its finally block; `ChatTurnExecutor` archives every
/// monitor notice; the UI polls [entryFor] on its render tick.
/// Finished entries linger for [finishedTtl] so an open fullpane can
/// show the final state, then prune on the next read.
library;

import 'dart:io';

import '../tools/shell_monitor.dart' show ShellMonitorNotice;
import 'shell_monitor_notifier.dart' show ShellMonitorRegistry;

/// Hard cap on the per-call rolling output tail. Matches the monitor
/// log's spirit (a bounded recent window) at a larger size: the
/// fullpane wants enough context to look like a terminal scrollback,
/// not a 1KB verdict sliver.
const int kShellLiveTailMaxChars = 64 * 1024;

/// One live (or recently finished) shell run, keyed by tool-call id.
class ShellLiveEntry {
  final String callId;

  /// The bash command as passed to the tool.
  final String command;

  /// The tool call's `intent` argument — the agent's own phrase for
  /// why this shell is running ("install dependencies"). May be empty.
  final String intent;

  final DateTime startedAt;

  DateTime updatedAt;

  /// Rolling combined stdout+stderr tail, capped to
  /// [kShellLiveTailMaxChars]. Pure display side channel.
  String outputTail = '';

  /// Aux-model monitor notices in firing order (CONFIGURED,
  /// PROGRESS/UNCERTAIN/STUCK per check, EVAL_ERROR, FALLBACK). The
  /// run-finish state is NOT a notice — read [finished] / [exitCode].
  final List<ShellMonitorNotice> monitorNotices = [];

  bool finished = false;

  /// True when the finish came from a kill rather than a normal exit
  /// (no exit code was readable).
  bool killed = false;

  int? exitCode;

  /// The spawned process — the kill handle for this specific run.
  Process? process;

  ShellLiveEntry({
    required this.callId,
    required this.command,
    required this.intent,
  }) : startedAt = DateTime.now(),
       updatedAt = DateTime.now();
}

/// App-level registry of live shell runs, keyed by session id then
/// tool-call id. Single-isolate TUI — no locking needed. Fail-open by
/// contract: callers wrap in try/catch at the wiring sites; a missed
/// update degrades the UI, never the command.
class ShellLiveRegistry {
  ShellLiveRegistry._() : finishedTtl = const Duration(minutes: 5);

  /// App singleton; tests construct their own instances with a tiny
  /// [finishedTtl].
  static final ShellLiveRegistry instance = ShellLiveRegistry._();

  /// How long a finished entry stays readable after [finish]. Long
  /// enough for an open fullpane to show the final state across the
  /// tool-result round trip; bounded so memory stays finite.
  final Duration finishedTtl;

  final Map<int, Map<String, ShellLiveEntry>> _bySession = {};

  ShellLiveRegistry({this.finishedTtl = const Duration(minutes: 5)});

  /// Register a new live entry for [callId]. Called by `ShellBase._run`
  /// right after the process spawns. Re-registration (retry with the
  /// same call id) overwrites — the old run is dead by then.
  ShellLiveEntry register({
    required int sessionId,
    required String callId,
    required String command,
    required String intent,
    Process? process,
  }) {
    final entry = ShellLiveEntry(
      callId: callId,
      command: command,
      intent: intent,
    )..process = process;
    _bySession.putIfAbsent(sessionId, () => {})[callId] = entry;
    return entry;
  }

  /// Append a decoded stdout/stderr chunk to the entry's rolling
  /// tail. Called from the same stream tap the progress parser uses;
  /// never touches the buffered output the LLM sees.
  void appendOutput(int sessionId, String callId, String chunk) {
    final entry = _bySession[sessionId]?[callId];
    if (entry == null || chunk.isEmpty) return;
    var tail = entry.outputTail + chunk;
    if (tail.length > kShellLiveTailMaxChars) {
      tail = tail.substring(tail.length - kShellLiveTailMaxChars);
    }
    entry.outputTail = tail;
    entry.updatedAt = DateTime.now();
  }

  /// Archive one aux-model monitor notice into the entry's timeline.
  /// Called from the chat executor's notice sink, so ALL notice kinds
  /// (CONFIGURED / verdicts / EVAL_ERROR / FALLBACK) land here even
  /// when the toast channel is gated.
  void addNotice(int sessionId, String callId, ShellMonitorNotice notice) {
    final entry = _bySession[sessionId]?[callId];
    if (entry == null) return;
    entry.monitorNotices.add(notice);
    entry.updatedAt = DateTime.now();
  }

  /// Mark the run finished. [exitCode] null means killed before an
  /// exit code could be read (rendered as "killed").
  void finish(int sessionId, String callId, {int? exitCode}) {
    final entry = _bySession[sessionId]?[callId];
    if (entry == null) return;
    entry.finished = true;
    entry.exitCode = exitCode;
    entry.killed = exitCode == null;
    entry.updatedAt = DateTime.now();
  }

  /// The entry for [callId], or null. Prunes stale finished entries
  /// on every read (all sessions), so a session nobody renders never
  /// leaks.
  ShellLiveEntry? entryFor(int sessionId, String callId) {
    _prune(DateTime.now());
    return _bySession[sessionId]?[callId];
  }

  /// Drop every entry for [sessionId] (session switch / teardown).
  void clearSession(int sessionId) {
    _bySession.remove(sessionId);
  }

  /// Kill THIS run's process group — the live fullpane's kill button.
  /// Goes through [ShellMonitorRegistry.killOne] so the kill note is
  /// stamped and the tool result gets the same agent-visible
  /// annotation as a toast kill. Returns false when the run has no
  /// live process (already exited).
  bool kill(
    int sessionId,
    String callId, {
    String reason = 'killed by user from the shell live view',
  }) {
    final entry = _bySession[sessionId]?[callId];
    final process = entry?.process;
    if (entry == null || process == null) return false;
    entry.killed = true;
    entry.updatedAt = DateTime.now();
    return ShellMonitorRegistry.instance.killOne(
      sessionId,
      process,
      reason: reason,
    );
  }

  void _prune(DateTime now) {
    _bySession.removeWhere((sid, perCall) {
      perCall.removeWhere(
        (_, e) => e.finished && now.difference(e.updatedAt) > finishedTtl,
      );
      return perCall.isEmpty;
    });
  }
}

/// Human-in-the-loop delivery for the shell progress monitor: after
/// every auxiliary-model evaluation of a long-running shell process
/// (and once when the monitor arms), the monitor loop in
/// `shell_base.dart` publishes a `ShellMonitorNotice` (defined in
/// `shell_monitor.dart` — pure data). The chat executor forwards each
/// notice to the chat panel, which renders it as a toast: what the
/// shell is doing, what the aux model's verdict is, and when it will
/// check again. The toast carries a kill action so the user can stop
/// the monitored process group early — normally only a STUCK verdict
/// kills.
///
/// Layering: the tool layer knows nothing about toasts (it only calls
/// the `ToolContext.shellMonitorNoticeSink` callback when it is
/// non-null); the toast component knows nothing about the monitor
/// (it renders an already-formatted `MonitorToastData`); the chat
/// panel is the only place that formats notices with `Strings` and
/// binds buttons to `ShellProcessRegistry`. `Strings` must never leak
/// below the components — hence raw structured fields here and
/// formatting at the wiring site.
library;

import 'dart:io';

import '../tools/shell_base.dart' show ShellProcessRegistry;
import '../utils/process_group_kill.dart';

/// Registry of live monitor-supervised shell processes, so the
/// monitor toast's kill button can tell "still running" from "already
/// exited" and terminate the process group on demand.
///
/// Sibling of `ShellProcessRegistry`, which owns kill semantics for
/// interrupts and timeout races but has no liveness query. This
/// registry is pure bookkeeping: entries are added when `_run` arms
/// its monitor, removed in `_run`'s finally block on every exit path,
/// and killing hands back to `ShellProcessRegistry.killAll` so the
/// toast button behaves exactly like a user interrupt (SIGTERM to the
/// whole process group, shared [killProcessGroup] helper). The TUI
/// runs on a single isolate, so no locking is needed.
class ShellMonitorRegistry {
  ShellMonitorRegistry._();

  static final ShellMonitorRegistry instance = ShellMonitorRegistry._();

  /// Stderr tail per live process, maintained by the monitor loop so
  /// the post-kill notification to the main session can include what
  /// the process was last printing. Trimmed to
  /// `kMonitorLogTailMaxChars` by the writer.
  final Map<Process, String> _stderrTails = {};

  /// Per-process kill reasons, set by [killAll] and consumed
  /// (take-and-clear) by the shell base right after `_run` returns.
  /// The consumed note is appended to the tool result so the AGENT —
  /// not just the human — learns the shell was killed from the
  /// monitor toast, and continues from the partial output instead of
  /// retrying the same long command.
  final Map<Process, String> _killNotes = {};

  final Map<int, Set<Process>> _processes = {};

  /// Track [process] as a monitor-supervised process of [sessionId].
  void add(int sessionId, Process process) {
    _processes.putIfAbsent(sessionId, () => {}).add(process);
  }

  /// Refresh the remembered stderr tail for [process].
  void noteStderr(Process process, String tail) {
    if (tail.isEmpty) return;
    _stderrTails[process] = tail;
  }

  /// The remembered stderr tail for [process] (empty when none).
  String stderrTail(Process process) => _stderrTails[process] ?? '';

  /// Whether any monitor-supervised process of [sessionId] is still
  /// running. Drives whether the toast renders a kill button at all.
  bool isRunning(int sessionId) => (_processes[sessionId] ?? const {}).isNotEmpty;

  /// Take (remove) the pending kill note for the process with OS pid
  /// [osPid], if any.
  String? takeKillNote(int osPid) {
    for (final p in _killNotes.keys.toList()) {
      if (p.pid == osPid) return _killNotes.remove(p);
    }
    return null;
  }

  /// Forget [process] (any exit path of the monitored run). The kill
  /// note is deliberately KEPT: the process dies before the shell
  /// base's finally block runs, and the tool body consumes the note
  /// only after `_run` returns — clearing it here would erase the
  /// agent-visible annotation the split second before it's read.
  void remove(int sessionId, Process process) {
    _processes[sessionId]?.remove(process);
    _stderrTails.remove(process);
    if (_processes[sessionId]?.isEmpty ?? false) {
      _processes.remove(sessionId);
    }
  }

  /// Kill every monitor-supervised process of [sessionId], stamping
  /// each victim with [reason] so the shell base can annotate that
  /// tool's result (agent-visible). Uses the same kill path as a user
  /// interrupt. Returns true when something was actually killed —
  /// false means the process already exited.
  bool killAll(
    int sessionId, {
    String reason = 'killed by user via monitor toast',
  }) {
    final victims = _processes[sessionId];
    if (victims == null || victims.isEmpty) return false;
    for (final p in victims) {
      _killNotes[p] = reason;
    }
    ShellProcessRegistry.instance.killAll(sessionId);
    return true;
  }

  /// Kill ONE process group — the live shell fullpane's per-run kill
  /// button (targeting a specific tool call, not the whole session).
  /// Same semantics as [killAll]: stamp the kill note so the tool
  /// result carries the agent-visible annotation, then hand off to
  /// [ShellProcessRegistry] for the actual SIGTERM-to-the-group.
  /// Returns true when the process was still registered (something
  /// was killed), false when it had already exited and been
  /// unregistered.
  bool killOne(
    int sessionId,
    Process process, {
    String reason = 'killed by user from the shell live view',
  }) {
    final victims = _processes[sessionId];
    if (victims == null || !victims.contains(process)) return false;
    _killNotes[process] = reason;
    ShellProcessRegistry.instance.unregister(sessionId, process);
    ShellProcessRegistry.killProcess(process);
    return true;
  }
}

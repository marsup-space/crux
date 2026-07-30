import 'package:drift/drift.dart';

import '../tools/shell_monitor.dart';
import 'database.dart' as db;
import 'shell_monitor_log_store.dart';

/// A [ShellMonitorLogSink] that buffers one run's events in memory
/// and flushes them to `shell_monitor_logs` in a single batch on
/// [finish]. Constructed per shell invocation by the chat executor
/// (see `chat_turn_executor.dart`); the monitor loop in
/// `shell_base.dart` emits events without knowing about persistence.
///
/// Batching matters: a chatty process can produce a check every
/// [kMonitorMinIntervalSeconds] for the whole run, and writing each
/// event separately would interleave with the main session's message
/// writes. One batch on finish is a single DB round-trip.
class ShellMonitorLogSinkImpl implements ShellMonitorLogSink {
  final ShellMonitorLogStore _store;
  final int sessionId;
  final int runId;
  @override
  final String command;
  @override
  final String intent;

  final List<db.ShellMonitorLogsCompanion> _pending = [];

  ShellMonitorLogSinkImpl({
    required this._store,
    required this.sessionId,
    required this.runId,
    required this.command,
    required this.intent,
  });

  @override
  void log(ShellMonitorEvent event) {
    // Cap the tail one more time here — the loop already caps at
    // kMonitorLogTailMaxChars, but a defensive clamp keeps a future
    // caller from growing rows unboundedly.
    final tail = event.outputTail;
    final cappedTail = tail == null
        ? null
        : (tail.length <= kMonitorLogTailMaxChars
              ? tail
              : tail.substring(tail.length - kMonitorLogTailMaxChars));
    _pending.add(
      db.ShellMonitorLogsCompanion(
        sessionId: Value(sessionId),
        runId: Value(runId),
        command: Value(command),
        intent: Value(intent),
        checkNumber: Value(event.checkNumber),
        elapsedSeconds: Value(event.elapsedSeconds),
        newOutputBytes: Value(event.newOutputBytes),
        totalOutputBytes: Value(event.totalOutputBytes),
        verdict: Value(event.verdict),
        intervalSeconds: Value(event.intervalSeconds),
        reason: Value(event.reason),
        outputTail: Value(cappedTail),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Flush the buffered events. Swallows DB errors on purpose: the
  /// monitor is fail-open (a logging failure must never surface as a
  /// tool failure), and the caller (the monitor loop's `finally`)
  /// runs this after the process result is already decided.
  @override
  Future<void> finish({int? exitCode}) async {
    if (_pending.isEmpty) return;
    try {
      await _store.insertRun(List.unmodifiable(_pending));
    } catch (_) {
      // Deliberately silent — see the doc comment. The events are
      // dropped; the run already completed.
    } finally {
      _pending.clear();
    }
  }
}

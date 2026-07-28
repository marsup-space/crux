import 'package:drift/drift.dart';

import 'database.dart' as db;

/// One monitor event as read back from `shell_monitor_logs`. Mirrors
/// the columns; the `/d-monitor` command renders these verbatim.
class ShellMonitorLogEntry {
  final int id;
  final int sessionId;
  final int runId;
  final String command;
  final String intent;
  final int checkNumber;
  final int elapsedSeconds;
  final int? newOutputBytes;
  final int? totalOutputBytes;
  final String? verdict;
  final int? intervalSeconds;
  final String? reason;
  final String? outputTail;
  final DateTime createdAt;

  const ShellMonitorLogEntry({
    required this.id,
    required this.sessionId,
    required this.runId,
    required this.command,
    required this.intent,
    required this.checkNumber,
    required this.elapsedSeconds,
    this.newOutputBytes,
    this.totalOutputBytes,
    this.verdict,
    this.intervalSeconds,
    this.reason,
    this.outputTail,
    required this.createdAt,
  });
}

/// Data-access layer for `shell_monitor_logs`. One instance is shared
/// by the whole app (constructed in `main` / the session controller,
/// same lifetime as [SessionStore]).
///
/// Writes are batch-only: the [ShellMonitorLogSinkImpl] accumulates a
/// run's events in memory and flushes them in one insert on `finish`,
/// so the hot monitor loop never touches the DB mid-check. Reads are
/// `/d-monitor`-only and always bounded (`LIMIT`).
class ShellMonitorLogStore {
  final db.CruxDatabase _db;

  ShellMonitorLogStore(this._db);

  /// Insert one run's worth of events in a single batch. Called by
  /// the sink on run finish; not intended for per-event writes.
  Future<void> insertRun(List<db.ShellMonitorLogsCompanion> rows) async {
    if (rows.isEmpty) return;
    await _db.batch((batch) {
      batch.insertAll(_db.shellMonitorLogs, rows);
    });
  }

  /// Most recent [limit] runs for [sessionId] (or across all sessions
  /// when null), each with its events in chronological order. A "run"
  /// is all rows sharing one `runId` — the run-start event plus every
  /// check plus the finish event. Runs are ordered by their latest
  /// event's `createdAt`, newest first.
  Future<List<List<ShellMonitorLogEntry>>> recentRuns({
    int? sessionId,
    int limit = 5,
  }) async {
    // Find the latest `limit` runIds first (a run can have many
    // events, so grouping in SQL keeps the row count we scan small).
    // `MAX(id)` identifies the newest event of each run; ordering by
    // it gives the most-recently-active runs.
    final latestPerRun = _db.selectOnly(_db.shellMonitorLogs)
      ..addColumns([_db.shellMonitorLogs.runId, _db.shellMonitorLogs.id.max()])
      ..groupBy([_db.shellMonitorLogs.runId])
      ..orderBy([OrderingTerm.desc(_db.shellMonitorLogs.id.max())])
      ..limit(limit);
    if (sessionId != null) {
      latestPerRun.where(_db.shellMonitorLogs.sessionId.equals(sessionId));
    }
    final runRows = await latestPerRun.get();
    if (runRows.isEmpty) return const [];

    // Pull the full event history for those runs in one query.
    final runIds = runRows
        .map((r) => r.read(_db.shellMonitorLogs.runId)!)
        .toList();
    final eventsQuery = _db.select(_db.shellMonitorLogs)
      ..where((t) => t.runId.isIn(runIds))
      ..orderBy([(t) => OrderingTerm.asc(t.id)]);
    if (sessionId != null) {
      eventsQuery.where((t) => t.sessionId.equals(sessionId));
    }
    final eventRows = await eventsQuery.get();

    // Group by runId, preserving the "newest run first" order from
    // the first query.
    final byRun = <int, List<ShellMonitorLogEntry>>{};
    for (final row in eventRows) {
      byRun.putIfAbsent(row.runId, () => []).add(_rowToEntry(row));
    }
    return [
      for (final runId in runIds)
        if (byRun.containsKey(runId)) byRun[runId]!,
    ];
  }

  static ShellMonitorLogEntry _rowToEntry(db.ShellMonitorLog row) {
    return ShellMonitorLogEntry(
      id: row.id,
      sessionId: row.sessionId,
      runId: row.runId,
      command: row.command,
      intent: row.intent,
      checkNumber: row.checkNumber,
      elapsedSeconds: row.elapsedSeconds,
      newOutputBytes: row.newOutputBytes,
      totalOutputBytes: row.totalOutputBytes,
      verdict: row.verdict,
      intervalSeconds: row.intervalSeconds,
      reason: row.reason,
      outputTail: row.outputTail,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}

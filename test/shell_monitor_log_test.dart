// Unit tests for the shell-monitor log pipeline: the in-memory sink
// that batches one run's events, and the store that reads runs back
// grouped by runId for `/d-monitor`.
//
// Runs against an in-memory drift database — no on-disk data dir, no
// aux model, no subprocess. The monitor loop itself is covered by
// shell_monitor_integration_test.dart; here we only assert that
// events logged through the sink land in the DB and come back in
// run-grouped, chronological order.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/session.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/shell_monitor_log_sink.dart';
import 'package:crux/src/storage/shell_monitor_log_store.dart';
import 'package:crux/src/tools/shell_monitor.dart';

void main() {
  late CruxDatabase db;
  late ShellMonitorLogStore store;

  setUp(() {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = ShellMonitorLogStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Insert the minimal `sessions` row the FK on
  /// `shell_monitor_logs.session_id` requires, returning its id.
  Future<int> seedSession() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db
        .into(db.sessions)
        .insert(
          SessionsCompanion.insert(
            status: SessionStatus.idle,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  ShellMonitorLogSinkImpl makeSink({
    required int sessionId,
    required int runId,
    String command = 'sleep 60',
    String intent = 'test the monitor',
  }) => ShellMonitorLogSinkImpl(
    store: store,
    sessionId: sessionId,
    runId: runId,
    command: command,
    intent: intent,
  );

  group('ShellMonitorLogSinkImpl', () {
    test('buffers events and writes them in one batch on finish', () async {
      final sessionId = await seedSession();
      final sink = makeSink(sessionId: sessionId, runId: 1);

      // Nothing is written before finish.
      sink.log(const ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0));
      sink.log(
        const ShellMonitorEvent(
          checkNumber: 1,
          elapsedSeconds: 20,
          newOutputBytes: 512,
          totalOutputBytes: 512,
          verdict: 'PROGRESS',
          intervalSeconds: 30,
          reason: 'compiling',
          outputTail: 'tail chunk',
        ),
      );
      expect(await store.recentRuns(sessionId: sessionId), isEmpty);

      await sink.finish(exitCode: 0);

      final runs = await store.recentRuns(sessionId: sessionId);
      expect(runs, hasLength(1));
      final events = runs.single;
      expect(events, hasLength(2));
      expect(events[0].checkNumber, 0);
      expect(events[0].verdict, isNull);
      expect(events[1].checkNumber, 1);
      expect(events[1].verdict, 'PROGRESS');
      expect(events[1].intervalSeconds, 30);
      expect(events[1].reason, 'compiling');
      expect(events[1].outputTail, 'tail chunk');
      expect(events[1].command, 'sleep 60');
      expect(events[1].intent, 'test the monitor');
    });

    test('caps the output tail at kMonitorLogTailMaxChars', () async {
      final sessionId = await seedSession();
      final sink = makeSink(sessionId: sessionId, runId: 1);
      final hugeTail = 'x' * (kMonitorLogTailMaxChars + 500);

      sink.log(
        ShellMonitorEvent(
          checkNumber: 1,
          elapsedSeconds: 20,
          verdict: 'PROGRESS',
          outputTail: hugeTail,
        ),
      );
      await sink.finish(exitCode: 0);

      final events = (await store.recentRuns(sessionId: sessionId)).single;
      final tail = events.single.outputTail!;
      expect(tail.length, kMonitorLogTailMaxChars);
      // Kept the END of the tail (the most recent output).
      expect(tail, endsWith('x' * 100));
    });

    test('finish with no events writes nothing', () async {
      final sessionId = await seedSession();
      final sink = makeSink(sessionId: sessionId, runId: 1);
      await sink.finish(exitCode: 0);
      expect(await store.recentRuns(sessionId: sessionId), isEmpty);
    });
  });

  group('ShellMonitorLogStore.recentRuns', () {
    test('groups events by runId, newest run first', () async {
      final sessionId = await seedSession();

      // Run 1: two events. Run 2 (newer): one event.
      final sink1 = makeSink(
        sessionId: sessionId,
        runId: 1,
        command: 'build a',
      );
      sink1.log(const ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0));
      sink1.log(
        const ShellMonitorEvent(
          checkNumber: 1,
          elapsedSeconds: 20,
          verdict: 'PROGRESS',
        ),
      );
      await sink1.finish(exitCode: 0);

      final sink2 = makeSink(
        sessionId: sessionId,
        runId: 2,
        command: 'build b',
      );
      sink2.log(const ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0));
      await sink2.finish(exitCode: 0);

      final runs = await store.recentRuns(sessionId: sessionId);
      expect(runs, hasLength(2));
      // Newest run (runId 2) comes first even though it has fewer events.
      expect(runs[0].single.runId, 2);
      expect(runs[0].single.command, 'build b');
      expect(runs[1].length, 2);
      expect(runs[1].first.runId, 1);
      // Events within a run are chronological.
      expect(runs[1].map((e) => e.checkNumber), [0, 1]);
    });

    test('respects the limit and the session filter', () async {
      final sessionA = await seedSession();
      final sessionB = await seedSession();

      for (var runId = 1; runId <= 4; runId++) {
        final sink = makeSink(sessionId: sessionA, runId: runId);
        sink.log(const ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0));
        await sink.finish(exitCode: 0);
      }
      final other = makeSink(sessionId: sessionB, runId: 99);
      other.log(const ShellMonitorEvent(checkNumber: 0, elapsedSeconds: 0));
      await other.finish(exitCode: 0);

      // Limit 2 → only the two newest runs of session A.
      final limited = await store.recentRuns(sessionId: sessionA, limit: 2);
      expect(limited, hasLength(2));
      expect(limited.map((r) => r.single.runId), [4, 3]);

      // Session filter: session B sees only its own run.
      final onlyB = await store.recentRuns(sessionId: sessionB);
      expect(onlyB, hasLength(1));
      expect(onlyB.single.single.runId, 99);

      // No filter → both sessions' runs, newest first.
      final all = await store.recentRuns();
      expect(all.length, greaterThanOrEqualTo(5));
    });

    test('returns an empty list when no runs exist', () async {
      expect(await store.recentRuns(sessionId: 12345), isEmpty);
    });
  });
}

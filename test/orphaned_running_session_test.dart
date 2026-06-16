// Tests for [SessionStore.markOrphanedRunningSessionsAsInterrupted]:
// when Crux is launched after being killed mid-stream, any sessions
// that were left in `running` must be transitioned to `interrupted`
// so the UI doesn't pretend they're still streaming.
//
// These tests use an in-memory [CruxDatabase] so they're isolated
// from the user's on-disk data dir (which is shared with other test
// files and would race on parallel runs).

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/session.dart';
import 'package:crux/src/storage/storage.dart';

void main() {
  late CruxDatabase db;
  late SessionStore store;

  setUp(() async {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SessionStore.markOrphanedRunningSessionsAsInterrupted', () {
    test('transitions a running session to interrupted', () async {
      final running = await store.create(model: 'test/test');
      await store.update(running.id, status: SessionStatus.running);

      final count =
          await store.markOrphanedRunningSessionsAsInterrupted();

      expect(count, 1);
      final reloaded = await store.getById(running.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.status, SessionStatus.interrupted);
    });

    test('returns 0 when no session is running', () async {
      await store.create(model: 'test/test'); // defaults to idle
      await store.create(model: 'test/test'); // defaults to idle

      final count =
          await store.markOrphanedRunningSessionsAsInterrupted();

      expect(count, 0);
    });

    test('leaves idle / done / interrupted / needUserAction untouched',
        () async {
      final idle = await store.create(model: 'test/test');
      final done = await store.create(model: 'test/test');
      await store.update(done.id, status: SessionStatus.done);
      final interrupted = await store.create(model: 'test/test');
      await store.update(interrupted.id, status: SessionStatus.interrupted);
      final needUser = await store.create(model: 'test/test');
      await store.update(needUser.id, status: SessionStatus.needUserAction);

      final count =
          await store.markOrphanedRunningSessionsAsInterrupted();

      expect(count, 0);
      expect((await store.getById(idle.id))!.status, SessionStatus.idle);
      expect((await store.getById(done.id))!.status, SessionStatus.done);
      expect(
        (await store.getById(interrupted.id))!.status,
        SessionStatus.interrupted,
      );
      expect(
        (await store.getById(needUser.id))!.status,
        SessionStatus.needUserAction,
      );
    });

    test('transitions only the running rows in a mixed batch', () async {
      final idle = await store.create(model: 'test/test');
      final a = await store.create(model: 'test/test');
      await store.update(a.id, status: SessionStatus.running);
      final b = await store.create(model: 'test/test');
      await store.update(b.id, status: SessionStatus.running);
      final done = await store.create(model: 'test/test');
      await store.update(done.id, status: SessionStatus.done);

      final count =
          await store.markOrphanedRunningSessionsAsInterrupted();

      expect(count, 2);
      expect((await store.getById(idle.id))!.status, SessionStatus.idle);
      expect((await store.getById(a.id))!.status, SessionStatus.interrupted);
      expect((await store.getById(b.id))!.status, SessionStatus.interrupted);
      expect((await store.getById(done.id))!.status, SessionStatus.done);
    });

    test('bumps updated_at on the rows it transitions', () async {
      final running = await store.create(model: 'test/test');
      // Set the status to `running` so the WHERE clause matches.
      await store.update(running.id, status: SessionStatus.running);
      // Roll updated_at into the past so we can observe a bump.
      final past = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      await db.customStatement(
        'UPDATE sessions SET updated_at = ? WHERE id = ?',
        [past, running.id],
      );
      final beforeUpdatedAt =
          (await store.getById(running.id))!.updatedAt;

      await store.markOrphanedRunningSessionsAsInterrupted();

      final afterUpdatedAt =
          (await store.getById(running.id))!.updatedAt;
      expect(afterUpdatedAt.isAfter(beforeUpdatedAt), isTrue);
    });

    test('is idempotent — running a second time is a no-op', () async {
      final running = await store.create(model: 'test/test');
      await store.update(running.id, status: SessionStatus.running);

      final firstCount =
          await store.markOrphanedRunningSessionsAsInterrupted();
      final secondCount =
          await store.markOrphanedRunningSessionsAsInterrupted();

      expect(firstCount, 1);
      expect(secondCount, 0);
      expect(
        (await store.getById(running.id))!.status,
        SessionStatus.interrupted,
      );
    });
  });
}
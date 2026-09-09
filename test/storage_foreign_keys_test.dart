// Tests for the storage-layer foreign-key / transaction hardening:
//
//   - `PRAGMA foreign_keys=ON` in the connection setup hook makes the
//     `onDelete: KeyAction.cascade` FKs declared in tables.dart real
//     (SQLite keeps FK enforcement per-connection; without the pragma
//     the cascades are parsed but never fire).
//   - `SessionStore.deleteSession` / `deleteByProjectPath` run their
//     multi-step deletes in one transaction and also reap
//     `file_last_writer` rows (which previously orphaned forever).
//   - `MessageStore.deleteCompleteCompactions` is transactional.
//   - `MessageStore.repairOrphanToolRows` skips `tool_call` rows whose
//     toolCalls JSON is corrupt instead of treating them as empty
//     flow terminators.
//
// The atomicity tests inject a mid-transaction failure with a
// sabotaging QueryExecutor wrapper and assert the earlier deletes
// were rolled back.

import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/part.dart';
import 'package:crux/src/storage/database.dart' as dbdef;
import 'package:crux/src/storage/storage.dart';
import 'package:drift/drift.dart'
    show
        BatchedStatements,
        QueryExecutor,
        QueryExecutorUser,
        SqlDialect,
        TransactionExecutor,
        Value,
        Variable;
import 'package:drift/native.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────

/// In-memory database whose connection has FK enforcement on, matching
/// the production connection setup in database.dart.
CruxDatabase _fkDatabase() {
  return CruxDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys=ON;');
      },
    ),
  );
}

/// In-memory database without the pragma — the state every executor
/// was in before the fix.
CruxDatabase _plainDatabase() {
  return CruxDatabase.forTesting(NativeDatabase.memory());
}

/// Seed one session with a full dependent-row graph: a message, a
/// part attached to that message, a file_read_state row, and a
/// file_last_writer attribution row.
Future<({int sessionId, int messageId})> _seedSessionGraph(
  SessionStore store, {
  String projectPath = '/proj',
  String filePath = '/proj/file.dart',
}) async {
  final session = await store.create(
    title: 'fk-test',
    model: 'minimax/MiniMax-M3',
    projectPath: projectPath,
  );
  final message = await store.messageStore.addMessage(
    session.id,
    role: 'user',
    content: 'hi',
  );
  await store.messageStore.addParts(session.id, message.id, [
    const PartData(type: PartType.text, data: {'text': 'hello'}),
  ]);
  await store.saveFileReadState(session.id, filePath, 111);
  await store.saveLastWriter(session.id, filePath, 111, 'edit file');
  return (sessionId: session.id, messageId: message.id);
}

Future<int> _count(CruxDatabase db, String sql, List<Object?> args) async {
  final row = await db
      .customSelect(sql, variables: [for (final a in args) Variable(a)])
      .getSingle();
  return row.read<int>('c');
}

Future<int> _childRows(CruxDatabase db, String table, int sessionId) {
  return _count(db, 'SELECT COUNT(*) AS c FROM $table WHERE session_id = ?', [
    sessionId,
  ]);
}

Future<int> _writerRows(CruxDatabase db, int writerSessionId) {
  return _count(
    db,
    'SELECT COUNT(*) AS c FROM file_last_writer WHERE writer_session_id = ?',
    [writerSessionId],
  );
}

Future<int> _sessionRows(CruxDatabase db, int sessionId) {
  return _count(db, 'SELECT COUNT(*) AS c FROM sessions WHERE id = ?', [
    sessionId,
  ]);
}

// ── Sabotaging executor ──────────────────────────────────────────────

/// A [QueryExecutor] wrapper that throws from `runDelete` when the
/// statement contains [_SabotageExecutor.failOn] while armed. Used to
/// fail a late step of a multi-step delete so the test can assert the
/// earlier steps were rolled back.
class _SabotageExecutor implements QueryExecutor {
  final QueryExecutor _inner;
  final String failOn;
  bool armed = false;

  _SabotageExecutor(this._inner, {required this.failOn});

  void _maybeThrow(String statement) {
    if (armed && statement.contains(failOn)) {
      throw StateError('sabotaged delete: $statement');
    }
  }

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) {
    _maybeThrow(statement);
    return _inner.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() =>
      _SabotageTransaction(this, _inner.beginTransaction());

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();
}

class _SabotageTransaction implements TransactionExecutor {
  final _SabotageExecutor _parent;
  final TransactionExecutor _inner;

  _SabotageTransaction(this._parent, this._inner);

  @override
  bool get supportsNestedTransactions => _inner.supportsNestedTransactions;

  @override
  Future<void> send() => _inner.send();

  @override
  Future<void> rollback() => _inner.rollback();

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _inner.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) {
    _parent._maybeThrow(statement);
    return _inner.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();
}

// ── Tests ────────────────────────────────────────────────────────────

void main() {
  group('PRAGMA foreign_keys / declared cascades', () {
    test('connection setup hook enables FK enforcement', () async {
      final db = _fkDatabase();
      addTearDown(db.close);

      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 1);
    });

    test('plain executor keeps SQLite default (enforcement off)', () async {
      // Control test: documents why the pragma had to be added to the
      // production setup — SQLite defaults to OFF per connection.
      final db = _plainDatabase();
      addTearDown(db.close);

      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 0);
    });

    test('enforcement rejects a message for a nonexistent session', () async {
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);

      await expectLater(
        store.messageStore.addMessage(999, role: 'user', content: 'x'),
        throwsA(isA<SqliteException>()),
      );
    });

    test('declared ON DELETE CASCADE fires on a raw session delete', () async {
      // Bypass the store layer and delete the session row directly,
      // the way the FK declarations in tables.dart intend: every
      // dependent table must be cleaned by the cascade itself.
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final g = await _seedSessionGraph(store);

      await db.customUpdate(
        'DELETE FROM sessions WHERE id = ?',
        variables: [Variable.withInt(g.sessionId)],
        updates: {db.sessions},
      );

      expect(await _sessionRows(db, g.sessionId), 0);
      expect(
        await _childRows(db, 'messages', g.sessionId),
        0,
        reason: 'messages.session_id cascades on session delete',
      );
      expect(
        await _childRows(db, 'parts', g.sessionId),
        0,
        reason: 'parts cascades via both message_id and session_id',
      );
      expect(
        await _childRows(db, 'file_read_state', g.sessionId),
        0,
        reason: 'file_read_state.session_id cascades',
      );
      expect(
        await _writerRows(db, g.sessionId),
        0,
        reason: 'file_last_writer.writer_session_id cascades',
      );
    });

    test('deleteMessagesFrom removes attached parts via cascade', () async {
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final g = await _seedSessionGraph(store);

      final deleted = await store.messageStore.deleteMessagesFrom(
        g.sessionId,
        g.messageId,
      );
      expect(deleted, 1);
      expect(
        await _childRows(db, 'parts', g.sessionId),
        0,
        reason: 'parts.message_id cascade must fire with FK on',
      );
    });
  });

  group('SessionStore.deleteSession', () {
    test('removes the full graph including file_last_writer (FK on)', () async {
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final g = await _seedSessionGraph(store);

      await store.deleteSession(g.sessionId);

      expect(await _sessionRows(db, g.sessionId), 0);
      expect(await _childRows(db, 'messages', g.sessionId), 0);
      expect(await _childRows(db, 'parts', g.sessionId), 0);
      expect(await _childRows(db, 'file_read_state', g.sessionId), 0);
      expect(
        await _writerRows(db, g.sessionId),
        0,
        reason: 'attribution rows must not survive their writer',
      );
    });

    test('still removes file_last_writer without the FK pragma', () async {
      // Regression test for the orphan fix: on executors where the
      // cascade never fires (the pre-fix state of every install), the
      // explicit delete must do the cleanup.
      final db = _plainDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final g = await _seedSessionGraph(store);

      await store.deleteSession(g.sessionId);

      expect(await _sessionRows(db, g.sessionId), 0);
      expect(await _childRows(db, 'messages', g.sessionId), 0);
      expect(await _childRows(db, 'parts', g.sessionId), 0);
      expect(await _childRows(db, 'file_read_state', g.sessionId), 0);
      expect(await _writerRows(db, g.sessionId), 0);
    });

    test(
      'is atomic: failure on the final delete rolls back children',
      () async {
        final executor = _SabotageExecutor(
          NativeDatabase.memory(),
          failOn: 'DELETE FROM "sessions"',
        );
        final db = CruxDatabase.forTesting(executor);
        addTearDown(db.close);
        final store = SessionStore(db);
        final g = await _seedSessionGraph(store);

        executor.armed = true;
        await expectLater(store.deleteSession(g.sessionId), throwsStateError);
        executor.armed = false;

        expect(
          await _sessionRows(db, g.sessionId),
          1,
          reason: 'sessions delete failed — row must remain',
        );
        expect(
          await _childRows(db, 'messages', g.sessionId),
          1,
          reason: 'child deletes must have been rolled back',
        );
        expect(await _childRows(db, 'parts', g.sessionId), 1);
        expect(await _childRows(db, 'file_read_state', g.sessionId), 1);
        expect(await _writerRows(db, g.sessionId), 1);
      },
    );
  });

  group('SessionStore.deleteByProjectPath', () {
    test('removes every session of the project and their dependents', () async {
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final a1 = await _seedSessionGraph(
        store,
        projectPath: '/a',
        filePath: '/a/one.dart',
      );
      final a2 = await _seedSessionGraph(
        store,
        projectPath: '/a',
        filePath: '/a/two.dart',
      );
      final b = await _seedSessionGraph(
        store,
        projectPath: '/b',
        filePath: '/b/keep.dart',
      );

      final removed = await store.deleteByProjectPath('/a');
      expect(removed, 2);

      for (final g in [a1, a2]) {
        expect(await _sessionRows(db, g.sessionId), 0);
        expect(await _childRows(db, 'messages', g.sessionId), 0);
        expect(await _childRows(db, 'parts', g.sessionId), 0);
        expect(await _childRows(db, 'file_read_state', g.sessionId), 0);
        expect(
          await _writerRows(db, g.sessionId),
          0,
          reason: 'file_last_writer must not orphan',
        );
      }
      expect(
        await _sessionRows(db, b.sessionId),
        1,
        reason: 'other projects must be untouched',
      );
      expect(await _childRows(db, 'messages', b.sessionId), 1);
      expect(await _writerRows(db, b.sessionId), 1);
    });

    test(
      'is atomic: failure on the sessions delete rolls back children',
      () async {
        final executor = _SabotageExecutor(
          NativeDatabase.memory(),
          failOn: 'DELETE FROM "sessions"',
        );
        final db = CruxDatabase.forTesting(executor);
        addTearDown(db.close);
        final store = SessionStore(db);
        final g = await _seedSessionGraph(store);

        executor.armed = true;
        await expectLater(store.deleteByProjectPath('/proj'), throwsStateError);
        executor.armed = false;

        expect(await _sessionRows(db, g.sessionId), 1);
        expect(await _childRows(db, 'messages', g.sessionId), 1);
        expect(await _childRows(db, 'parts', g.sessionId), 1);
        expect(await _childRows(db, 'file_read_state', g.sessionId), 1);
        expect(await _writerRows(db, g.sessionId), 1);
      },
    );
  });

  group('MessageStore.deleteCompleteCompactions', () {
    Future<void> addCompaction(
      SessionStore store,
      int sessionId, {
      required String meta,
    }) {
      return store.messageStore.addMessage(
        sessionId,
        role: 'compaction',
        content: 'summary',
        meta: meta,
      );
    }

    test('deletes only complete compactions, in one transaction', () async {
      final db = _fkDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final session = await store.create(
        title: 't',
        model: 'm',
        projectPath: '/p',
      );

      await addCompaction(store, session.id, meta: ''); // complete
      await addCompaction(
        store,
        session.id,
        meta: '{"status":"complete"}',
      ); // complete
      await addCompaction(
        store,
        session.id,
        meta: 'not-json{',
      ); // unparseable meta counts as complete
      await addCompaction(
        store,
        session.id,
        meta: '{"status":"compacting"}',
      ); // in-progress: keep
      await addCompaction(
        store,
        session.id,
        meta: '{"status":"failed"}',
      ); // failed: keep

      final deleted = await store.messageStore.deleteCompleteCompactions(
        session.id,
      );
      expect(deleted, 3);

      final remaining = await store.messageStore.getMessages(session.id);
      expect(remaining, hasLength(2));
      expect(remaining.map((m) => m.meta).toSet(), {
        '{"status":"compacting"}',
        '{"status":"failed"}',
      });
    });

    test('is atomic: failure mid-delete rolls back earlier deletes', () async {
      final executor = _SabotageExecutor(
        NativeDatabase.memory(),
        failOn: 'DELETE FROM "messages"',
      );
      final db = CruxDatabase.forTesting(executor);
      addTearDown(db.close);
      final store = SessionStore(db);
      final session = await store.create(
        title: 't',
        model: 'm',
        projectPath: '/p',
      );
      await addCompaction(store, session.id, meta: '');
      await addCompaction(store, session.id, meta: '{"status":"complete"}');

      executor.armed = true;
      await expectLater(
        store.messageStore.deleteCompleteCompactions(session.id),
        throwsStateError,
      );
      executor.armed = false;

      final remaining = await store.messageStore.getMessages(session.id);
      expect(
        remaining,
        hasLength(2),
        reason: 'both compaction rows must survive the rollback',
      );
    });
  });

  group('MessageStore.repairOrphanToolRows — corrupt toolCalls JSON', () {
    test('corrupt row is skipped, not treated as a flow terminator', () async {
      // Flow under repair: tool_call announces {a, b}; tool(a) lands;
      // then a tool_call row with corrupt toolCalls JSON appears;
      // then tool(b) lands. The corrupt row cannot terminate the
      // pending flow — its announced ids are unknowable — so {b}
      // must still match its result and the repair is a no-op.
      // (Pre-fix, the corrupt row was treated as an empty tool_call,
      // which orphaned 'b': tool(b) was deleted and 'b' was pruned
      // from the first tool_call row.)
      final db = _plainDatabase();
      addTearDown(db.close);
      final store = SessionStore(db);
      final session = await store.create(
        title: 't',
        model: 'm',
        projectPath: '/p',
      );
      final messages = store.messageStore;

      await messages.addMessage(session.id, role: 'user', content: 'do it');
      await messages.addToolRound(
        session.id,
        toolCalls: [
          ToolCallData(callId: 'a', name: 'read', input: {}),
          ToolCallData(callId: 'b', name: 'grep', input: {}),
        ],
        results: [(callId: 'a', output: 'a-out', meta: '')],
      );
      // Raw insert: addMessage always encodes well-formed JSON, so a
      // corrupt payload has to go in at the drift layer.
      await db
          .into(db.messages)
          .insert(
            dbdef.MessagesCompanion.insert(
              sessionId: session.id,
              role: 'tool_call',
              createdAt: DateTime.now().millisecondsSinceEpoch,
              toolCalls: const Value('{"broken": true,'),
            ),
          );
      await messages.addMessage(
        session.id,
        role: 'tool',
        content: 'b-out',
        toolCallId: 'b',
      );

      final n = await messages.repairOrphanToolRows(session.id);
      expect(
        n,
        0,
        reason:
            'the {a,b} flow is well-formed once the corrupt row '
            'is skipped',
      );

      final all = await messages.getMessages(session.id);
      expect(
        all.where((m) => m.role == 'tool'),
        hasLength(2),
        reason: 'tool(b) must not be reaped as an orphan',
      );
      final toolCallRows = all.where((m) => m.role == 'tool_call').toList();
      expect(
        toolCallRows,
        hasLength(2),
        reason: 'the corrupt row itself is left untouched',
      );
      expect(toolCallRows.first.toolCalls.map((c) => c.callId).toList(), [
        'a',
        'b',
      ], reason: 'the well-formed tool_call row keeps both entries');
    });

    test(
      'corrupt row does not shield a genuinely orphaned pending flow',
      () async {
        // The corrupt row is skipped, but ids still pending at end of
        // input are still orphans: tool_call announces {a}, no result
        // ever lands, and a corrupt row follows. 'a' is unrecoverable
        // and must still be reaped.
        final db = _plainDatabase();
        addTearDown(db.close);
        final store = SessionStore(db);
        final session = await store.create(
          title: 't',
          model: 'm',
          projectPath: '/p',
        );
        final messages = store.messageStore;

        await messages.addToolRound(
          session.id,
          toolCalls: [ToolCallData(callId: 'a', name: 'read', input: {})],
          results: const [],
        );
        await db
            .into(db.messages)
            .insert(
              dbdef.MessagesCompanion.insert(
                sessionId: session.id,
                role: 'tool_call',
                createdAt: DateTime.now().millisecondsSinceEpoch,
                toolCalls: const Value('!!!'),
              ),
            );

        final n = await messages.repairOrphanToolRows(session.id);
        expect(n, 1, reason: 'only the orphaned tool_call row is deleted');

        final all = await messages.getMessages(session.id);
        expect(
          all,
          hasLength(1),
          reason: 'the corrupt row survives; the orphan row is gone',
        );
        expect(all.single.role, 'tool_call');
        expect(
          all.single.toolCalls,
          isEmpty,
          reason: 'the surviving row is the corrupt (unparseable) one',
        );
      },
    );
  });
}

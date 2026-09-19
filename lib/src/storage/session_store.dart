import 'dart:io';

import 'package:drift/drift.dart';

import 'agent_store.dart';
import 'database.dart' as db;
import '../models/session.dart';
import '../services/llm_error.dart';
import 'message_store.dart';
import 'notes_store.dart';
import 'shell_monitor_log_store.dart';

const _unset = Object();

class SessionLeaseClaimException implements Exception {
  final int sessionId;

  SessionLeaseClaimException(this.sessionId);

  @override
  String toString() {
    return 'Session #$sessionId is already running in another Crux instance.';
  }
}

/// Data-access layer for sessions.
///
/// Message and parts CRUD live in [MessageStore].
/// This class implements [SessionStoreAccessor] so [MessageStore] can
/// bump `updated_at` on message writes without a circular dependency.
class SessionStore implements SessionStoreAccessor {
  static const defaultRunningLeaseTimeout = Duration(seconds: 30);

  final db.CruxDatabase _db;
  final String instanceId;
  final Duration runningLeaseTimeout;

  /// The underlying database. Exposed so sibling stores that share
  /// this database's lifetime (e.g. [shellMonitorLogStore]) can be
  /// constructed without threading the raw [db.CruxDatabase] through
  /// every call site.
  db.CruxDatabase get database => _db;

  ShellMonitorLogStore? _shellMonitorLogStore;

  /// Lazily-created store for `shell_monitor_logs`. Lazy so tests
  /// that never touch the monitor don't pay for the accessor, and so
  /// the store shares this [SessionStore]'s database connection (and
  /// therefore its WAL / busy-timeout pragmas).
  ShellMonitorLogStore get shellMonitorLogStore =>
      _shellMonitorLogStore ??= ShellMonitorLogStore(_db);

  NotesStore? _notesStore;

  /// Lazily-created store for `project_notes` (the "my notes"
  /// feature). Shares this [SessionStore]'s database connection, same
  /// rationale as [shellMonitorLogStore].
  NotesStore get notesStore => _notesStore ??= NotesStore(_db);

  AgentStore? _agentStore;

  /// Lazily-created store for the `agents` roster (subagent v2).
  /// Shares this [SessionStore]'s database connection, same rationale
  /// as [notesStore].
  AgentStore get agentStore => _agentStore ??= AgentStore(_db);

  /// Message store — set after construction to avoid a circular
  /// dependency. [MessageStore.sessionStore] points back here.
  late final MessageStore messageStore;

  SessionStore(
    this._db, {
    String? instanceId,
    this.runningLeaseTimeout = defaultRunningLeaseTimeout,
  }) : instanceId = instanceId ?? _defaultInstanceId() {
    messageStore = MessageStore(_db)..sessionStore = this;
  }

  int _slugCounter = 0;

  String _generateSlug() {
    _slugCounter++;
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'session-$ts-$_slugCounter';
  }

  static String _defaultInstanceId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'crux-$pid-$ts';
  }

  Future<Session> create({
    String title = '',
    String model = '',
    String projectPath = '',
    String agent = '',
    int? parentId,
    String? kind,
  }) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final slug = _generateSlug();
    final id = await _db
        .into(_db.sessions)
        .insert(
          db.SessionsCompanion.insert(
            status: SessionStatus.idle,
            createdAt: nowMs,
            updatedAt: nowMs,
            slug: Value(slug),
            title: Value(title),
            model: Value(model),
            agent: Value(agent),
            parentId: Value(parentId),
            projectPath: Value(projectPath),
            kind: Value(kind),
          ),
        );
    return Session(
      id: id,
      slug: slug,
      title: title,
      model: model,
      status: SessionStatus.idle,
      agent: agent,
      parentId: parentId,
      projectPath: projectPath,
      kind: kind,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<Session?> getById(int id) async {
    final row = await (_db.select(
      _db.sessions,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _rowToSession(row);
  }

  Future<List<Session>> list({
    String? projectPath,
    int limit = 100,
    int offset = 0,
    bool includeArchived = false,
  }) async {
    final query = _db.select(_db.sessions)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(limit, offset: offset);

    query.where((t) {
      final conditions = <Expression<bool>>[];
      // Chat-mode rows are never returned by [list] — they belong to
      // the global "Chats" section (see [listChats]), not the
      // project-scoped "Sessions" list.
      conditions.add(t.kind.isNull() | t.kind.isNotValue('chat'));
      if (projectPath != null) {
        conditions.add(t.projectPath.equals(projectPath));
      }
      if (!includeArchived) {
        conditions.add(t.archivedAt.isNull());
      }
      return conditions.reduce((a, b) => a & b);
    });

    final rows = await query.get();
    return rows.map(_rowToSession).toList();
  }

  /// List Chat-mode sessions across *all* projects. Chats are not
  /// tied to a workspace (`projectPath` is `''`), so they are visible
  /// in every Crux instance's "Chats" section. The running-lease
  /// fields on each row ([Session.runningOwnerId],
  /// [Session.runningHeartbeatAt]) are what make a chat that's open
  /// (streaming) in one instance refuse to open in another — the same
  /// mechanism that guards regular sessions.
  Future<List<Session>> listChats({
    int limit = 100,
    int offset = 0,
    bool includeArchived = false,
  }) async {
    final query = _db.select(_db.sessions)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(limit, offset: offset);

    query.where((t) {
      final conditions = <Expression<bool>>[t.kind.equals('chat')];
      if (!includeArchived) {
        conditions.add(t.archivedAt.isNull());
      }
      return conditions.reduce((a, b) => a & b);
    });

    final rows = await query.get();
    return rows.map(_rowToSession).toList();
  }

  /// Every session row — workspace sessions AND chats, active AND
  /// archived — newest-first by [Session.updatedAt]. Powers the
  /// session management panel's search box, which must see archived
  /// rows (the sidebar lists and the `#` mention candidates cannot:
  /// those are split/bounded — see [list] / [listChats] /
  /// [loadSessionMentionCandidates callers for the living-set variants]).
  ///
  /// [limit] caps the row materialization so a years-old database
  /// cannot freeze the panel; it is deliberately generous (500)
  /// because scanning happens in memory over titles + ids.
  Future<List<Session>> listAny({int limit = 500}) async {
    final query = _db.select(_db.sessions)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_rowToSession).toList();
  }

  Future<void> archiveSession(int id) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(archivedAt: Value(nowMs), updatedAt: Value(nowMs)),
    );
  }

  Future<void> unarchiveSession(int id) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        archivedAt: const Value(null),
        updatedAt: Value(nowMs),
      ),
    );
  }

  /// Pin a session (workspace or chat) to the top of the sidebar.
  /// Sets [pinnedAt] to now and leaves [updatedAt] untouched, so
  /// pinning does not re-order the recency buckets — pinned rows sort
  /// by [pinnedAt], not [updatedAt].
  Future<void> pinSession(int id) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(pinnedAt: Value(nowMs)),
    );
  }

  /// Unpin a session, returning it to the normal recency-sorted list.
  Future<void> unpinSession(int id) async {
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(pinnedAt: const Value(null)),
    );
  }

  /// Auto-archive all un-archived sessions for [projectPath] whose
  /// [updatedAt] is older than [olderThan]. Returns the number of
  /// sessions that were archived.
  ///
  /// Uses a single indexed UPDATE — O(log n) with the
  /// `idx_sessions_project_archived` index, no full table scan.
  Future<int> autoArchive({
    String? projectPath,
    required Duration olderThan,
  }) async {
    final cutoffMs = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final query = _db.update(_db.sessions)
      ..where((t) => t.archivedAt.isNull())
      ..where((t) => t.pinnedAt.isNull())
      ..where((t) => t.updatedAt.isSmallerThanValue(cutoffMs));

    if (projectPath != null) {
      // Project-scoped pass. Chat rows have projectPath='' so they
      // never match here; chats are swept separately by
      // [autoArchiveChats].
      query.where((t) => t.projectPath.equals(projectPath));
    }

    return query.write(
      db.SessionsCompanion(archivedAt: Value(nowMs), updatedAt: Value(nowMs)),
    );
  }

  /// Auto-archive Chat-mode sessions not updated in [olderThan].
  /// Mirrors the per-project [autoArchive] but scoped to `kind='chat'`
  /// rows globally (chats aren't tied to any workspace). Keeps the
  /// "Chats" sidebar section from filling with stale rows, matching
  /// the 3-day behaviour regular sessions get.
  Future<int> autoArchiveChats({required Duration olderThan}) async {
    final cutoffMs = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.sessions)
          ..where((t) => t.kind.equals('chat'))
          ..where((t) => t.archivedAt.isNull())
          ..where((t) => t.pinnedAt.isNull())
          ..where((t) => t.updatedAt.isSmallerThanValue(cutoffMs)))
        .write(
          db.SessionsCompanion(
            archivedAt: Value(nowMs),
            updatedAt: Value(nowMs),
          ),
        );
  }

  /// Count of archived sessions for a given project path.
  ///
  /// Uses a single `SELECT COUNT(*)` — O(log n) with the
  /// `idx_sessions_project_archived` index, no row materialization.
  Future<int> archivedCount({String? projectPath}) async {
    final countExp = countAll();
    final query = _db.selectOnly(_db.sessions)
      ..addColumns([countExp])
      ..where(_db.sessions.archivedAt.isNotNull())
      // Chat rows belong to the global "Chats" section; count them
      // separately via [archivedChatCount].
      ..where(
        _db.sessions.kind.isNull() | _db.sessions.kind.isNotValue('chat'),
      );

    if (projectPath != null) {
      query.where(_db.sessions.projectPath.equals(projectPath));
    }

    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// Count of archived Chat-mode sessions (global, not project-scoped).
  Future<int> archivedChatCount() async {
    final countExp = countAll();
    final query = _db.selectOnly(_db.sessions)
      ..addColumns([countExp])
      ..where(_db.sessions.archivedAt.isNotNull())
      ..where(_db.sessions.kind.equals('chat'));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  Future<Session> update(
    int id, {
    String? title,
    String? model,
    SessionStatus? status,
    int? tokensIn,
    int? tokensOut,
    int? contextTokens,
    String? thinkingMode,
    Object? reasoningEffort = _unset,
    Object? temperatureOverride = _unset,
    double? ttftMs,
    double? tokPerSec,
    int? promptCacheHitTokens,
    Object? systemPrompt = _unset,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (status == SessionStatus.running) {
      return _claimRunningLease(id, nowMs: nowMs);
    }
    final Value<String?> effortValue = reasoningEffort == _unset
        ? const Value.absent()
        : reasoningEffort == null
        ? const Value(null)
        : Value(reasoningEffort as String);
    // Tri-state: caller didn't pass it (absent, leave alone), explicitly
    // cleared the override to `null` (drop model override), or set a new
    // value. Same pattern as `reasoningEffort` so the row can represent
    // "use the model default" without the caller having to special-case.
    final Value<double?> tempValue = temperatureOverride == _unset
        ? const Value.absent()
        : temperatureOverride == null
        ? const Value(null)
        : Value(temperatureOverride as double);
    final Value<String?> systemPromptValue = systemPrompt == _unset
        ? const Value.absent()
        : systemPrompt == null
        ? const Value(null)
        : Value(systemPrompt as String);
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        model: model != null ? Value(model) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        tokensIn: tokensIn != null ? Value(tokensIn) : const Value.absent(),
        tokensOut: tokensOut != null ? Value(tokensOut) : const Value.absent(),
        contextTokens: contextTokens != null
            ? Value(contextTokens)
            : const Value.absent(),
        thinkingMode: thinkingMode != null
            ? Value(thinkingMode)
            : const Value.absent(),
        reasoningEffort: effortValue,
        temperatureOverride: tempValue,
        ttftMs: ttftMs != null ? Value(ttftMs) : const Value.absent(),
        tokPerSec: tokPerSec != null ? Value(tokPerSec) : const Value.absent(),
        promptCacheHitTokens: promptCacheHitTokens != null
            ? Value(promptCacheHitTokens)
            : const Value.absent(),
        systemPrompt: systemPromptValue,
        runningOwnerId: status != null
            ? const Value(null)
            : const Value.absent(),
        runningHeartbeatAt: status != null
            ? const Value(null)
            : const Value.absent(),
        updatedAt: Value(nowMs),
      ),
    );
    final updated = await getById(id);
    return updated!;
  }

  Future<Session> _claimRunningLease(int id, {required int nowMs}) async {
    final staleBeforeMs = nowMs - runningLeaseTimeout.inMilliseconds;
    final updated = await _db.customUpdate(
      '''
UPDATE sessions
SET status = ?,
    running_owner_id = ?,
    running_heartbeat_at = ?,
    updated_at = ?
WHERE id = ?
  AND (
    status != ?
    OR running_owner_id IS NULL
    OR running_owner_id = ?
    OR running_heartbeat_at IS NULL
    OR running_heartbeat_at < ?
  )
''',
      variables: [
        Variable<String>(SessionStatus.running.name),
        Variable<String>(instanceId),
        Variable<int>(nowMs),
        Variable<int>(nowMs),
        Variable<int>(id),
        Variable<String>(SessionStatus.running.name),
        Variable<String>(instanceId),
        Variable<int>(staleBeforeMs),
      ],
      updates: {_db.sessions},
    );
    if (updated == 0) {
      final existing = await getById(id);
      if (existing == null) {
        throw StateError('Session #$id not found');
      }
      throw SessionLeaseClaimException(id);
    }
    final reloaded = await getById(id);
    return reloaded!;
  }

  Future<void> heartbeatRunningSession(int sessionId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _db.customUpdate(
      '''
UPDATE sessions
SET running_heartbeat_at = ?
WHERE id = ?
  AND status = ?
  AND running_owner_id = ?
''',
      variables: [
        Variable<int>(nowMs),
        Variable<int>(sessionId),
        Variable<String>(SessionStatus.running.name),
        Variable<String>(instanceId),
      ],
      updates: {_db.sessions},
    );
  }

  bool isLiveRunningSessionOwnedByAnotherInstance(Session session) {
    if (session.status != SessionStatus.running) return false;
    final ownerId = session.runningOwnerId;
    final heartbeatAt = session.runningHeartbeatAt;
    if (ownerId == null || ownerId == instanceId || heartbeatAt == null) {
      return false;
    }
    final staleBefore = DateTime.now().subtract(runningLeaseTimeout);
    return heartbeatAt.isAfter(staleBefore);
  }

  /// Delete a session and every row that belongs to it.
  ///
  /// Runs in a single transaction so a failure midway can never
  /// leave a half-deleted session behind. Child rows are deleted
  /// explicitly rather than relying on the `ON DELETE CASCADE`
  /// foreign keys declared in tables.dart: cascades only fire on
  /// connections with `PRAGMA foreign_keys=ON` (the production
  /// connection setup enables it — see database.dart), and the
  /// explicit deletes keep cleanup correct on executors that don't
  /// set the pragma (e.g. bare in-memory test databases).
  ///
  /// `file_last_writer` rows pointing at the deleted session are
  /// removed as well. They were never cleaned up before FK
  /// enforcement existed, so existing installs can carry orphans
  /// that would make the read-before-write guard attribute writes
  /// to a session that no longer exists.
  Future<void> deleteSession(int id) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.fileLastWriter,
      )..where((t) => t.writerSessionId.equals(id))).go();
      await (_db.delete(
        _db.fileReadState,
      )..where((t) => t.sessionId.equals(id))).go();
      await (_db.delete(_db.parts)..where((t) => t.sessionId.equals(id))).go();
      await (_db.delete(
        _db.messages,
      )..where((t) => t.sessionId.equals(id))).go();
      await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> saveFileReadState(
    int sessionId,
    String normalizedPath,
    int mtimeMs,
  ) async {
    await _db
        .into(_db.fileReadState)
        .insertOnConflictUpdate(
          db.FileReadStateCompanion.insert(
            sessionId: sessionId,
            path: normalizedPath,
            mtimeMs: mtimeMs,
          ),
        );
  }

  Future<Map<String, int>> loadFileReadState(int sessionId) async {
    final rows = await (_db.select(
      _db.fileReadState,
    )..where((t) => t.sessionId.equals(sessionId))).get();
    return {for (final r in rows) r.path: r.mtimeMs};
  }

  /// Upsert the `file_last_writer` row for [path]. Called by the
  /// edit/write tools after a successful mutation, so other
  /// sessions' read-before-write guards can name this session and
  /// its intent when they hit mtime drift on the same file.
  ///
  /// One row per path (PK = path) — overwriting a previous writer
  /// is the point. The recorded `mtimeMs` is the post-write mtime
  /// the tracker observed; the guard cross-checks it against the
  /// current on-disk mtime and drops the attribution line when
  /// they don't match (external edit between our write and the
  /// guard check).
  Future<void> saveLastWriter(
    int sessionId,
    String normalizedPath,
    int mtimeMs,
    String intent,
  ) async {
    await _db
        .into(_db.fileLastWriter)
        .insertOnConflictUpdate(
          db.FileLastWriterCompanion.insert(
            path: normalizedPath,
            writerSessionId: sessionId,
            intent: Value(intent),
            mtimeMs: mtimeMs,
          ),
        );
  }

  /// Look up who last wrote [path]. Returns `null` when no
  /// attribution row exists. That can mean the file was never
  /// written by a tracked session, or that the writer's row was
  /// removed together with the session: [deleteSession] and
  /// [deleteByProjectPath] delete `file_last_writer` rows
  /// explicitly, and a direct `sessions`-row delete also cascades
  /// here — but only on connections with `PRAGMA foreign_keys=ON`
  /// (the production connection setup enables it; executors without
  /// the pragma rely on the explicit deletes).
  Future<({int sessionId, String intent, int mtimeMs})?> loadLastWriter(
    String normalizedPath,
  ) async {
    final row = await (_db.select(
      _db.fileLastWriter,
    )..where((t) => t.path.equals(normalizedPath))).getSingleOrNull();
    if (row == null) return null;
    return (
      sessionId: row.writerSessionId,
      intent: row.intent,
      mtimeMs: row.mtimeMs,
    );
  }

  /// Look up the live title for a session. Used by the guard to
  /// render the attribution line — looked up live (not snapshotted
  /// at write time) so `/rename` changes are reflected immediately.
  /// Returns `''` when the session doesn't exist (was deleted
  /// between the write and the guard check) — the guard still
  /// names the id, just without a title.
  Future<String> lookupSessionTitle(int sessionId) async {
    final row = await (_db.select(
      _db.sessions,
    )..where((t) => t.id.equals(sessionId))).getSingleOrNull();
    return row?.title ?? '';
  }

  /// Delete every session for [projectPath] and all of their
  /// dependent rows. Returns the number of sessions deleted.
  ///
  /// The id-list read and all deletes run in one transaction, so
  /// the operation is all-or-nothing and a concurrently created
  /// session can't slip between the read and the deletes. Child
  /// rows — including `file_last_writer` — are deleted explicitly
  /// rather than relying on FK cascades; see [deleteSession] for
  /// why.
  Future<int> deleteByProjectPath(String projectPath) async {
    return _db.transaction(() async {
      final sessionIds =
          await (_db.select(_db.sessions)
                ..where((t) => t.projectPath.equals(projectPath)))
              .map((row) => row.id)
              .get();
      for (final id in sessionIds) {
        await (_db.delete(
          _db.fileLastWriter,
        )..where((t) => t.writerSessionId.equals(id))).go();
        await (_db.delete(
          _db.fileReadState,
        )..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(
          _db.parts,
        )..where((t) => t.sessionId.equals(id))).go();
        await (_db.delete(
          _db.messages,
        )..where((t) => t.sessionId.equals(id))).go();
      }
      await (_db.delete(
        _db.sessions,
      )..where((t) => t.projectPath.equals(projectPath))).go();
      return sessionIds.length;
    });
  }

  /// Bump the `updated_at` timestamp for [sessionId]. Called by
  /// [MessageStore] when a message is written or deleted so the
  /// session's sort order stays accurate in the sidebar.
  @override
  Future<void> touchSession(int sessionId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(sessionId)))
        .write(db.SessionsCompanion(updatedAt: Value(nowMs)));
  }

  /// Repair sessions whose `context_tokens` was reset to 0 by a
  /// failed AI turn (network error / user ESC / stream interrupted
  /// before the LLM reported any usage). The next-turn projection
  /// uses `session.contextTokens` as its primary basis, so a 0
  /// value would force it through the slow fallback path; the
  /// displayed context bar would also inflate (summing tool
  /// content on top of an effectively-missing last-AI prompt).
  ///
  /// Reconstruct `context_tokens` from the last AI message that
  /// actually reported tokens: `tokens_in + tokens_out -
  /// reasoning_tokens`. AI `tokens_in` is the per-turn prompt size
  /// already cumulative within the session, so this single value
  /// is the right projection. Idempotent — sessions that already
  /// have `context_tokens > 0` are left alone.
  ///
  /// Returns the number of sessions repaired.
  Future<int> repairStaleContextTokens() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final result = await _db.customUpdate(
      '''
UPDATE sessions
SET context_tokens = (
  SELECT m.tokens_in + m.tokens_out - m.reasoning_tokens
  FROM messages m
  WHERE m.session_id = sessions.id
    AND m.role = 'ai'
    AND m.tokens_in > 0
  ORDER BY m.id DESC
  LIMIT 1
),
    updated_at = ?
WHERE context_tokens = 0
  AND EXISTS (
    SELECT 1 FROM messages m
    WHERE m.session_id = sessions.id
      AND m.role = 'ai'
      AND m.tokens_in > 0
  )
      ''',
      variables: [Variable.withInt(nowMs)],
      updates: {_db.sessions},
    );
    return result;
  }

  /// Mark every session in [projectPath] with status
  /// [SessionStatus.running] as [SessionStatus.interrupted].
  ///
  /// On a clean launch there should be no stale sessions in `running`
  /// for the current project —
  /// the only way one ends up that way in the database is if a
  /// previous Crux process was killed (crash, SIGKILL, power loss)
  /// while a turn was streaming. The in-memory state that would
  /// have driven those sessions to `done` (or `needUserAction`) is
  /// gone, so on the next launch we transition them to
  /// `interrupted` — that mirrors the path the orchestrator takes
  /// when the user presses Esc mid-stream, and the UI can render
  /// them as resumable rather than falsely reporting them as
  /// still in flight.
  ///
  /// For every transitioned session this also persists a
  /// `stream_error` row explaining WHY the turn stopped (the process
  /// died mid-stream), so the chat history shows an abnormal-stop
  /// bubble with a one-click continue affordance instead of leaving
  /// the turn silently dangling. Best-effort: a failed insert never
  /// blocks the status transition.
  ///
  /// Returns the number of sessions transitioned.
  Future<int> markOrphanedRunningSessionsAsInterrupted({
    required String projectPath,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final staleBeforeMs = nowMs - runningLeaseTimeout.inMilliseconds;

    // Read the ids BEFORE the update so we know which sessions to
    // annotate. The lease predicates match exactly what the UPDATE
    // below transitions, so the two sets are identical.
    final staleIds =
        await (_db.select(_db.sessions)
              ..where((t) => t.status.equals(SessionStatus.running.name))
              ..where((t) => t.projectPath.equals(projectPath))
              ..where(
                (t) =>
                    t.runningOwnerId.isNull() |
                    t.runningHeartbeatAt.isNull() |
                    t.runningHeartbeatAt.isSmallerThanValue(staleBeforeMs),
              ))
            .map((row) => row.id)
            .get();

    final updated = await _db.customUpdate(
      '''
UPDATE sessions
SET status = ?,
    running_owner_id = NULL,
    running_heartbeat_at = NULL,
    updated_at = ?
WHERE status = ?
  AND project_path = ?
  AND (
    running_owner_id IS NULL
    OR running_heartbeat_at IS NULL
    OR running_heartbeat_at < ?
  )
''',
      variables: [
        Variable<String>(SessionStatus.interrupted.name),
        Variable<int>(nowMs),
        Variable<String>(SessionStatus.running.name),
        Variable<String>(projectPath),
        Variable<int>(staleBeforeMs),
      ],
      updates: {_db.sessions},
    );

    // Persist an abnormal-stop bubble for each transitioned session.
    // The structured payload decodes into the same ErrorBubble the
    // live error path renders, so a crash-resumed turn reads exactly
    // like any other non-normal stop: reason + one-click continue.
    for (final id in staleIds) {
      try {
        final stopError = LlmError(
          kind: LlmErrorKind.cancelled,
          vendor: LlmVendor.unknown,
          message:
              'The previous Crux process exited while this turn '
              'was still streaming — the response was cut off.',
          providerName: '',
        );
        await messageStore.addMessage(
          id,
          role: 'stream_error',
          content: stopError.toUserMessage(),
          error: stopError.toJson(),
        );
      } catch (_) {
        // Annotation is best-effort; the status transition above is
        // the source of truth and must not be rolled back.
      }
    }

    return updated;
  }

  Session _rowToSession(db.Session row) {
    return Session(
      id: row.id,
      slug: row.slug,
      title: row.title,
      model: row.model,
      status: row.status,
      agent: row.agent,
      parentId: row.parentId,
      projectPath: row.projectPath,
      tokensIn: row.tokensIn,
      tokensOut: row.tokensOut,
      contextTokens: row.contextTokens,
      thinkingMode: row.thinkingMode,
      reasoningEffort: row.reasoningEffort,
      temperatureOverride: row.temperatureOverride,
      ttftMs: row.ttftMs,
      tokPerSec: row.tokPerSec,
      promptCacheHitTokens: row.promptCacheHitTokens,
      runningOwnerId: row.runningOwnerId,
      runningHeartbeatAt: row.runningHeartbeatAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.runningHeartbeatAt!)
          : null,
      kind: row.kind,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      archivedAt: row.archivedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.archivedAt!)
          : null,
      pinnedAt: row.pinnedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.pinnedAt!)
          : null,
      systemPrompt: row.systemPrompt,
    );
  }
}

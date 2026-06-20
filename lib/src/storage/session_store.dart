import 'dart:io';

import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/session.dart';
import 'message_store.dart';

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

    if (projectPath != null || !includeArchived) {
      query.where((t) {
        final conditions = <Expression<bool>>[];
        if (projectPath != null) {
          conditions.add(t.projectPath.equals(projectPath));
        }
        if (!includeArchived) {
          conditions.add(t.archivedAt.isNull());
        }
        return conditions.reduce((a, b) => a & b);
      });
    }

    final rows = await query.get();
    return rows.map(_rowToSession).toList();
  }

  Future<void> archiveSession(int id) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        archivedAt: Value(nowMs),
        updatedAt: Value(nowMs),
      ),
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

  /// Auto-archive all un-archived sessions for [projectPath] whose
  /// [updatedAt] is older than [olderThan]. Returns the number of
  /// sessions that were archived.
  Future<int> autoArchive({
    String? projectPath,
    required Duration olderThan,
  }) async {
    final cutoffMs =
        DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final candidates = await _db.select(_db.sessions).get();
    final toArchive = <int>[];
    for (final row in candidates) {
      if (row.archivedAt != null) continue;
      if (projectPath != null && row.projectPath != projectPath) continue;
      if (row.updatedAt < cutoffMs) {
        toArchive.add(row.id);
      }
    }
    if (toArchive.isEmpty) return 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final id in toArchive) {
      await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
        db.SessionsCompanion(
          archivedAt: Value(nowMs),
          updatedAt: Value(nowMs),
        ),
      );
    }
    return toArchive.length;
  }

  /// Count of archived sessions for a given project path.
  Future<int> archivedCount({String? projectPath}) async {
    final archived = await list(
      projectPath: projectPath,
      includeArchived: true,
      limit: 1000,
    );
    return archived.where((s) => s.archivedAt != null).length;
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

  Future<void> deleteSession(int id) async {
    await (_db.delete(_db.fileReadState)
          ..where((t) => t.sessionId.equals(id)))
        .go();
    await (_db.delete(_db.parts)..where((t) => t.sessionId.equals(id))).go();
    await (_db.delete(_db.messages)..where((t) => t.sessionId.equals(id))).go();
    await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
  }

  Future<void> saveFileReadState(
      int sessionId, String normalizedPath, int mtimeMs) async {
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
    final rows = await (_db.select(_db.fileReadState)
          ..where((t) => t.sessionId.equals(sessionId)))
        .get();
    return {for (final r in rows) r.path: r.mtimeMs};
  }

  Future<int> deleteByProjectPath(String projectPath) async {
    final sessionIds =
        await (_db.select(_db.sessions)
              ..where((t) => t.projectPath.equals(projectPath)))
            .map((row) => row.id)
            .get();
    for (final id in sessionIds) {
      await (_db.delete(
        _db.messages,
      )..where((t) => t.sessionId.equals(id))).go();
      await (_db.delete(_db.parts)..where((t) => t.sessionId.equals(id))).go();
      await (_db.delete(_db.fileReadState)
            ..where((t) => t.sessionId.equals(id)))
          .go();
    }
    await (_db.delete(
      _db.sessions,
    )..where((t) => t.projectPath.equals(projectPath))).go();
    return sessionIds.length;
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
  /// Returns the number of sessions transitioned.
  Future<int> markOrphanedRunningSessionsAsInterrupted({
    required String projectPath,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final staleBeforeMs = nowMs - runningLeaseTimeout.inMilliseconds;
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
      ttftMs: row.ttftMs,
      tokPerSec: row.tokPerSec,
      promptCacheHitTokens: row.promptCacheHitTokens,
      runningOwnerId: row.runningOwnerId,
      runningHeartbeatAt: row.runningHeartbeatAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.runningHeartbeatAt!)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      archivedAt: row.archivedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.archivedAt!)
          : null,
      systemPrompt: row.systemPrompt,
    );
  }
}

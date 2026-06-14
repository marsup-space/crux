import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/session.dart';
import 'message_store.dart';

const _unset = Object();

/// Data-access layer for sessions.
///
/// Message, parts, and offloaded-content CRUD live in [MessageStore].
/// This class implements [SessionStoreAccessor] so [MessageStore] can
/// bump `updated_at` on message writes without a circular dependency.
class SessionStore implements SessionStoreAccessor {
  final db.CruxDatabase _db;

  /// Message store — set after construction to avoid a circular
  /// dependency. [MessageStore.sessionStore] points back here.
  late final MessageStore messageStore;

  SessionStore(this._db) {
    messageStore = MessageStore(_db)..sessionStore = this;
  }

  int _slugCounter = 0;

  String _generateSlug() {
    _slugCounter++;
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'session-$ts-$_slugCounter';
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
    // Free the off-loaded bytes tied to this session. The session
    // itself survives archive (just hidden from the sidebar), so a
    // future unarchive can still read the message history; only the
    // recallable bytes are dropped.
    await messageStore.cleanOffloadedContent(id);
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
    double? cost,
    int? tokensIn,
    int? tokensOut,
    int? contextTokens,
    String? thinkingMode,
    Object? reasoningEffort = _unset,
    double? ttftMs,
    double? tokPerSec,
    int? promptCacheHitTokens,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final Value<String?> effortValue = reasoningEffort == _unset
        ? const Value.absent()
        : reasoningEffort == null
        ? const Value(null)
        : Value(reasoningEffort as String);
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        model: model != null ? Value(model) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        cost: cost != null ? Value(cost) : const Value.absent(),
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
        updatedAt: Value(nowMs),
      ),
    );
    final updated = await getById(id);
    return updated!;
  }

  Future<void> deleteSession(int id) async {
    // Manual deletes in FK-cascade order. The schema declares
    // `onDelete: KeyAction.cascade` on the child rows, but the
    // connection does not enable `PRAGMA foreign_keys = ON` —
    // so the cascade is advisory, not enforced. Doing the
    // deletes explicitly keeps cleanup correct without changing
    // the connection setup.
    await (_db.delete(_db.offloadedContent)
          ..where((t) => t.sessionId.equals(id)))
        .go();
    await (_db.delete(_db.parts)..where((t) => t.sessionId.equals(id))).go();
    await (_db.delete(_db.messages)..where((t) => t.sessionId.equals(id))).go();
    await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
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
      cost: row.cost,
      tokensIn: row.tokensIn,
      tokensOut: row.tokensOut,
      contextTokens: row.contextTokens,
      thinkingMode: row.thinkingMode,
      reasoningEffort: row.reasoningEffort,
      ttftMs: row.ttftMs,
      tokPerSec: row.tokPerSec,
      promptCacheHitTokens: row.promptCacheHitTokens,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      archivedAt: row.archivedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.archivedAt!)
          : null,
    );
  }
}

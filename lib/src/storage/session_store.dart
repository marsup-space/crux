import 'dart:convert';

import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/session.dart';
import '../models/message.dart';
import '../models/part.dart';
import 'session_lock.dart';

class SessionStore {
  final db.CruxDatabase _db;
  final SessionLock _lock;

  SessionStore(this._db, this._lock);

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
    final id = await _db.into(_db.sessions).insert(
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
    final row = await (_db.select(_db.sessions)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
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

  Future<Session> update(
    int id, {
    String? title,
    String? model,
    SessionStatus? status,
    double? cost,
    int? tokensIn,
    int? tokensOut,
    int? contextTokens,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        model: model != null ? Value(model) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        cost: cost != null ? Value(cost) : const Value.absent(),
        tokensIn: tokensIn != null ? Value(tokensIn) : const Value.absent(),
        tokensOut: tokensOut != null ? Value(tokensOut) : const Value.absent(),
        contextTokens:
            contextTokens != null ? Value(contextTokens) : const Value.absent(),
        updatedAt: Value(nowMs),
      ),
    );
    final updated = await getById(id);
    return updated!;
  }

  Future<void> archive(int id) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(id))).write(
      db.SessionsCompanion(
        archivedAt: Value(nowMs),
        updatedAt: Value(nowMs),
      ),
    );
  }

  Future<void> delete(int id) async {
    await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
  }

  Future<Session> fork(int sessionId, {int? upToMessageId}) async {
    await _lock.acquire(sessionId);
    try {
      final source = await getById(sessionId);
      if (source == null) throw StateError('Session $sessionId not found');

      final forkCount = await _countForks(sessionId);
      final forked = await create(
        title: '${source.title} (fork #$forkCount)',
        model: source.model,
        projectPath: source.projectPath,
        agent: source.agent,
        parentId: sessionId,
      );

      final messages = await getMessages(sessionId);
      final toCopy = upToMessageId != null
          ? messages.where((m) => m.id <= upToMessageId).toList()
          : messages;

      for (final msg in toCopy) {
        final newMsg = await addMessage(
          forked.id,
          role: msg.role,
          content: msg.content,
          model: msg.model,
        );
        final parts = await getParts(msg.id);
        for (final part in parts) {
          await addPart(
            newMsg.id,
            forked.id,
            type: part.type,
            data: part.data,
          );
        }
      }

      return forked;
    } finally {
      _lock.release(sessionId);
    }
  }

  Future<int> _countForks(int parentId) async {
    final count = _db.sessions.id.count();
    final query = _db.selectOnly(_db.sessions)
      ..addColumns([count])
      ..where(_db.sessions.parentId.equals(parentId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<Message> addMessage(
    int sessionId, {
    required String role,
    required String content,
    String reasoningContent = '',
    String model = '',
    double cost = 0.0,
    int tokensIn = 0,
    int tokensOut = 0,
    String? error,
  }) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final id = await _db.into(_db.messages).insert(
          db.MessagesCompanion.insert(
            sessionId: sessionId,
            role: role,
            createdAt: nowMs,
            content: Value(content),
            reasoningContent: Value(reasoningContent),
            model: Value(model),
            cost: Value(cost),
            tokensIn: Value(tokensIn),
            tokensOut: Value(tokensOut),
            error: Value(error),
          ),
        );

    await _touchSession(sessionId);

    return Message(
      id: id,
      sessionId: sessionId,
      role: role,
      content: content,
      reasoningContent: reasoningContent,
      model: model,
      cost: cost,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      error: error,
      createdAt: now,
    );
  }

  Future<List<Message>> getMessages(
    int sessionId, {
    int limit = 1000,
    int? beforeId,
  }) async {
    final query = _db.select(_db.messages)
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
      ..limit(limit);

    if (beforeId != null) {
      query.where(
          (t) => t.sessionId.equals(sessionId) & t.id.isSmallerThanValue(beforeId));
    } else {
      query.where((t) => t.sessionId.equals(sessionId));
    }

    final rows = await query.get();
    return rows.map(_rowToMessage).toList();
  }

  Future<void> deleteMessage(int id) async {
    await (_db.delete(_db.messages)..where((t) => t.id.equals(id))).go();
  }

  Future<Part> addPart(
    int messageId,
    int sessionId, {
    required PartType type,
    Map<String, dynamic>? data,
  }) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final dataStr = jsonEncode(data ?? {});
    final id = await _db.into(_db.parts).insert(
          db.PartsCompanion.insert(
            messageId: messageId,
            sessionId: sessionId,
            type: type.name,
            createdAt: nowMs,
            data: Value(dataStr),
          ),
        );
    return Part(
      id: id,
      messageId: messageId,
      sessionId: sessionId,
      type: type,
      data: data ?? {},
      createdAt: now,
    );
  }

  Future<List<Part>> getParts(int messageId) async {
    final query = _db.select(_db.parts)
      ..where((t) => t.messageId.equals(messageId))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(_rowToPart).toList();
  }

  Future<List<Part>> getPartsBySession(int sessionId) async {
    final query = _db.select(_db.parts)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(_rowToPart).toList();
  }

  Future<void> _touchSession(int sessionId) async {
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
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      archivedAt: row.archivedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.archivedAt!)
          : null,
    );
  }

  Message _rowToMessage(db.Message row) {
    return Message(
      id: row.id,
      sessionId: row.sessionId,
      role: row.role,
      content: row.content,
      reasoningContent: row.reasoningContent,
      model: row.model,
      cost: row.cost,
      tokensIn: row.tokensIn,
      tokensOut: row.tokensOut,
      error: row.error,
      parentMsgId: row.parentMsgId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }

  Part _rowToPart(db.Part row) {
    return Part(
      id: row.id,
      messageId: row.messageId,
      sessionId: row.sessionId,
      type: PartType.values.firstWhere(
        (t) => t.name == row.type,
        orElse: () => PartType.text,
      ),
      data: Part.parseDataJson(row.data),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}

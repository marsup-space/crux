import 'dart:convert';

import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/session.dart';
import '../models/message.dart';
import '../models/part.dart';

const _unset = Object();

class SessionStore {
  final db.CruxDatabase _db;

  SessionStore(this._db);

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
    await cleanOffloadedContent(id);
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

  Future<Message> addMessage(
    int sessionId, {
    required String role,
    required String content,
    String reasoningContent = '',
    String reasoningSignature = '',
    int reasoningTokens = 0,
    int thinkingDurationMs = 0,
    String? reasoningEffort,
    String model = '',
    double cost = 0.0,
    int tokensIn = 0,
    int tokensOut = 0,
    String? error,
    List<ToolCallData> toolCalls = const [],
    String toolCallId = '',
    String tldr = '',
    int? preCompressTokens,
  }) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final id = await _db
        .into(_db.messages)
        .insert(
          db.MessagesCompanion.insert(
            sessionId: sessionId,
            role: role,
            createdAt: nowMs,
            content: Value(content),
            reasoningContent: Value(reasoningContent),
            reasoningSignature: Value(reasoningSignature),
            reasoningTokens: Value(reasoningTokens),
            thinkingDurationMs: Value(thinkingDurationMs),
            reasoningEffort: Value(reasoningEffort),
            model: Value(model),
            cost: Value(cost),
            tokensIn: Value(tokensIn),
            tokensOut: Value(tokensOut),
            error: Value(error),
            toolCalls: Value(Message.encodeToolCalls(toolCalls)),
            toolCallId: Value(toolCallId),
            tldr: Value(tldr),
            preCompressTokens: Value(preCompressTokens),
          ),
        );

    await _touchSession(sessionId);

    return Message(
      id: id,
      sessionId: sessionId,
      role: role,
      content: content,
      reasoningContent: reasoningContent,
      reasoningSignature: reasoningSignature,
      reasoningTokens: reasoningTokens,
      thinkingDurationMs: thinkingDurationMs,
      reasoningEffort: reasoningEffort,
      model: model,
      cost: cost,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      error: error,
      preCompressTokens: preCompressTokens,
      createdAt: now,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      tldr: tldr,
    );
  }

  /// Persist a `tool_call` assistant row and all of its matching
  /// `tool` result rows in a single SQLite transaction.
  ///
  /// The agentic loop in [ChatService] used to call [addMessage]
  /// once for the assistant row and again in a `for` loop for every
  /// result row. If the process died between those writes (terminal
  /// closed, OS kill, power loss, an exception thrown from a tool's
  /// result-handling code), the conversation kept the `tool_call`
  /// row but lost the matching `tool` rows — an orphan that every
  /// future replay sent to a strict provider would reject (MiniMax
  /// surfaces this as `tool call result does not follow tool call`).
  ///
  /// Wrapping both writes in [_db.transaction] makes the persist
  /// step all-or-nothing: SQLite rolls back on any failure and the
  /// next turn sees either the full round or no round at all.
  Future<Message> addToolRound(
    int sessionId, {
    String roundText = '',
    String reasoningContent = '',
    String reasoningSignature = '',
    int reasoningTokens = 0,
    int thinkingDurationMs = 0,
    String? reasoningEffort,
    required List<ToolCallData> toolCalls,
    int? preCompressTokens,
    required List<({String callId, String output})> results,
  }) {
    return _db.transaction(() async {
      final assistant = await addMessage(
        sessionId,
        role: 'tool_call',
        content: roundText,
        reasoningContent: reasoningContent,
        reasoningSignature: reasoningSignature,
        reasoningTokens: reasoningTokens,
        thinkingDurationMs: thinkingDurationMs,
        reasoningEffort: reasoningEffort,
        toolCalls: toolCalls,
        preCompressTokens: preCompressTokens,
      );
      for (final r in results) {
        await addMessage(
          sessionId,
          role: 'tool',
          content: r.output,
          toolCallId: r.callId,
        );
      }
      return assistant;
    });
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
        (t) =>
            t.sessionId.equals(sessionId) & t.id.isSmallerThanValue(beforeId),
      );
    } else {
      query.where((t) => t.sessionId.equals(sessionId));
    }

    final rows = await query.get();
    return rows.map(_rowToMessage).toList();
  }

  Future<void> _touchSession(int sessionId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.sessions)..where((t) => t.id.equals(sessionId)))
        .write(db.SessionsCompanion(updatedAt: Value(nowMs)));
  }

  Future<void> updateMessageTldr(int messageId, String tldr) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(db.MessagesCompanion(tldr: Value(tldr)));
  }

  /// Delete every message in [sessionId] whose id is `>=` [fromId].
  /// Used by `/retry` to wipe the last "round" (the user prompt plus
  /// the AI response, tool calls, and tool results that came after
  /// it) so a fresh attempt can be made. The `parts` table cascades
  /// on `messageId`, so a plain DELETE here is enough to clean up
  /// attachment rows too.
  Future<int> deleteMessagesFrom(int sessionId, int fromId) async {
    final deleted = await (_db.delete(
      _db.messages,
    )..where(
        (t) =>
            t.sessionId.equals(sessionId) & t.id.isBiggerOrEqualValue(fromId),
      ))
        .go();
    if (deleted > 0) {
      await _touchSession(sessionId);
    }
    return deleted;
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

  Future<List<Part>> addParts(
    int sessionId,
    int messageId,
    List<PartData> parts,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final results = <Part>[];
    for (final p in parts) {
      final id = await _db
          .into(_db.parts)
          .insert(
            db.PartsCompanion.insert(
              messageId: messageId,
              sessionId: sessionId,
              type: p.type.value,
              data: Value(jsonEncode(p.data)),
              createdAt: nowMs,
            ),
          );
      results.add(
        Part(
          id: id,
          messageId: messageId,
          sessionId: sessionId,
          type: p.type,
          data: p.data,
          createdAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
        ),
      );
    }
    return results;
  }

  Future<List<Part>> getPartsByMessage(int messageId) async {
    final rows = await (_db.select(
      _db.parts,
    )..where((t) => t.messageId.equals(messageId))).get();
    return rows.map(_rowToPart).toList();
  }

  Future<List<Part>> getPartsBySession(int sessionId) async {
    final rows = await (_db.select(
      _db.parts,
    )..where((t) => t.sessionId.equals(sessionId))).get();
    return rows.map(_rowToPart).toList();
  }

  Part _rowToPart(db.Part row) {
    return Part(
      id: row.id,
      messageId: row.messageId,
      sessionId: row.sessionId,
      type: PartType.values.firstWhere(
        (t) => t.value == row.type,
        orElse: () => PartType.text,
      ),
      data: Part.parseDataJson(row.data),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }

  Message _rowToMessage(db.Message row) {
    return Message(
      id: row.id,
      sessionId: row.sessionId,
      role: row.role,
      content: row.content,
      reasoningContent: row.reasoningContent,
      reasoningSignature: row.reasoningSignature,
      reasoningTokens: row.reasoningTokens,
      thinkingDurationMs: row.thinkingDurationMs,
      reasoningEffort: row.reasoningEffort,
      model: row.model,
      cost: row.cost,
      tokensIn: row.tokensIn,
      tokensOut: row.tokensOut,
      error: row.error,
      parentMsgId: row.parentMsgId,
      preCompressTokens: row.preCompressTokens,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      toolCalls: Message.parseToolCallsJson(row.toolCalls),
      toolCallId: row.toolCallId,
      tldr: row.tldr,
    );
  }

  /// Persist the full bytes of a large tool-call argument that has
  /// been off-loaded from the conversation log. The persisted
  /// tool_call's argument is replaced with a stand-in pointer;
  /// this row is the recovery target for the `recall` tool.
  Future<void> saveOffloadedContent({
    required int sessionId,
    required String callId,
    required String toolName,
    required int byteSize,
    required int lineCount,
    required String content,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _db.into(_db.offloadedContent).insert(
      db.OffloadedContentCompanion.insert(
        sessionId: sessionId,
        callId: callId,
        toolName: toolName,
        byteSize: byteSize,
        lineCount: lineCount,
        content: content,
        createdAt: nowMs,
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Return the full content for a previously off-loaded
  /// `(sessionId, callId)` pair, or `null` if the row is gone
  /// (cleaned by `/archive` → `cleanOffloadedContent`, or by a
  /// future `/compact`).
  Future<String?> getOffloadedContent(int sessionId, String callId) async {
    final row = await (_db.select(_db.offloadedContent)
          ..where(
            (t) => t.sessionId.equals(sessionId) & t.callId.equals(callId),
          ))
        .getSingleOrNull();
    return row?.content;
  }

  /// Delete every off-loaded-content row for [sessionId]. Returns
  /// the number of bytes freed (sum of `byte_size` over the deleted
  /// rows, or 0 if nothing was off-loaded). Called from
  /// `archiveSession` today; will be called from `/compact` once
  /// that lands.
  ///
  /// Note: the FK already cascades on session delete, so this
  /// method is only useful when the session *itself* survives
  /// (i.e. archive, future compact) — the cascading path handles
  /// the "session is gone" case automatically.
  Future<int> cleanOffloadedContent(int sessionId) async {
    final sumRow = await (_db.selectOnly(_db.offloadedContent)
          ..addColumns([_db.offloadedContent.byteSize.sum()])
          ..where(_db.offloadedContent.sessionId.equals(sessionId)))
        .map((row) => row.read(_db.offloadedContent.byteSize.sum()) ?? 0)
        .getSingleOrNull();
    final bytesFreed = sumRow ?? 0;
    await (_db.delete(_db.offloadedContent)
          ..where((t) => t.sessionId.equals(sessionId)))
        .go();
    return bytesFreed;
  }
}

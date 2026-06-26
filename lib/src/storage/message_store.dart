import 'dart:convert';

import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/part.dart';

/// Data-access layer for messages and parts.
///
/// Split from [SessionStore] so each class owns a single table family.
/// The [sessionStore] reference supports the `_touchSession` side-effect
/// (bumping `updated_at` when a message is written), which keeps the
/// session's sort order accurate in the sidebar without the caller
/// having to remember a separate update call.
class MessageStore {
  final db.CruxDatabase _db;

  /// Used by [addMessage] / [addToolRound] / [deleteMessagesFrom] to
  /// bump the parent session's `updated_at` so the sidebar re-sorts.
  /// Set after construction to avoid a circular dependency.
  late final SessionStoreAccessor sessionStore;

  MessageStore(this._db);

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
    int tokensIn = 0,
    int tokensOut = 0,
    String? error,
    List<ToolCallData> toolCalls = const [],
    String toolCallId = '',
    String tldr = '',
    List<ImageAttachment> images = const [],
    int parallelCount = 0,
    String meta = '',
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
            tokensIn: Value(tokensIn),
            tokensOut: Value(tokensOut),
            error: Value(error),
            toolCalls: Value(Message.encodeToolCalls(toolCalls)),
            toolCallId: Value(toolCallId),
            tldr: Value(tldr),
            images: Value(ImageAttachment.encodeList(images)),
            parallelCount: Value(parallelCount),
            meta: Value(meta),
          ),
        );

    await sessionStore.touchSession(sessionId);

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
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      error: error,
      createdAt: now,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      tldr: tldr,
      images: images,
      parallelCount: parallelCount,
      meta: meta,
    );
  }

  /// Persist a `tool_call` assistant row and all of its matching
  /// `tool` result rows in a single SQLite transaction.
  ///
  /// Wrapping both writes in [_db.transaction] makes the persist
  /// step all-or-nothing: SQLite rolls back on any failure and the
  /// next turn sees either the full round or no round at all.
  ///
  /// Each [results] entry's `meta` (if non-empty) is persisted on
  /// the tool row alongside `output`. The meta is read by the
  /// chat-history bubble renderer; it is **not** part of what the
  /// LLM sees — the LLM only ever receives `output`.
  Future<Message> addToolRound(
    int sessionId, {
    String roundText = '',
    String reasoningContent = '',
    String reasoningSignature = '',
    int reasoningTokens = 0,
    int thinkingDurationMs = 0,
    String? reasoningEffort,
    required List<ToolCallData> toolCalls,
    required List<({String callId, String output, String meta})> results,
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
      );
      for (final r in results) {
        await addMessage(
          sessionId,
          role: 'tool',
          content: r.output,
          toolCallId: r.callId,
          meta: r.meta,
        );
      }
      return assistant;
    });
  }

  /// Number of messages in [sessionId]. Used by the `session` tool to
  /// render the message-count column on a `list` and to bound the
  /// "showing N of M" hint on a `show`.
  Future<int> countBySession(int sessionId) async {
    final count = countAll();
    final query = _db.selectOnly(_db.messages)
      ..addColumns([count])
      ..where(_db.messages.sessionId.equals(sessionId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Count for each session in [sessionIds] in a single query. Returns
  /// an empty map for an empty input. Missing sessions map to 0.
  ///
  /// Used by the `session list` action — fetching N sessions and then
  /// N separate `countBySession` round-trips is wasteful, so we batch.
  Future<Map<int, int>> countBySessions(List<int> sessionIds) async {
    if (sessionIds.isEmpty) return const {};
    final count = countAll();
    final query = _db.selectOnly(_db.messages)
      ..addColumns([count, _db.messages.sessionId])
      ..where(_db.messages.sessionId.isIn(sessionIds))
      ..groupBy([_db.messages.sessionId]);
    final rows = await query.get();
    final result = <int, int>{for (final id in sessionIds) id: 0};
    for (final row in rows) {
      final sid = row.read(_db.messages.sessionId);
      final c = row.read(count);
      if (sid != null && c != null) result[sid] = c;
    }
    return result;
  }

  /// Returns up to [limit] messages for [sessionId] in chronological
  /// order (oldest first).
  ///
  /// The default call (no [beforeId]) returns the **latest** `limit`
  /// messages — i.e. the tail of the session. To read further back in
  /// time, pass `beforeId` = the smallest id from the previous page
  /// (i.e. the first id in the returned list). That walks the session
  /// backwards one page at a time. The returned list is always in
  /// chronological order so callers can render it directly.
  ///
  /// Implementation note: SQL orders by `id DESC` so the LIMIT slices
  /// off the most-recent N rows; we then reverse in memory to put them
  /// back in chronological order. Ordering by `id` (the auto-increment
  /// primary key) is monotonic and stable, which is exactly what the
  /// `beforeId` pagination cursor needs.
  Future<List<Message>> getMessages(
    int sessionId, {
    int limit = 1000,
    int? beforeId,
  }) async {
    final query = _db.select(_db.messages)
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
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
    final result = rows.map(_rowToMessage).toList();
    return result.reversed.toList();
  }

  Future<void> updateMessageTldr(int messageId, String tldr) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(db.MessagesCompanion(tldr: Value(tldr)));
  }

  Future<void> updateMessage(
    int messageId, {
    String? content,
    String? meta,
    String? error,
  }) async {
    await (_db.update(
      _db.messages,
    )..where((t) => t.id.equals(messageId))).write(
      db.MessagesCompanion(
        content: content != null ? Value(content) : const Value.absent(),
        meta: meta != null ? Value(meta) : const Value.absent(),
        error: error != null ? Value(error) : const Value.absent(),
      ),
    );
  }

  /// Delete every message in [sessionId] whose id is `>=` [fromId].
  /// Used by `/retry` to wipe the last "round" (the user prompt plus
  /// the AI response, tool calls, and tool results that came after
  /// it) so a fresh attempt can be made. The `parts` table cascades
  /// on `messageId`, so a plain DELETE here is enough to clean up
  /// attachment rows too.
  Future<int> deleteMessagesFrom(int sessionId, int fromId) async {
    final deleted =
        await (_db.delete(_db.messages)..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.id.isBiggerOrEqualValue(fromId),
            ))
            .go();
    if (deleted > 0) {
      await sessionStore.touchSession(sessionId);
    }
    return deleted;
  }

  /// Delete every `status: 'complete'` compaction message in
  /// [sessionId]. Used by the chat-log compaction path's
  /// "replace from scratch" model: each new compact builds a
  /// fresh chat log from the full non-compaction history, so
  /// the prior `compaction`-role messages are no longer needed
  /// (their content has been folded into the new one).
  ///
  /// In-progress compactions (the `status: 'compacting'` marker
  /// written at the start of [ChatService.createChatLogCompaction]
  /// before the actual rebuild) are NOT touched here — they
  /// represent a half-finished write and are reaped by the
  /// `try { ... } catch { mark 'failed' }` block in
  /// createChatLogCompaction when the next compact runs.
  Future<int> deleteCompleteCompactions(int sessionId) async {
    final rows = await (_db.select(_db.messages)
          ..where((t) =>
              t.sessionId.equals(sessionId) &
              t.role.equals('compaction')))
        .get();
    var deleted = 0;
    for (final row in rows) {
      // Mirror ChatService._isCompleteCompactionMessage: empty
      // or unparseable meta is treated as complete (the only
      // sentinel is the literal `status: 'compacting'`).
      if (row.meta.isEmpty) {
        await (_db.delete(_db.messages)..where((t) => t.id.equals(row.id))).go();
        deleted++;
        continue;
      }
      bool isComplete = true;
      try {
        final decoded = jsonDecode(row.meta);
        if (decoded is Map<String, dynamic>) {
          isComplete = (decoded['status'] as String? ?? 'complete') == 'complete';
        }
      } catch (_) {
        isComplete = true;
      }
      if (isComplete) {
        await (_db.delete(_db.messages)..where((t) => t.id.equals(row.id))).go();
        deleted++;
      }
    }
    if (deleted > 0) {
      await sessionStore.touchSession(sessionId);
    }
    return deleted;
  }

  // ── Parts ────────────────────────────────────────────────────────

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

  // ── Row mappers ──────────────────────────────────────────────────

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
      tokensIn: row.tokensIn,
      tokensOut: row.tokensOut,
      error: row.error,
      parentMsgId: row.parentMsgId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      toolCalls: Message.parseToolCallsJson(row.toolCalls),
      toolCallId: row.toolCallId,
      tldr: row.tldr,
      images: ImageAttachment.decodeList(row.images),
      parallelCount: row.parallelCount,
      meta: row.meta,
    );
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
}

/// Thin interface that [SessionStore] implements so [MessageStore]
/// can bump `updated_at` without taking a direct dependency on the
/// full [SessionStore] class (avoids a circular import).
abstract class SessionStoreAccessor {
  Future<void> touchSession(int sessionId);
}

import 'dart:convert';

import 'package:drift/drift.dart';
import 'database.dart' as db;
import '../models/daily_usage_stats.dart';
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
    String model = '',
    int tokensIn = 0,
    int tokensOut = 0,
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
        model: model,
        tokensIn: tokensIn,
        tokensOut: tokensOut,
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

  /// Total tokens (in + out) per local calendar day, for the home
  /// screen's activity heatmap.
  ///
  /// Returns a map from `'YYYY-MM-DD'` (local time) to the summed token
  /// count. Only AI/tool_call rows carry token counts, but summing all
  /// rows is equivalent (other roles persist 0) and avoids a role
  /// filter. [sinceDaysAgo] bounds the window (e.g. 371 for a year +
  /// partial week); pass [projectPath] to scope to one workspace.
  ///
  /// `created_at` is stored as local epoch-ms, so
  /// `date(created_at/1000, 'unixepoch', 'localtime')` buckets by the
  /// user's own midnight — matching how the heatmap renders days.
  Future<Map<String, int>> dailyTokenTotals({
    required int sinceDaysAgo,
    String? projectPath,
  }) async {
    final sinceMs = DateTime.now()
        .subtract(Duration(days: sinceDaysAgo))
        .millisecondsSinceEpoch;
    final offset = _sqliteUtcOffsetModifier(DateTime.now().timeZoneOffset);
    final variables = <Variable<Object>>[Variable.withInt(sinceMs)];
    var projectFilter = '';
    if (projectPath != null) {
      projectFilter = 'AND s.project_path = ?';
      variables.add(Variable.withString(projectPath));
    }
    final rows = await _db
        .customSelect(
          "SELECT COALESCE("
          "date(m.created_at / 1000, 'unixepoch', 'localtime'), "
          "date(m.created_at / 1000, 'unixepoch', '$offset')) "
          'AS day, '
          'SUM(m.tokens_in + m.tokens_out) AS total '
          'FROM messages m '
          'JOIN sessions s ON s.id = m.session_id '
          'WHERE m.created_at >= ? $projectFilter '
          'GROUP BY day',
          variables: variables,
          readsFrom: {_db.messages, _db.sessions},
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('day'): row.read<int>('total'),
    };
  }

  /// Per-local-day usage stats for the home screen's `today` box: total
  /// tokens, conversation turns (`role: 'user'` messages), and the
  /// number of distinct sessions that had activity that day. Each day
  /// also carries a per-model token breakdown ([DailyUsageStats.byModel],
  /// from a second `GROUP BY day, model` aggregate) for the box's bar
  /// chart.
  ///
  /// Returns a map from `'YYYY-MM-DD'` (local time) to a
  /// [DailyUsageStats]. [sinceDaysAgo] bounds the window (e.g. 371 for a
  /// year + partial week); pass [projectPath] to scope to one workspace
  /// (chats have an empty `project_path`, so they drop out of a
  /// project-scoped query — matching [dailyTokenTotals]).
  ///
  /// `created_at` is stored as local epoch-ms, so
  /// `date(created_at/1000, 'unixepoch', 'localtime')` buckets by the
  /// user's own midnight.
  Future<Map<String, DailyUsageStats>> dailyUsageStats({
    required int sinceDaysAgo,
    String? projectPath,
  }) async {
    final sinceMs = DateTime.now()
        .subtract(Duration(days: sinceDaysAgo))
        .millisecondsSinceEpoch;
    final offset = _sqliteUtcOffsetModifier(DateTime.now().timeZoneOffset);
    final variables = <Variable<Object>>[Variable.withInt(sinceMs)];
    var projectFilter = '';
    if (projectPath != null) {
      projectFilter = 'AND s.project_path = ?';
      variables.add(Variable.withString(projectPath));
    }
    final rows = await _db
        .customSelect(
          "SELECT COALESCE("
          "date(m.created_at / 1000, 'unixepoch', 'localtime'), "
          "date(m.created_at / 1000, 'unixepoch', '$offset')) "
          'AS day, '
          'SUM(m.tokens_in + m.tokens_out) AS tokens, '
          "SUM(CASE WHEN m.role = 'user' THEN 1 ELSE 0 END) AS turns, "
          'COUNT(DISTINCT m.session_id) AS sessions '
          'FROM messages m '
          'JOIN sessions s ON s.id = m.session_id '
          'WHERE m.created_at >= ? $projectFilter '
          'GROUP BY day',
          variables: variables,
          readsFrom: {_db.messages, _db.sessions},
        )
        .get();

    // Per-day × per-model totals (same filters as the day aggregate).
    // Only models with a nonzero sum are kept — empty-string model ids
    // (user/tool rows and legacy data) carry no tokens of their own.
    // `model` is fully qualified in GROUP BY/HAVING: both `messages`
    // and `sessions` carry a `model` column, so a bare `model` is an
    // ambiguous reference and SQLite rejects the statement outright.
    final modelRows = await _db
        .customSelect(
          "SELECT COALESCE("
          "date(m.created_at / 1000, 'unixepoch', 'localtime'), "
          "date(m.created_at / 1000, 'unixepoch', '$offset')) "
          'AS day, '
          'm.model AS model, '
          'SUM(m.tokens_in + m.tokens_out) AS tokens '
          'FROM messages m '
          'JOIN sessions s ON s.id = m.session_id '
          "WHERE m.created_at >= ? AND m.model != '' $projectFilter "
          'GROUP BY day, m.model '
          'HAVING tokens > 0',
          variables: variables,
          readsFrom: {_db.messages, _db.sessions},
        )
        .get();
    // day → model → tokens.
    final byModel = <String, Map<String, int>>{};
    for (final row in modelRows) {
      byModel
          .putIfAbsent(row.read<String>('day'), () => {})
          [row.read<String>('model')] = row.read<int>('tokens');
    }

    return {
      for (final row in rows)
        row.read<String>('day'): DailyUsageStats(
          tokens: row.read<int>('tokens'),
          turns: row.read<int>('turns'),
          sessions: row.read<int>('sessions'),
          byModel: byModel[row.read<String>('day')] ?? const {},
        ),
    };
  }

  /// SQLite's `localtime` modifier can return NULL in a Windows background
  /// isolate because the embedded runtime has no usable local-time callback.
  /// Keep it as the preferred path (it handles historical DST), then fall
  /// back to Dart's current UTC offset so day aggregation still works rather
  /// than leaving the Home widgets permanently in their loading state.
  static String _sqliteUtcOffsetModifier(Duration offset) {
    final negative = offset.isNegative;
    final minutes = offset.inMinutes.abs();
    final hoursPart = (minutes ~/ 60).toString().padLeft(2, '0');
    final minutesPart = (minutes % 60).toString().padLeft(2, '0');
    return '${negative ? '-' : '+'}$hoursPart:$minutesPart';
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
  /// it) so a fresh attempt can be made. The attached `parts` rows
  /// are removed by the `ON DELETE CASCADE` on `Parts.messageId` —
  /// which only fires on connections with `PRAGMA foreign_keys=ON`.
  /// The production connection setup enables that pragma (see
  /// database.dart); executors that don't set it (e.g. a bare
  /// in-memory test database) leave the `parts` rows behind.
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
  /// Delete every `stream_error` row for [sessionId]. Called at the
  /// start of every new turn (user message, /continue, /retry) so
  /// the persisted error bubble from a previous failed attempt
  /// disappears before the new attempt begins. The next attempt's
  /// success hides it naturally; its failure is surfaced by a
  /// fresh bubble written by [ChatTurnOrchestrator].
  ///
  /// Returns the count deleted (zero is normal — no prior error
  /// bubble, or one already cleared by a prior new turn).
  Future<int> clearStreamErrorsFor(int sessionId) async {
    final deleted =
        await (_db.delete(_db.messages)..where(
              (t) =>
                  t.sessionId.equals(sessionId) & t.role.equals('stream_error'),
            ))
            .go();
    if (deleted > 0) {
      await sessionStore.touchSession(sessionId);
    }
    return deleted;
  }

  /// Storage-side counterpart to
  /// [AnthropicCompatibleProvider._enforceToolUsePairing]. Walks
  /// the session's `tool_call` and `tool` rows and removes the
  /// orphans the per-request sanitizer would otherwise strip at
  /// wire-format time:
  ///
  ///   - `tool_call` rows (the assistant message announcing one
  ///     or more `tool_use` blocks) lose entries whose `callId`
  ///     no subsequent `tool` row references. A `tool_call` row
  ///     whose `toolCalls` become empty after pruning is deleted
  ///     entirely — an empty tool_call assistant message is
  ///     meaningless and would re-trigger the same orphan error
  ///     on the next request.
  ///   - `tool` rows (the persisted result for a single
  ///     `tool_use`) are deleted when their `toolCallId` doesn't
  ///     appear in any preceding `tool_call` row, or when the
  ///     preceding `tool_call` row's flow has been terminated by
  ///     a `user` or `ai` message that came in before the result
  ///     was written (the canonical interrupted-round symptom).
  ///
  /// The walk is in id (chronological) order. A regular `user`,
  /// `ai`, or any other role in between `tool_call` and its
  /// `tool` results terminates the pending flow — those orphan
  /// `tool_use` ids and any `tool` rows whose flow has been
  /// terminated this way are both pruned.
  ///
  /// A `tool_call` row whose `toolCalls` JSON fails to parse is
  /// skipped entirely: it neither terminates the pending flow
  /// (its announced ids are unknowable) nor is itself pruned.
  /// Only rows that parse cleanly are eligible for repair.
  ///
  /// Runs in a single transaction so a failure in the middle of
  /// the walk leaves the DB unchanged. Returns the total number
  /// of rows modified (each deleted `tool_call` counts as 1,
  /// each deleted `tool` counts as 1; an updated `tool_call`
  /// row with at least one entry pruned also counts as 1 — so
  /// the same row can contribute at most 1 per kind, not per
  /// entry). A well-formed history returns 0 and is the
  /// expected common case.
  ///
  /// Used by the chat executor's auto-repair-and-retry hook on
  /// the first occurrence of an orphan-tool-use error per round.
  /// Gated on `LlmProvider.supportsOrphanToolRepair` — only
  /// Anthropic-compatible providers invoke this, mirroring the
  /// wire-format sanitizer on the Anthropic side.
  Future<int> repairOrphanToolRows(int sessionId) async {
    var modifiedCount = 0;

    await _db.transaction(() async {
      // Pull the rows we care about, in chronological order.
      // Reading only the columns we need keeps the snapshot
      // small for sessions with many messages.
      final toolRows =
          await (_db.select(_db.messages)
                ..where(
                  (t) =>
                      t.sessionId.equals(sessionId) &
                      (t.role.equals('tool_call') |
                          t.role.equals('tool') |
                          t.role.equals('ai') |
                          t.role.equals('user') |
                          t.role.equals('system') |
                          t.role.equals('compaction') |
                          t.role.equals('parallel_praise') |
                          t.role.equals('single_call_reminder')),
                )
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get();

      // ── Pass 1: identify orphan tool_use ids ────────────────────
      //
      // The walk mirrors
      // AnthropicCompatibleProvider._enforceToolUsePairing on the
      // Anthropic wire family: tool_call rows push ids onto
      // pending; tool rows match against pending; anything else
      // (ai / user / system / etc.) terminates the pending flow.
      // Unmatched ids and unprovoked tool rows become orphans.
      final orphanUseIds = <String>{};
      Set<String>? pending;

      for (final row in toolRows) {
        final role = row.role;
        if (role == 'tool_call') {
          final calls = _tryParseToolCalls(row.toolCalls);
          if (calls == null) {
            // Corrupt toolCalls JSON: skip the row entirely. It
            // must NOT terminate the pending flow — we can't know
            // which ids it announced, so treating it as an empty
            // terminator would wrongly orphan the previous flow's
            // unanswered ids (and pass 2 would then prune rows
            // based on that misreading). The row itself is left
            // untouched in pass 2 as well.
            continue;
          }
          final ids = <String>{};
          for (final c in calls) {
            ids.add(c.callId);
          }
          if (ids.isNotEmpty) {
            // A new tool_call supersedes the previous pending
            // flow without answering it — that previous flow's
            // unresponded-to ids are orphan by definition.
            if (pending != null) orphanUseIds.addAll(pending);
            pending = ids;
          } else {
            // tool_call row with no toolCalls is meaningless;
            // treat it like an ai row (terminates pending).
            if (pending != null) {
              orphanUseIds.addAll(pending);
              pending = null;
            }
          }
        } else if (role == 'tool') {
          if (pending == null || !pending.remove(row.toolCallId)) {
            // Either there's no preceding tool_call announcing
            // this id, or the preceding flow has already been
            // terminated by an intervening message. Either way:
            // orphan.
            if (row.toolCallId.isNotEmpty) {
              orphanUseIds.add(row.toolCallId);
            } else {
              // tool row with no toolCallId — used as a fallback
              // marker only; we still want to clean it up.
              orphanUseIds.add('__orphan_no_id_${row.id}__');
            }
          }
        } else {
          // ai / user / system / compaction / parallel_praise /
          // single_call_reminder all terminate the pending tool
          // flow (a regular user message sandwiched between a
          // tool_call and its tools is the canonical interrupted
          // round).
          if (pending != null) {
            orphanUseIds.addAll(pending);
            pending = null;
          }
        }
      }
      // End of input — anything still pending never got its
      // results written.
      if (pending != null) orphanUseIds.addAll(pending);

      if (orphanUseIds.isEmpty) return;

      // ── Pass 2: prune the DB ────────────────────────────────────
      //
      // For each row whose ids touch the orphan set, either
      // update with the kept ids or delete the whole row.
      for (final row in toolRows) {
        if (row.role == 'tool_call') {
          final calls = _tryParseToolCalls(row.toolCalls);
          // Unreadable rows were skipped in pass 1, so none of
          // their ids can be in the orphan set — leave them alone
          // rather than guessing.
          if (calls == null || calls.isEmpty) continue;
          final kept = calls
              .where((c) => !orphanUseIds.contains(c.callId))
              .toList();
          if (kept.length == calls.length) continue;
          if (kept.isEmpty) {
            await (_db.delete(
              _db.messages,
            )..where((t) => t.id.equals(row.id))).go();
            modifiedCount++;
          } else {
            await (_db.update(
              _db.messages,
            )..where((t) => t.id.equals(row.id))).write(
              db.MessagesCompanion(
                toolCalls: Value(Message.encodeToolCalls(kept)),
              ),
            );
            modifiedCount++;
          }
        } else if (row.role == 'tool') {
          if (orphanUseIds.contains(row.toolCallId) ||
              orphanUseIds.contains('__orphan_no_id_${row.id}__')) {
            await (_db.delete(
              _db.messages,
            )..where((t) => t.id.equals(row.id))).go();
            modifiedCount++;
          }
        }
      }
    });

    if (modifiedCount > 0) {
      await sessionStore.touchSession(sessionId);
    }
    return modifiedCount;
  }

  /// Parse a `messages.tool_calls` payload, returning `null` when
  /// the JSON is corrupt (as opposed to a legitimately empty list,
  /// which yields `[]`). [repairOrphanToolRows] uses this to tell
  /// "row announces no calls" apart from "row can't be read" —
  /// [Message.parseToolCallsJson] deliberately collapses both into
  /// an empty list for UI rendering, which is the wrong signal for
  /// a repair walk.
  static List<ToolCallData>? _tryParseToolCalls(String json) {
    if (json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => ToolCallData.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<int> deleteCompleteCompactions(int sessionId) async {
    var deleted = 0;
    // Read + deletes in a single transaction. The compaction
    // caller inserts the replacement message immediately after
    // this returns, so a half-applied delete (or a concurrent
    // write landing between the read and the deletes) must not
    // leave the session with duplicate or missing compaction rows.
    await _db.transaction(() async {
      final rows =
          await (_db.select(_db.messages)..where(
                (t) =>
                    t.sessionId.equals(sessionId) & t.role.equals('compaction'),
              ))
              .get();
      for (final row in rows) {
        // Mirror ChatService._isCompleteCompactionMessage: empty
        // or unparseable meta is treated as complete (the only
        // sentinel is the literal `status: 'compacting'`).
        if (row.meta.isEmpty) {
          await (_db.delete(
            _db.messages,
          )..where((t) => t.id.equals(row.id))).go();
          deleted++;
          continue;
        }
        bool isComplete = true;
        try {
          final decoded = jsonDecode(row.meta);
          if (decoded is Map<String, dynamic>) {
            isComplete =
                (decoded['status'] as String? ?? 'complete') == 'complete';
          }
        } catch (_) {
          isComplete = true;
        }
        if (isComplete) {
          await (_db.delete(
            _db.messages,
          )..where((t) => t.id.equals(row.id))).go();
          deleted++;
        }
      }
    });
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

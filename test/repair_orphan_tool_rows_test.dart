// Tests for `MessageStore.repairOrphanToolRows` — the storage-side
// counterpart to `AnthropicCompatibleProvider._enforceToolUsePairing`.
//
// The repair walks a session's `tool_call` and `tool` rows, finds
// orphans (tool_use ids with no matching tool result; tool results
// whose preceding tool_call flow has been terminated), and prunes
// them. The chat executor's auto-repair-and-retry hook invokes this
// on the first occurrence of an orphan-tool-use error per round,
// gated on `LlmProvider.supportsOrphanToolRepair`.
//
// These tests exercise the repair logic in isolation against a
// real in-memory Drift database, mirroring
// `AnthropicCompatibleProvider._enforceToolUsePairing`'s walk.

import 'package:crux/src/models/message.dart';
import 'package:crux/src/storage/message_store.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

Future<SessionStore> _freshStore() async {
  final db = CruxDatabase.forTesting(NativeDatabase.memory());
  final store = SessionStore(db);
  addTearDown(db.close);
  return store;
}

Future<int> _createSession(SessionStore store) async {
  final session = await store.create(
    title: 'repair-test',
    model: 'minimax/MiniMax-M3',
    projectPath: '/tmp',
  );
  return session.id;
}

void main() {
  group('MessageStore.repairOrphanToolRows', () {
    late SessionStore store;
    late int sessionId;
    late MessageStore messages;

    setUp(() async {
      store = await _freshStore();
      sessionId = await _createSession(store);
      messages = store.messageStore;
    });

    test('returns 0 on a session with no tool history', () async {
      // Sanity: well-formed empty history must be a true no-op so
      // the executor doesn't surface a "repaired N rows" toast on
      // a pristine session.
      await messages.addMessage(sessionId, role: 'user', content: 'hi');
      await messages.addMessage(sessionId, role: 'ai', content: 'hello');

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, 0);

      final all = await messages.getMessages(sessionId);
      expect(
        all,
        hasLength(2),
        reason: 'no rows should be modified on a clean history',
      );
    });

    test('returns 0 on a well-formed round', () async {
      // Common case from a completed, persisted round: tool_call
      // announces ids {a, b}; tool rows for both follow. The
      // per-request sanitizer would also pass this through, so the
      // DB repair is a no-op.
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [
          ToolCallData(callId: 'a', name: 'read', input: {}),
          ToolCallData(callId: 'b', name: 'grep', input: {}),
        ],
        results: [
          (callId: 'a', output: 'file contents', meta: ''),
          (callId: 'b', output: 'match', meta: ''),
        ],
      );

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, 0);

      final all = await messages.getMessages(sessionId);
      expect(all.map((m) => m.role).toList(), [
        'user',
        'tool_call',
        'tool',
        'tool',
      ]);
    });

    test('drops orphan tool_use entries from a tool_call row', () async {
      // Mid-round interrupt: tool_call announced {a, b, c} but
      // only tool(a) and tool(b) got persisted. tool(c) was lost
      // (kill -9, hot reload, etc.). The repair must prune 'c'
      // from the tool_call row's `toolCalls` JSON — and keep the
      // row, since 'a' and 'b' are still well-formed.
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [
          ToolCallData(callId: 'a', name: 'read', input: {'p': '/a'}),
          ToolCallData(callId: 'b', name: 'grep', input: {'q': 'b'}),
          ToolCallData(callId: 'c', name: 'grep', input: {'q': 'c'}),
        ],
        results: [
          (callId: 'a', output: 'a-contents', meta: ''),
          (callId: 'b', output: 'b-match', meta: ''),
          // No result for 'c'.
        ],
      );

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, greaterThan(0), reason: 'one or more rows must change');

      // After repair: orphan 'c' is gone, well-formed pairs survive.
      final all = await messages.getMessages(sessionId);
      // tool_call row should still exist (a + b kept the row alive).
      final toolCallRow = all.firstWhere((m) => m.role == 'tool_call');
      expect(toolCallRow.toolCalls.map((c) => c.callId).toList(), [
        'a',
        'b',
      ], reason: "orphan 'c' must be pruned from the tool_call row");
      // Both surviving tool rows stay.
      final toolRows = all.where((m) => m.role == 'tool').toList();
      expect(toolRows, hasLength(2));
      expect(toolRows.map((m) => m.toolCallId).toSet(), {'a', 'b'});
    });

    test('deletes a tool_call row whose every tool_use is orphan', () async {
      // Total mid-round interrupt: tool_call announced {a}, but
      // the round aborted before any tool result landed, then a
      // new user message came in. The assistant message with no
      // surviving tool_use is meaningless and must be deleted
      // entirely (an empty tool_call row in chat history looks
      // broken).
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [ToolCallData(callId: 'a', name: 'read', input: {})],
        results: [],
      );
      await messages.addMessage(sessionId, role: 'user', content: 'never mind');

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, 1, reason: 'one row (the tool_call) must be deleted');

      final all = await messages.getMessages(sessionId);
      // Only the two user rows survive.
      expect(all.map((m) => m.role).toList(), ['user', 'user']);
    });

    test('deletes orphan tool rows (no preceding tool_call id)', () async {
      // A tool row whose toolCallId references a tool_use that
      // never got persisted (or has already been pruned by an
      // earlier repair) — Anthropic rejects tool_results that
      // don't follow a matching tool_use.
      await messages.addMessage(
        sessionId,
        role: 'tool',
        content: 'orphan result',
        toolCallId: 'nonexistent_call_id',
      );

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, 1, reason: 'one orphan tool row must be deleted');

      final all = await messages.getMessages(sessionId);
      expect(all, isEmpty);
    });

    test('terminates pending on intervening ai row', () async {
      // The canonical interrupted round: tool_call announces
      // {a, b}; tools begin to execute; before all results
      // land, an ai turn starts (e.g. the model streamed text
      // first). The 'b' tool_use is left dangling — the repair
      // prunes the dangling tool_use from the assistant row's
      // toolCalls (and any future `tool` row referencing 'b'
      // would be orphan in turn).
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [
          ToolCallData(callId: 'a', name: 'read', input: {}),
          ToolCallData(callId: 'b', name: 'grep', input: {}),
        ],
        results: [(callId: 'a', output: 'a-contents', meta: '')],
      );
      await messages.addMessage(sessionId, role: 'ai', content: 'half-thought');

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, greaterThan(0));

      final all = await messages.getMessages(sessionId);
      final toolCallRow = all.firstWhere((m) => m.role == 'tool_call');
      expect(toolCallRow.toolCalls.map((c) => c.callId).toList(), [
        'a',
      ], reason: "'b' is dropped — its tool_use is interrupted");
      // The ai row survives unchanged.
      final aiRows = all.where((m) => m.role == 'ai').toList();
      expect(aiRows.map((m) => m.content).toList(), ['half-thought']);
    });

    test('runs idempotently — well-formed history is a no-op', () async {
      // Double-invocation shouldn't mutate anything the second
      // time; the repair must converge on a stable state.
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [
          ToolCallData(callId: 'a', name: 'read', input: {}),
          ToolCallData(callId: 'b', name: 'grep', input: {}),
        ],
        results: [
          (callId: 'a', output: 'a', meta: ''),
          (callId: 'b', output: 'b', meta: ''),
        ],
      );

      final first = await messages.repairOrphanToolRows(sessionId);
      final second = await messages.repairOrphanToolRows(sessionId);
      expect(first, 0);
      expect(second, 0);
    });

    test(
      'multi-round session: only orphans in the broken round are touched',
      () async {
        // A real session looks like:
        //   user: do X
        //   tool_call(announced a) → tool(a)
        //   ai: result of X
        //   user: do Y (new prompt)
        //   tool_call(announced b, c) → tool(b) — interrupted
        //   user: ok fine
        // The first round is well-formed; only the second round
        // has the orphan ('c'). The repair should leave the first
        // round alone and prune 'c' from the second.
        await messages.addMessage(sessionId, role: 'user', content: 'do X');
        await messages.addToolRound(
          sessionId,
          toolCalls: [ToolCallData(callId: 'a', name: 'read', input: {})],
          results: [(callId: 'a', output: 'X-result', meta: '')],
        );
        await messages.addMessage(sessionId, role: 'ai', content: 'X done');
        await messages.addMessage(sessionId, role: 'user', content: 'do Y');
        await messages.addToolRound(
          sessionId,
          toolCalls: [
            ToolCallData(callId: 'b', name: 'grep', input: {'q': 'b'}),
            ToolCallData(callId: 'c', name: 'grep', input: {'q': 'c'}),
          ],
          results: [
            (callId: 'b', output: 'b-match', meta: ''),
            // 'c' missing — interrupted.
          ],
        );
        await messages.addMessage(sessionId, role: 'user', content: 'ok fine');

        final n = await messages.repairOrphanToolRows(sessionId);
        expect(n, greaterThan(0));

        final all = await messages.getMessages(sessionId);
        final toolCallRows = all.where((m) => m.role == 'tool_call').toList();
        expect(toolCallRows, hasLength(2));
        // First round (well-formed): toolCall(a) still intact.
        expect(toolCallRows[0].toolCalls.map((c) => c.callId).toList(), ['a']);
        // Second round (repaired): only 'b' remains.
        expect(toolCallRows[1].toolCalls.map((c) => c.callId).toList(), ['b']);
      },
    );

    test('end-of-input terminates still-pending flow', () async {
      // The DB ends with a tool_call whose tool_use never got a
      // tool result (e.g. the session was aborted mid-round with
      // only the assistant row persisted). The repair must treat
      // this as orphan — there are no more messages coming, so
      // the pending tool_use ids are unrecoverable.
      await messages.addMessage(sessionId, role: 'user', content: 'do it');
      await messages.addToolRound(
        sessionId,
        toolCalls: [ToolCallData(callId: 'a', name: 'read', input: {})],
        results: [],
      );

      final n = await messages.repairOrphanToolRows(sessionId);
      expect(n, 1, reason: 'one tool_call row must be deleted');

      final all = await messages.getMessages(sessionId);
      // tool_call gone — only the user prompt survives.
      expect(all.map((m) => m.role).toList(), ['user']);
    });
  });
}

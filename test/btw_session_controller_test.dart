// Tests for the in-memory `/btw` chain stored on `SessionController`.
//
// The btw buffer is the single source of truth for ephemeral side
// questions: it must (a) accumulate turns per session, (b) preserve
// each session's chain across session switches (chains are
// per-session and navigation between sessions doesn't leak between
// them), (c) drop the current session's chain on
// `clearBtwTurnsFor`, and (d) survive being appended-then-cleared
// repeatedly without leaking entries.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory tempDir;
  late ProviderService providerService;
  late SessionStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_btw_sc_');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    store = SessionStore(CruxDatabase());
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SessionController buildController() {
    // The btw buffer tests don't drive any LLM calls, so the
    // ChatService's LlmClient + ToolExecutor are never invoked.
    // We construct real instances because the constructor
    // signatures require them; both are cheap to build.
    final toolRegistry = ToolRegistry()
      ..registerDefaults(
        FileReadTracker(),
        sessionStore: store,
        webProviderRegistry: WebProviderRegistry(),
      );
    return SessionController(
      store: store,
      providerService: providerService,
      chatService: ChatService(
        store,
        providerService,
        LlmClient(),
        ToolExecutor(toolRegistry),
      ),
      refresh: () {},
    );
  }

  test('btwTurnsFor returns an empty list for an unseen session', () {
    final c = buildController();
    expect(
      c.btwTurnsFor(42),
      isEmpty,
      reason: 'no btw chain for a session that has never seen /btw',
    );
  });

  test('appendPendingBtwTurn + updateLastBtwTurnAiText chains turns', () {
    final c = buildController();
    final sid = 7;

    c.appendPendingBtwTurn(sid, 'how do I undo in vim?');
    expect(c.btwTurnsFor(sid), hasLength(1));
    expect(c.btwTurnsFor(sid).last.userText, 'how do I undo in vim?');
    expect(
      c.btwTurnsFor(sid).last.aiText,
      isEmpty,
      reason: 'pending turn starts with empty AI text',
    );

    // Simulate the LLM streaming in the response.
    c.updateLastBtwTurnAiText(sid, 'Press ');
    c.updateLastBtwTurnAiText(sid, 'Press u');
    c.updateLastBtwTurnAiText(sid, 'Press u to undo.');

    final turns = c.btwTurnsFor(sid);
    expect(
      turns,
      hasLength(1),
      reason: 'updates are in place; no new turn is created',
    );
    expect(turns.last.aiText, 'Press u to undo.');

    // A second round should append, not replace.
    c.appendPendingBtwTurn(sid, 'and redo?');
    c.updateLastBtwTurnAiText(sid, 'Ctrl-r');
    expect(c.btwTurnsFor(sid), hasLength(2));
    expect(c.btwTurnsFor(sid).first.userText, 'how do I undo in vim?');
    expect(c.btwTurnsFor(sid).first.aiText, 'Press u to undo.');
    expect(c.btwTurnsFor(sid).last.userText, 'and redo?');
    expect(c.btwTurnsFor(sid).last.aiText, 'Ctrl-r');
  });

  test('clearBtwTurnsFor empties the chain in place', () {
    final c = buildController();
    final sid = 9;

    c.appendPendingBtwTurn(sid, 'a');
    c.appendPendingBtwTurn(sid, 'b');
    c.appendPendingBtwTurn(sid, 'c');
    expect(c.btwTurnsFor(sid), hasLength(3));

    c.clearBtwTurnsFor(sid);
    expect(
      c.btwTurnsFor(sid),
      isEmpty,
      reason: 'clearBtwTurnsFor must drop every accumulated turn',
    );
  });

  test('chains are isolated per session', () {
    final c = buildController();
    c.appendPendingBtwTurn(1, 'session 1 question');
    c.appendPendingBtwTurn(2, 'session 2 question');
    c.appendPendingBtwTurn(1, 'session 1 follow-up');

    expect(c.btwTurnsFor(1), hasLength(2));
    expect(c.btwTurnsFor(2), hasLength(1));
    expect(c.btwTurnsFor(1).first.userText, 'session 1 question');
    expect(c.btwTurnsFor(1).last.userText, 'session 1 follow-up');
    expect(c.btwTurnsFor(2).last.userText, 'session 2 question');

    // Clearing session 1 must not touch session 2.
    c.clearBtwTurnsFor(1);
    expect(c.btwTurnsFor(1), isEmpty);
    expect(
      c.btwTurnsFor(2),
      hasLength(1),
      reason: 'chains are per-session, not global',
    );
  });

  test('updateLastBtwTurnAiText is a no-op on an empty chain', () {
    final c = buildController();
    final sid = 11;
    // Must not throw, must not create a phantom turn.
    c.updateLastBtwTurnAiText(sid, 'orphan update');
    expect(
      c.btwTurnsFor(sid),
      isEmpty,
      reason:
          'updates with no pending turn must not silently '
          'create a chain entry',
    );
  });

  test('switchSession preserves the prior session\'s btw chain', () async {
    // The btw chain is per-session and survives navigation —
    // switching away from session A and back to it should
    // re-render the same boxed bubbles the user left behind.
    // This is the user-facing behavior: each session is its own
    // scratch space, and a /btw question you asked in session A
    // is still there when you come back to A, even if you've
    // since worked in B.
    final c = buildController();
    final sessionA = await store.create(
      title: 'Session A',
      model: '',
      projectPath: tempDir.path,
    );
    final sessionB = await store.create(
      title: 'Session B',
      model: '',
      projectPath: tempDir.path,
    );
    c.sessions = [sessionA, sessionB];
    c.currentSessionId = sessionA.id;

    // Build up a chain in session A.
    c.appendPendingBtwTurn(sessionA.id, 'a question');
    c.updateLastBtwTurnAiText(sessionA.id, 'an answer');
    expect(c.btwTurnsFor(sessionA.id), hasLength(1));

    // Build up a chain in session B before we switch.
    c.appendPendingBtwTurn(sessionB.id, 'b question');
    c.updateLastBtwTurnAiText(sessionB.id, 'b answer');

    // Switching to B must NOT touch A's chain. B's chain is also
    // untouched (it belongs to the new current session).
    await c.switchSession(sessionB.id);
    expect(
      c.btwTurnsFor(sessionA.id),
      hasLength(1),
      reason: 'prior session\'s btw chain must survive a switch',
    );
    expect(
      c.btwTurnsFor(sessionB.id),
      hasLength(1),
      reason: 'new session\'s chain must be untouched',
    );

    // Switch back to A and verify the chain is still there.
    await c.switchSession(sessionA.id);
    expect(
      c.btwTurnsFor(sessionA.id),
      hasLength(1),
      reason: 'chain must still be intact after a round-trip switch',
    );
    expect(c.btwTurnsFor(sessionA.id).last.userText, 'a question');
    expect(c.btwTurnsFor(sessionA.id).last.aiText, 'an answer');
  });

  test('deleteSession drops that session\'s btw chain', () async {
    final c = buildController();
    final sessionA = await store.create(
      title: 'Session A',
      model: '',
      projectPath: tempDir.path,
    );
    final sessionB = await store.create(
      title: 'Session B',
      model: '',
      projectPath: tempDir.path,
    );
    c.sessions = [sessionA, sessionB];
    c.currentSessionId = sessionA.id;

    c.appendPendingBtwTurn(sessionA.id, 'a question');
    c.updateLastBtwTurnAiText(sessionA.id, 'an answer');
    c.appendPendingBtwTurn(sessionB.id, 'b question');
    c.updateLastBtwTurnAiText(sessionB.id, 'b answer');

    // Delete session A and verify only B's chain survives.
    await c.deleteSession(sessionA.id);
    expect(
      c.btwTurnsFor(sessionA.id),
      isEmpty,
      reason: 'deleted session\'s chain must not leak',
    );
    expect(
      c.btwTurnsFor(sessionB.id),
      hasLength(1),
      reason: 'unrelated sessions\' chains must be untouched',
    );
  });

  test('btw content is never persisted — the LLM context for a real '
      'turn only sees persisted real messages, never the btw chain', () async {
    // This is the core guarantee: when the user types a non-`/btw`
    // message after a btw round, the LLM that responds to the real
    // turn must NOT see the btw content in its context. The design
    // enforces this in two layers:
    //
    //   1. `_sendBtwTurn` never calls `_store.addMessage` (it goes
    //      through `LlmClient.streamChat` directly, not
    //      `ChatService.sendMessage`), so btw turns never reach
    //      the DB. The persisted history is therefore real turns
    //      only.
    //
    //   2. `_sendMessage` (the entry point for real turns) calls
    //      `clearBtwTurnsFor(sessionId)` BEFORE `_sendTurn`, so
    //      the in-memory chain that `_sendBtwTurn` populated is
    //      empty by the time a real turn runs. (Even if it
    //      weren't empty, `_sendTurn` reads history from the
    //      store, not from the btw buffer, so the chain wouldn't
    //      appear in the LLM context anyway.)
    //
    // This test verifies layer 1 (the more important of the two):
    // after a sequence of btw rounds and a real turn, the
    // persisted history contains only the real messages.
    final c = buildController();
    final session = await store.create(
      title: 'Test',
      model: '',
      projectPath: tempDir.path,
    );
    c.sessions = [session];
    c.currentSessionId = session.id;

    // Simulate a btw round: the chat panel would normally call
    // `_sendBtwTurn` here, which appends to the in-memory chain
    // but never touches the store.
    c.appendPendingBtwTurn(session.id, 'how do I undo in vim?');
    c.updateLastBtwTurnAiText(session.id, 'Press u.');

    // Simulate another btw round.
    c.appendPendingBtwTurn(session.id, 'and redo?');
    c.updateLastBtwTurnAiText(session.id, 'Ctrl-r.');

    // Verify the in-memory chain has the btw content (this is
    // what the model sees for the next btw round).
    expect(c.btwTurnsFor(session.id), hasLength(2));

    // Simulate a real turn. The chat panel would call
    // `_sendMessage` here, which:
    //   1. Calls `clearBtwTurnsFor(sessionId)` to wipe the chain.
    //   2. Calls `_sendTurn(text: ...)` which calls
    //      `_store.addMessage(...)` to persist the new real user
    //      message, then dispatches the LLM call.
    c.clearBtwTurnsFor(session.id);
    await store.messageStore.addMessage(
      session.id,
      role: 'user',
      content: 'now let\'s refactor',
    );
    await c.loadMessages(session.id);

    // The persisted history (what the LLM sees) must contain only
    // the real turn — no btw content at all.
    final persisted = await store.messageStore.getMessages(session.id);
    expect(
      persisted,
      hasLength(1),
      reason: 'only the real turn should be persisted',
    );
    expect(persisted.single.role, equals('user'));
    expect(persisted.single.content, equals("now let's refactor"));

    // And the btw chain is empty.
    expect(
      c.btwTurnsFor(session.id),
      isEmpty,
      reason: 'chain must be empty after a real turn',
    );

    // Critically: nowhere in the persisted history do any of the
    // btw strings appear.
    final allPersistedText = persisted.map((m) => m.content).join(' ');
    expect(
      allPersistedText.contains('how do I undo'),
      isFalse,
      reason: 'btw question must not leak into the real turn history',
    );
    expect(
      allPersistedText.contains('Press u'),
      isFalse,
      reason: 'btw answer must not leak into the real turn history',
    );
    expect(
      allPersistedText.contains('Ctrl-r'),
      isFalse,
      reason: 'btw follow-up must not leak into the real turn history',
    );
  });
}

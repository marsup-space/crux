import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/storage/message_store.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// `messages.meta` carries inline UI metadata attached to a tool
/// result (e.g. `{"routing":"system-proxy"}` when a `webfetch`
/// fell back to the system proxy). The LLM never sees it — only
/// the chat-history bubble / detail-view renderers read it.
///
/// This group locks down the persistence round-trip: whatever the
/// tool layer writes into `meta` is exactly what comes back from
/// `getMessages`. The default empty string is also verified so
/// existing tools (no UI metadata) don't accidentally emit
/// non-default values.
void main() {
  late CruxDatabase db;
  late SessionStore store;
  late int sessionId;

  setUp(() async {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db);
    final session = await store.create(
      title: 'meta test',
      model: 'openai/gpt-4o',
      projectPath: '/tmp',
    );
    sessionId = session.id;
  });

  tearDown(() async {
    await db.close();
  });

  group('messages.meta — persistence round-trip', () {
    test('defaults to empty string when not provided', () async {
      final store = MessageStore(db);
      store.sessionStore = SessionStore(db);
      await store.addMessage(sessionId, role: 'tool', content: 'out');
      final msgs = await store.getMessages(sessionId);
      expect(msgs, hasLength(1));
      expect(msgs.first.meta, '');
    });

    test('persists arbitrary meta through addMessage + getMessages', () async {
      final store = MessageStore(db);
      store.sessionStore = SessionStore(db);
      await store.addMessage(
        sessionId,
        role: 'tool',
        content: 'out',
        meta: '{"routing":"system-proxy"}',
      );
      final msgs = await store.getMessages(sessionId);
      expect(msgs.first.meta, '{"routing":"system-proxy"}');
    });

    test('addToolRound persists meta per tool result', () async {
      final store = MessageStore(db);
      store.sessionStore = SessionStore(db);
      await store.addToolRound(
        sessionId,
        roundText: '',
        toolCalls: [
          ToolCallData(callId: 'a', name: 'webfetch', input: const {}),
          ToolCallData(callId: 'b', name: 'read', input: const {}),
        ],
        results: [
          (callId: 'a', output: '<html>', meta: '{"routing":"system-proxy"}'),
          (callId: 'b', output: 'file contents', meta: ''),
        ],
      );

      final msgs = await store.getMessages(sessionId);
      final toolResults = msgs.where((m) => m.role == 'tool').toList();
      expect(toolResults, hasLength(2));
      // Match by toolCallId so order in the table doesn't matter.
      final byCallId = {for (final m in toolResults) m.toolCallId: m.meta};
      expect(
        byCallId['a'],
        '{"routing":"system-proxy"}',
        reason: 'webfetch (proxy path) carries the routing hint',
      );
      expect(byCallId['b'], '', reason: 'read tool carries no UI metadata');
    });

    test('copyWith propagates meta', () {
      final original = Message(
        id: 1,
        sessionId: 1,
        role: 'tool',
        content: 'out',
      );
      final copy = original.copyWith(meta: '{"routing":"system-proxy"}');
      expect(copy.meta, '{"routing":"system-proxy"}');
    });

    test('copyWith can overwrite meta to empty string', () {
      final original = Message(
        id: 1,
        sessionId: 1,
        role: 'tool',
        content: 'out',
        meta: '{"routing":"system-proxy"}',
      );
      final copy = original.copyWith(meta: '');
      expect(copy.meta, '');
    });
  });

  // Sanity: the SessionStatus enum used by `create` is what
  // the storage layer expects. (Already exercised elsewhere; this
  // test guards against accidental enum-shape changes.)
  test('SessionStatus.idle is the default for new sessions', () async {
    final sessions = await store.list();
    expect(sessions.first.status, SessionStatus.idle);
  });
}

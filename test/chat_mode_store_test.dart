import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/session.dart';
import 'package:crux/src/storage/database.dart' hide Session;
import 'package:crux/src/storage/session_store.dart';

void main() {
  late CruxDatabase db;
  late SessionStore store;

  setUp(() {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db, instanceId: 'test');
  });

  tearDown(() async {
    await db.close();
  });

  Future<Session> createSession({String projectPath = '/proj'}) {
    return store.create(title: 'S', model: 'm', projectPath: projectPath);
  }

  Future<Session> createChat() {
    return store.create(title: 'C', model: 'm', projectPath: '', kind: 'chat');
  }

  test('create persists kind and reads it back via isChat', () async {
    final chat = await createChat();
    expect(chat.isChat, isTrue);

    final reloaded = await store.getById(chat.id);
    expect(reloaded, isNotNull);
    expect(reloaded!.kind, 'chat');
    expect(reloaded.isChat, isTrue);

    final normal = await createSession();
    final reloadedNormal = await store.getById(normal.id);
    expect(reloadedNormal!.kind, isNull);
    expect(reloadedNormal.isChat, isFalse);
  });

  test('list() excludes chat rows; listChats() returns only chats', () async {
    await createSession();
    await createSession();
    final chat = await createChat();

    final sessions = await store.list(projectPath: '/proj');
    expect(sessions.every((s) => !s.isChat), isTrue);
    expect(sessions.length, 2);

    // Even without a project filter, list() must not leak chats.
    final all = await store.list();
    expect(all.any((s) => s.isChat), isFalse);

    final chats = await store.listChats();
    expect(chats.length, 1);
    expect(chats.single.id, chat.id);
    expect(chats.single.isChat, isTrue);
  });

  test('chats are visible globally (no project scoping)', () async {
    await createChat();
    await createChat();

    // listChats takes no projectPath — every instance sees all chats.
    final chats = await store.listChats();
    expect(chats.length, 2);

    // A project-scoped list for a *different* project sees neither.
    final projA = await store.list(projectPath: '/other');
    expect(projA, isEmpty);
  });

  test('archivedCount excludes chats; archivedChatCount counts them', () async {
    final chat = await createChat();
    await createSession();

    await store.archiveSession(chat.id);

    expect(await store.archivedCount(projectPath: '/proj'), 0);
    expect(await store.archivedChatCount(), 1);

    // Unarchived chats still show up in listChats, archived ones don't.
    expect(await store.listChats(), isEmpty);
    expect(await store.listChats(includeArchived: true), hasLength(1));
  });

  test('autoArchiveChats sweeps stale chats but not recent ones', () async {
    final stale = await createChat();
    final fresh = await createChat();
    await createSession(); // project session — untouched by chat sweep

    // Backdate `stale` beyond the threshold by writing updatedAt directly.
    final oldMs = DateTime.now()
        .subtract(const Duration(days: 10))
        .millisecondsSinceEpoch;
    await db.customUpdate(
      'UPDATE sessions SET updated_at = ? WHERE id = ?',
      variables: [Variable.withInt(oldMs), Variable.withInt(stale.id)],
      updates: {db.sessions},
    );

    final swept = await store.autoArchiveChats(
      olderThan: const Duration(days: 3),
    );
    expect(swept, 1);

    final remaining = await store.listChats();
    expect(remaining.map((s) => s.id), [fresh.id]);
    expect(await store.archivedChatCount(), 1);
  });

  test('project autoArchive does not touch chats', () async {
    final chat = await createChat();
    final oldMs = DateTime.now()
        .subtract(const Duration(days: 10))
        .millisecondsSinceEpoch;
    await db.customUpdate(
      'UPDATE sessions SET updated_at = ? WHERE id = ?',
      variables: [Variable.withInt(oldMs), Variable.withInt(chat.id)],
      updates: {db.sessions},
    );

    // Project-scoped sweep for the workspace the chat happens to have
    // been created near — chats have projectPath='' so they never match.
    await store.autoArchive(
      projectPath: '/proj',
      olderThan: const Duration(days: 3),
    );

    final stillThere = await store.listChats();
    expect(stillThere.map((s) => s.id), contains(chat.id));
  });
}

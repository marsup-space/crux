import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory originalCwd;
  late Directory tempDir;
  late CruxDatabase db;
  late ProviderService providerService;

  setUp(() async {
    originalCwd = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('crux_multi_instance_');
    Directory.current = tempDir;
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    providerService = ProviderService(userProvidersDir: tempDir.path);
  });

  tearDown(() async {
    await db.close();
    Directory.current = originalCwd;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SessionController buildController(SessionStore store) {
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

  test('initSessions selects the most recent idle or done session', () async {
    final store = SessionStore(db, instanceId: 'local');
    final projectPath = Directory.current.path;
    final idle = await store.create(
      title: 'Idle',
      model: '',
      projectPath: projectPath,
    );
    final running = await store.create(
      title: 'Running elsewhere',
      model: '',
      projectPath: projectPath,
    );
    await store.update(running.id, status: SessionStatus.running);
    final done = await store.create(
      title: 'Done',
      model: '',
      projectPath: projectPath,
    );
    await store.update(done.id, status: SessionStatus.done);

    final controller = buildController(store);
    await controller.initSessions();

    expect(controller.currentSessionId, done.id);
    expect(controller.currentSessionId, isNot(running.id));
    expect(controller.currentSessionId, isNot(idle.id));
  });

  test(
    'initSessions creates a new session when none are idle or done',
    () async {
      final owner = SessionStore(db, instanceId: 'owner');
      final local = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      final running = await owner.create(
        title: 'Running elsewhere',
        model: '',
        projectPath: projectPath,
      );
      await owner.update(running.id, status: SessionStatus.running);
      final interrupted = await local.create(
        title: 'Interrupted',
        model: '',
        projectPath: projectPath,
      );
      await local.update(interrupted.id, status: SessionStatus.interrupted);

      final controller = buildController(local);
      await controller.initSessions();

      expect(controller.currentSessionId, isNot(running.id));
      expect(controller.currentSessionId, isNot(interrupted.id));
      // Empty title = untitled; the display layer renders a
      // locale-aware placeholder (see Session.isUntitled).
      expect(controller.currentSession.title, '');
      expect(controller.currentSession.status, SessionStatus.idle);
    },
  );

  test(
    'switchSession refuses a live session owned by another instance',
    () async {
      final owner = SessionStore(db, instanceId: 'owner');
      final local = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      final idle = await local.create(
        title: 'Idle',
        model: '',
        projectPath: projectPath,
      );
      final running = await owner.create(
        title: 'Running elsewhere',
        model: '',
        projectPath: projectPath,
      );
      await owner.update(running.id, status: SessionStatus.running);

      final controller = buildController(local);
      controller.sessions = [idle, (await local.getById(running.id))!];
      controller.currentSessionId = idle.id;

      final error = await controller.switchSession(running.id);

      expect(error, contains('another Crux instance'));
      expect(controller.currentSessionId, idle.id);
    },
  );

  test(
    'reconcileInactiveRunningSessions idles stopped local running rows',
    () async {
      final store = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      final running = await store.create(
        title: 'Finished locally',
        model: '',
        projectPath: projectPath,
      );
      await store.update(running.id, status: SessionStatus.running);

      final controller = buildController(store);
      controller.sessions = [(await store.getById(running.id))!];

      final changed = await controller.reconcileInactiveRunningSessions(
        refresh: false,
      );

      expect(changed, isTrue);
      expect(controller.sessions.single.status, SessionStatus.idle);
      expect((await store.getById(running.id))!.status, SessionStatus.idle);
    },
  );

  test(
    'reconcileInactiveRunningSessions preserves live rows owned elsewhere',
    () async {
      final owner = SessionStore(db, instanceId: 'owner');
      final local = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      final running = await owner.create(
        title: 'Running elsewhere',
        model: '',
        projectPath: projectPath,
      );
      await owner.update(running.id, status: SessionStatus.running);

      final controller = buildController(local);
      controller.sessions = [(await local.getById(running.id))!];

      final changed = await controller.reconcileInactiveRunningSessions(
        refresh: false,
      );

      expect(changed, isFalse);
      expect(controller.sessions.single.status, SessionStatus.running);
      expect((await local.getById(running.id))!.status, SessionStatus.running);
    },
  );

  test(
    'initSessions loads chats globally alongside project sessions',
    () async {
      final store = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      await store.create(title: 'WS', model: '', projectPath: projectPath);
      final chat = await store.create(
        title: 'Chat',
        model: '',
        projectPath: '',
        kind: 'chat',
      );

      final controller = buildController(store);
      await controller.initSessions();

      expect(controller.sessions.any((s) => s.isChat), isFalse);
      expect(controller.chats.map((s) => s.id), contains(chat.id));
      // findSession resolves across both lists.
      expect(controller.findSession(chat.id)?.isChat, isTrue);
    },
  );

  test(
    'switchSession refuses a chat that is live in another instance',
    () async {
      final owner = SessionStore(db, instanceId: 'owner');
      final local = SessionStore(db, instanceId: 'local');
      final projectPath = Directory.current.path;
      final idle = await local.create(
        title: 'Idle',
        model: '',
        projectPath: projectPath,
      );
      final runningChat = await owner.create(
        title: 'Chat elsewhere',
        model: '',
        projectPath: '',
        kind: 'chat',
      );
      await owner.update(runningChat.id, status: SessionStatus.running);

      final controller = buildController(local);
      controller.sessions = [idle];
      controller.chats = [(await local.getById(runningChat.id))!];
      controller.currentSessionId = idle.id;

      final error = await controller.switchSession(runningChat.id);

      expect(error, contains('another Crux instance'));
      expect(controller.currentSessionId, idle.id);
    },
  );
}

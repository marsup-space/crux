// Mirrors SessionController state into SessionCubit. Every mutation on
// the controller should also produce a matching change in
// `controller.cubit.state`, so widgets can subscribe via BlocBuilder
// while older code keeps reading from the controller's fields.
//
// These tests drive the controller through the same paths it sees at
// runtime (initSessions, switchSession, message-queue ops, pending
// images, input stash, rename, generateTitle, resolveAuxiliaryModel,
// deleteSession) and assert the cubit reflects each step.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/models/image_attachment.dart';
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
  late SessionStore store;

  setUp(() async {
    originalCwd = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('crux_cubit_mirror_');
    Directory.current = tempDir;
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    providerService = ProviderService(userProvidersDir: tempDir.path);
    store = SessionStore(db, instanceId: 'local');
  });

  tearDown(() async {
    await db.close();
    Directory.current = originalCwd;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SessionController buildController() {
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

  test('initSessions mirrors sessions list, archivedCount, and currentId',
      () async {
    final idle = await store.create(
      title: 'Idle',
      model: '',
      projectPath: Directory.current.path,
    );

    final controller = buildController();
    await controller.initSessions();

    expect(controller.currentSessionId, idle.id);
    expect(controller.cubit.state.currentSessionId, idle.id);
    expect(
      controller.cubit.state.sessions.map((s) => s.id),
      controller.sessions.map((s) => s.id),
    );
    expect(controller.cubit.state.archivedCount, controller.archivedCount);
  });

  test('loadMessages puts cached messages into the cubit', () async {
    final session = await store.create(
      title: 'With messages',
      model: '',
      projectPath: Directory.current.path,
    );
    await store.messageStore.addMessage(
      session.id,
      role: 'user',
      content: 'hello',
    );
    await store.messageStore.addMessage(
      session.id,
      role: 'ai',
      content: 'world',
    );

    final controller = buildController()..sessions = [session];
    await controller.loadMessages(session.id);

    expect(controller.messageCache[session.id], hasLength(2));
    expect(controller.cubit.state.messagesFor(session.id), hasLength(2));
  });

  test('switchSession lifecycle mirrors loading state into the cubit',
      () async {
    final session = await store.create(
      title: 'Big',
      model: '',
      projectPath: Directory.current.path,
    );
    for (var i = 0; i < 30; i++) {
      await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: 'message #$i',
      );
    }

    final controller = buildController()..sessions = [session];
    controller.beginSwitchSession(session.id);
    expect(
      controller.cubit.state.isLoadingMessages(session.id),
      isTrue,
      reason: 'beginSwitchSession should mirror loading=true into the cubit',
    );

    await controller.completeSwitchSession(session.id);

    expect(
      controller.cubit.state.isLoadingMessages(session.id),
      isFalse,
      reason: 'completeSwitchSession should mirror loading=false finally',
    );
    expect(
      controller.cubit.state.messagesFor(session.id),
      hasLength(30),
      reason: 'chunked load should mirror every cache update',
    );
  });

  test('message queue enqueue / discard / drain mirror to the cubit', () {
    final controller = buildController();
    final sessionId = 1;

    final id1 = controller.enqueueMessage(sessionId, 'first');
    expect(controller.cubit.state.queuedMessagesFor(sessionId), hasLength(1));
    expect(
      controller.cubit.state.queuedMessagesFor(sessionId).first.id,
      id1,
    );

    controller.enqueueMessage(sessionId, 'second');
    expect(controller.cubit.state.queuedMessagesFor(sessionId), hasLength(2));

    expect(controller.discardQueuedMessage(sessionId, id1), isTrue);
    expect(
      controller.cubit.state.queuedMessagesFor(sessionId),
      hasLength(1),
      reason: 'discard should mirror the new snapshot',
    );
    expect(
      controller.cubit.state.queuedMessagesFor(sessionId).first.content,
      'second',
    );

    final drained = controller.drainMessageQueue(sessionId);
    expect(drained, contains('second'));
    expect(controller.cubit.state.queuedMessagesFor(sessionId), isEmpty);

    controller.enqueueMessage(sessionId, 'leftover');
    controller.clearMessageQueue(sessionId);
    expect(controller.cubit.state.queuedMessagesFor(sessionId), isEmpty);
  });

  test('pending image ops mirror to the cubit', () {
    final controller = buildController();
    const image = ImageAttachment(
      mediaType: 'image/png',
      base64Data: 'abc',
      label: 'clipboard',
    );
    const image2 = ImageAttachment(
      mediaType: 'image/png',
      base64Data: 'def',
      label: 'paste',
    );

    controller.addPendingImage(7, image);
    expect(controller.cubit.state.pendingImagesFor(7), [image]);

    controller.setPendingImages(7, const [image, image2]);
    expect(controller.cubit.state.pendingImagesFor(7), [image, image2]);

    expect(controller.removePendingImage(7, 1), isTrue);
    expect(controller.cubit.state.pendingImagesFor(7), [image2]);

    final drained = controller.drainPendingImages(7);
    expect(drained, [image2]);
    expect(controller.cubit.state.pendingImagesFor(7), isEmpty);
  });

  test('stashInputText mirrors to the cubit', () {
    final controller = buildController();
    controller.stashInputText(4, 'draft');
    expect(controller.cubit.state.inputTextStash[4], 'draft');

    controller.stashInputText(4, '');
    expect(controller.cubit.state.inputTextStash.containsKey(4), isFalse);
  });

  test('rename mirrors the new title into the cubit', () async {
    final session = await store.create(
      title: 'Old title',
      model: '',
      projectPath: Directory.current.path,
    );
    final controller = buildController()
      ..sessions = [session]
      ..currentSessionId = session.id;

    await controller.renameSession(session.id, 'New title');

    expect(
      controller.cubit.state.currentSession?.title,
      'New title',
      reason: 'rename should be visible in the cubit session list',
    );
  });

  test('resolveAuxiliaryModel mirrors the resolved model name', () {
    final controller = buildController();
    // No provider config in this test, so the cubit ends up with
    // whatever the master fallback computes. The mirror should at
    // least agree with the controller's own field after the call.
    controller.resolveAuxiliaryModel();
    expect(
      controller.cubit.state.auxiliaryModelShortName,
      controller.auxiliaryModelShortName,
    );
  });

  test(
      'generateTitle mirrors whatever state the controller ends up in',
      () async {
    final session = await store.create(
      title: 'New Session',
      model: '',
      projectPath: Directory.current.path,
    );
    // ProviderService in this fixture has no auxiliary model
    // configured, so generateTitle returns immediately without
    // flipping the isGeneratingTitle flag. Verify the cubit's
    // final state still matches the controller's flag — i.e. the
    // cubit never diverges from the controller's source of truth.
    final controller = buildController()
      ..sessions = [session]
      ..currentSessionId = session.id;

    await controller.generateTitle(session.id);

    expect(
      controller.cubit.state.isGeneratingTitle,
      controller.isGeneratingTitle,
      reason: 'cubit.isGeneratingTitle should track controller.isGeneratingTitle',
    );
    expect(controller.cubit.state.isGeneratingTitle, isFalse);
  });

  test(
      'deleteSession mirrors session removal + reload into the cubit',
      () async {
    final keep = await store.create(
      title: 'Keep',
      model: '',
      projectPath: Directory.current.path,
    );
    final drop = await store.create(
      title: 'Drop',
      model: '',
      projectPath: Directory.current.path,
    );

    final controller = buildController()
      ..sessions = [drop, keep]
      ..currentSessionId = drop.id;

    await controller.deleteSession(drop.id);

    expect(
      controller.cubit.state.sessions.map((s) => s.id),
      [keep.id],
      reason: 'removed session should be gone from the cubit list',
    );
    expect(
      controller.cubit.state.currentSessionId,
      keep.id,
      reason: 'currentSessionId should rebalance to the remaining session',
    );
    expect(
      controller.cubit.state.messagesFor(drop.id),
      isEmpty,
      reason: 'removeSessionState should clear the deleted cache',
    );
  });

  group('btwCubit mirror', () {
    test('appendBtwTurn / appendPendingBtwTurn mirror into btwCubit', () {
      final controller = buildController();
      const completed = BtwTurn(userText: 'hi', aiText: 'hello');
      const pending = BtwTurn(userText: 'followup', aiText: '');

      controller.appendBtwTurn(1, completed);
      expect(controller.btwCubit.state.turnsFor(1), [completed]);

      controller.appendPendingBtwTurn(1, 'followup');
      expect(
        controller.btwCubit.state.turnsFor(1),
        [completed, pending],
      );
    });

    test('updateLastBtwTurnAiText mirrors into the last turn', () {
      final controller = buildController();
      controller.appendPendingBtwTurn(2, 'what is dart?');
      controller.updateLastBtwTurnAiText(2, 'Dart is a programming language.');

      expect(controller.btwCubit.state.turnsFor(2).single.aiText,
          'Dart is a programming language.');
      // The controller's own btw buffer should agree with the cubit.
      expect(
        controller.btwTurnsFor(2).single.aiText,
        'Dart is a programming language.',
      );
    });

    test('clearBtwTurnsFor wipes the cubit entry for that session', () {
      final controller = buildController();
      controller.appendPendingBtwTurn(3, 'first');
      controller.appendPendingBtwTurn(3, 'second');
      expect(controller.btwCubit.state.turnsFor(3), hasLength(2));

      controller.clearBtwTurnsFor(3);
      expect(controller.btwCubit.state.turnsFor(3), isEmpty);
      expect(controller.btwTurnsFor(3), isEmpty);
    });

    test('deleteSession removes btw state from both buffers', () async {
      final session = await store.create(
        title: 'With btw',
        model: '',
        projectPath: Directory.current.path,
      );

      final controller = buildController()
        ..sessions = [session]
        ..currentSessionId = session.id;
      controller.appendPendingBtwTurn(session.id, 'a turn');
      expect(
        controller.btwCubit.state.turnsFor(session.id),
        hasLength(1),
      );

      await controller.deleteSession(session.id);

      expect(
        controller.btwCubit.state.turnsFor(session.id),
        isEmpty,
        reason: 'deleteSession should drop per-session btw state from cubit',
      );
      expect(controller.btwTurnsFor(session.id), isEmpty);
    });
  });
}

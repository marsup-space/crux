import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late SessionStore store;
  late ProviderService providerService;
  late ChatService chatService;
  late SessionController sessionController;
  late StreamingController streamingController;
  late ChatTurnOrchestrator orchestrator;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_subagent_wake_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db, instanceId: 'local');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    final tracker = FileReadTracker();
    final toolRegistry = ToolRegistry()
      ..registerDefaults(
        tracker,
        sessionStore: store,
        webProviderRegistry: WebProviderRegistry(),
      );
    chatService = ChatService(
      store,
      providerService,
      LlmClient(),
      ToolExecutor(toolRegistry),
    );
    sessionController = SessionController(
      store: store,
      providerService: providerService,
      chatService: chatService,
      refresh: () {},
    );
    streamingController = StreamingController(
      sessionController: sessionController,
      refresh: () {},
    );
    orchestrator = ChatTurnOrchestrator(
      store: store,
      chatService: chatService,
      providerService: providerService,
      sessionController: sessionController,
      streamingController: streamingController,
      toolRegistry: toolRegistry,
      showToast: (_, {mode = ToastMode.info}) {},
      refresh: () {},
      gitStatusService: GitStatusService(),
      tracker: tracker,
    );
  });

  tearDown(() async {
    streamingController.dispose();
    sessionController.dispose();
    chatService.dispose();
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<Session> newSession() async {
    final s = await store.create(
      title: 't',
      projectPath: tempDir.path,
      model: 'openai/gpt-5',
    );
    sessionController.sessions = [s];
    sessionController.currentSessionId = s.id;
    return s;
  }

  group('enqueueSubagentWake', () {
    test('mid-turn: queues the envelope instead of dropping it', () async {
      final s = await newSession();
      final rt = sessionController.runtime(s.id);
      rt.isResponding = true; // main agent mid-turn → sendTurn is a no-op

      orchestrator.enqueueSubagentWake(
        '[Crux system note — subagent report] done',
        sessionId: s.id,
      );

      // The M2 bug dropped this envelope. It must now be queued, so the
      // drain after the turn settles can deliver it.
      expect(orchestrator.pendingSubagentWakesForTest, hasLength(1));
      expect(orchestrator.pendingSubagentWakesForTest.first.$1, s.id);
      expect(rt.isResponding, isTrue);
    });

    test('multiple mid-turn reports coalesce in the queue', () async {
      final s = await newSession();
      final rt = sessionController.runtime(s.id);
      rt.isResponding = true;
      orchestrator.enqueueSubagentWake('report A', sessionId: s.id);
      orchestrator.enqueueSubagentWake('report B', sessionId: s.id);
      orchestrator.enqueueSubagentWake('report C', sessionId: s.id);
      expect(orchestrator.pendingSubagentWakesForTest, hasLength(3));
    });

    test('queued envelopes clear when the session is gone', () async {
      final s = await newSession();
      final rt = sessionController.runtime(s.id);
      rt.isResponding = true;
      orchestrator.enqueueSubagentWake('report', sessionId: s.id);
      expect(orchestrator.pendingSubagentWakesForTest, isNotEmpty);
      // Session detached (user switched away / closed) → drain drops
      // its group: the wake has nowhere to land.
      sessionController.sessions = [];
      rt.isResponding = false;
      orchestrator.drainSubagentWakesForTest();
      expect(orchestrator.pendingSubagentWakesForTest, isEmpty);
    });

    test(
      'a report for a BACKGROUND session wakes that session, not the viewed one',
      () async {
        final viewed = await newSession();
        final background = await store.create(
          title: 'bg',
          projectPath: tempDir.path,
          model: 'openai/gpt-5',
        );
        sessionController.sessions = [viewed, background];
        // Both idle. The user is VIEWING `viewed`; the run belonged to
        // `background`. The wake must target `background`: its turn
        // starts (and, with no provider key in tests, settles with a
        // persisted row), while `viewed` stays untouched.
        orchestrator.enqueueSubagentWake(
          '[Crux system note — subagent report] done',
          sessionId: background.id,
        );
        await _pumpUntil(
          () async => (await store.messageStore.getMessages(background.id))
              .isNotEmpty,
        );
        // The viewed session's history stays empty — no wake, no user
        // row, no error row.
        expect(
          await store.messageStore.getMessages(viewed.id),
          isEmpty,
        );
        expect(sessionController.currentSessionId, viewed.id);
      },
    );

    test(
      'busy background session keeps its group queued while another group drains',
      () async {
        final a = await newSession();
        final b = await store.create(
          title: 'b',
          projectPath: tempDir.path,
          model: 'openai/gpt-5',
        );
        sessionController.sessions = [a, b];
        sessionController.runtime(b.id).isResponding = true; // b mid-turn

        orchestrator.enqueueSubagentWake('for-a', sessionId: a.id);
        orchestrator.enqueueSubagentWake('for-b', sessionId: b.id);

        // b's group requeued synchronously (b is mid-turn); a's group
        // drained into a targeted sendTurn that lands rows in a's
        // history (user row first; the keyless provider then settles).
        final pending = orchestrator.pendingSubagentWakesForTest;
        expect(pending, hasLength(1));
        expect(pending.first.$1, b.id);
        expect(pending.first.$2, 'for-b');
        await _pumpUntil(
          () async => (await store.messageStore.getMessages(a.id)).isNotEmpty,
        );
      },
    );
  });
}

/// Poll [condition] until true (bounded), yielding between checks so
/// async orchestrator work progresses.
Future<void> _pumpUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

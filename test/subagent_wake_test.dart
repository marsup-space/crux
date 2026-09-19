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
      );

      // The M2 bug dropped this envelope. It must now be queued, so the
      // drain after the turn settles can deliver it.
      expect(orchestrator.pendingSubagentWakesForTest, hasLength(1));
      expect(rt.isResponding, isTrue);
    });

    test('multiple mid-turn reports coalesce in the queue', () async {
      final s = await newSession();
      final rt = sessionController.runtime(s.id);
      rt.isResponding = true;
      orchestrator.enqueueSubagentWake('report A');
      orchestrator.enqueueSubagentWake('report B');
      orchestrator.enqueueSubagentWake('report C');
      expect(orchestrator.pendingSubagentWakesForTest, hasLength(3));
    });

    test('queued envelopes clear when the session is gone', () async {
      final s = await newSession();
      final rt = sessionController.runtime(s.id);
      rt.isResponding = true;
      orchestrator.enqueueSubagentWake('report');
      expect(orchestrator.pendingSubagentWakesForTest, isNotEmpty);
      // Session detached (user switched away / closed) → drain drops them.
      sessionController.currentSessionId = null;
      rt.isResponding = false;
      orchestrator.drainSubagentWakesForTest();
      expect(orchestrator.pendingSubagentWakesForTest, isEmpty);
    });
  });
}

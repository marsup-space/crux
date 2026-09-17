import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/ui/toast.dart';
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
  late ChatService chatService;
  late SessionController sessionController;
  late StreamingController streamingController;
  late GitStatusService gitStatusService;
  late ChatTurnOrchestrator orchestrator;

  setUp(() async {
    // Intentionally NOT reassigned. `Directory.current` is process-global and
    // package:test runs suites concurrently in one process, so mutating it here
    // raced every other suite that reads it. The code under test and these tests
    // already read the same cwd, so they agree without it; anything this suite
    // must own is addressed explicitly through `tempDir`.
    tempDir = await Directory.systemTemp.createTemp(
      'crux_compact_context_mirror_',
    );

    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db, instanceId: 'local');
    final providerService = ProviderService(userProvidersDir: tempDir.path);
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
      projectPath: () => tempDir.path,
    );
    streamingController = StreamingController(
      sessionController: sessionController,
      refresh: () {},
    );
    gitStatusService = GitStatusService();
    orchestrator = ChatTurnOrchestrator(
      store: store,
      chatService: chatService,
      providerService: providerService,
      sessionController: sessionController,
      streamingController: streamingController,
      toolRegistry: toolRegistry,
      showToast: (_, {mode = ToastMode.info}) {},
      refresh: () {},
      gitStatusService: gitStatusService,
      tracker: tracker,
    );
  });

  tearDown(() async {
    streamingController.dispose();
    sessionController.dispose();
    chatService.dispose();
    gitStatusService.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'manual compaction mirrors the reduced target into MetricsCubit',
    () async {
      final session = await store.create(
        title: 'Compaction target mirror',
        model: '',
        projectPath: tempDir.path,
      );
      await store.update(session.id, contextTokens: 100000);
      session.contextTokens = 100000;
      await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: 'Please inspect the context-window display.',
      );
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'The context can be compacted now.',
      );

      sessionController
        ..sessions = [session]
        ..currentSessionId = session.id;
      final runtime = sessionController.runtime(session.id);
      expect(runtime.contextTargetTokens, 100000);
      expect(
        sessionController.metricsCubit.state
            .sessionState(session.id)
            .contextTargetTokens,
        100000,
      );

      await orchestrator.compactCurrentSession();

      expect(session.contextTokens, lessThan(100000));
      expect(runtime.contextTargetTokens, session.contextTokens);
      expect(
        sessionController.metricsCubit.state
            .sessionState(session.id)
            .contextTargetTokens,
        session.contextTokens,
        reason:
            'ContextBar reads MetricsCubit, so compaction must mirror the '
            'new target there instead of only updating SessionRuntimeState.',
      );
    },
  );
}

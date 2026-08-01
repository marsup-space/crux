// Regression: in vibe mode the `role: 'compaction'` row used to be
// invisible — `walkSegments` skips it as a system role, and only the
// verbose path rendered the [CompactionDivider]. The fix re-inserts
// the divider in the vibe path, anchored to the first user message
// persisted after the compaction row (or after all segments when the
// compaction is the latest row).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm_bloc/nocterm_bloc.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/btw_cubit.dart';
import 'package:crux/src/components/chat_history.dart';
import 'package:crux/src/components/chat_turn_cubit.dart';
import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/metrics_cubit.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/session_cubit.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/streaming_cubit.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late SessionStore store;
  late ProviderService providerService;
  late ToolRegistry toolRegistry;
  late ChatService chatService;
  late SessionController sessionController;
  late StreamingController streamingController;
  late GitStatusService gitStatusService;
  late ChatTurnOrchestrator turnOrchestrator;
  late AutoScrollController scrollController;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'crux_vibe_compaction_divider_',
    );

    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db, instanceId: 'local');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    final tracker = FileReadTracker();
    toolRegistry = ToolRegistry()
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
    gitStatusService = GitStatusService();
    turnOrchestrator = ChatTurnOrchestrator(
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
    scrollController = AutoScrollController();
  });

  tearDown(() async {
    scrollController.dispose();
    streamingController.dispose();
    sessionController.dispose();
    chatService.dispose();
    gitStatusService.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<String> renderVibeHistory({
    required int sessionId,
    required List<Message> messages,
  }) async {
    final session = Session(
      id: sessionId,
      title: 'Vibe compaction divider',
      model: '',
      projectPath: tempDir.path,
      status: SessionStatus.running,
    );
    sessionController
      ..sessions = [session]
      ..currentSessionId = sessionId
      ..putCachedMessages(sessionId, messages);
    sessionController.cubit.replaceSessions(
      sessions: [session],
      archivedCount: 0,
      currentSessionId: sessionId,
    );
    sessionController.runtime(sessionId).chatDisplayMode = ChatDisplayMode.vibe;

    String rendered = '';
    await testNocterm('render', (tester) async {
      await tester.pumpComponent(
        MultiBlocProvider(
          providers: [
            BlocProvider<SessionCubit>.value(value: sessionController.cubit),
            BlocProvider<BtwCubit>.value(value: sessionController.btwCubit),
            BlocProvider<MetricsCubit>.value(
              value: sessionController.metricsCubit,
            ),
            BlocProvider<ChatTurnCubit>.value(
              value: sessionController.chatTurnCubit,
            ),
            BlocProvider<StreamingCubit>.value(
              value: sessionController.streamingCubit,
            ),
          ],
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 100,
              height: 30,
              child: ChatHistory(
                scrollController: scrollController,
                sessionController: sessionController,
                streamingController: streamingController,
                turnOrchestrator: turnOrchestrator,
                providerService: providerService,
                toolRegistry: toolRegistry,
                showToast: (_, {mode = ToastMode.info}) {},
                refresh: () {},
              ),
            ),
          ),
        ),
      );
      rendered = tester.renderToString(showBorders: false);
    }, size: const Size(100, 30));
    return rendered;
  }

  test(
    'vibe mode renders the compaction divider between the turns it separates',
    () async {
      final messages = <Message>[
        Message(id: 1, sessionId: 1, role: 'user', content: 'first question'),
        Message(id: 2, sessionId: 1, role: 'ai', content: 'first answer'),
        Message(
          id: 3,
          sessionId: 1,
          role: 'compaction',
          content: 'compacted chat log',
        ),
        Message(id: 4, sessionId: 1, role: 'user', content: 'second question'),
        Message(id: 5, sessionId: 1, role: 'ai', content: 'second answer'),
      ];

      final rendered = await renderVibeHistory(
        sessionId: 1,
        messages: messages,
      );

      expect(
        RegExp(r'\bCompaction\b').allMatches(rendered),
        hasLength(1),
        reason: rendered,
      );
      // Ordering: the divider sits between the two turns — after the
      // first turn's prose, before the second turn's user line.
      final compactionAt = rendered.indexOf('Compaction');
      final firstAnswerAt = rendered.indexOf('first answer');
      final secondQuestionAt = rendered.indexOf('second question');
      expect(firstAnswerAt, greaterThanOrEqualTo(0), reason: rendered);
      expect(secondQuestionAt, greaterThanOrEqualTo(0), reason: rendered);
      expect(compactionAt, greaterThan(firstAnswerAt), reason: rendered);
      expect(compactionAt, lessThan(secondQuestionAt), reason: rendered);
    },
  );

  test(
    'vibe mode renders the compaction divider when compaction is the latest row',
    () async {
      final messages = <Message>[
        Message(id: 1, sessionId: 2, role: 'user', content: 'only question'),
        Message(id: 2, sessionId: 2, role: 'ai', content: 'only answer'),
        Message(
          id: 3,
          sessionId: 2,
          role: 'compaction',
          content: 'compacted chat log',
        ),
      ];

      final rendered = await renderVibeHistory(
        sessionId: 2,
        messages: messages,
      );

      expect(
        RegExp(r'\bCompaction\b').allMatches(rendered),
        hasLength(1),
        reason: rendered,
      );
      // Falls after the only turn's prose.
      final compactionAt = rendered.indexOf('Compaction');
      final answerAt = rendered.indexOf('only answer');
      expect(answerAt, greaterThanOrEqualTo(0), reason: rendered);
      expect(compactionAt, greaterThan(answerAt), reason: rendered);
    },
  );
}

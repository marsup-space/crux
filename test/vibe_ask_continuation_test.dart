// Regression test: after submitting an `ask` form mid-turn, the
// agent's continuation (more tool rounds + the final `role: 'ai'`
// reply) must render in vibe mode. The answer row closes the first
// segment; the continuation lives under the SAME user turn. The
// final `ai` row must close a segment that actually renders — not
// vanish behind the streaming bubble's baseSegment merge.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm_test.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/ask_answer_bubble.dart';
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
    tempDir = await Directory.systemTemp.createTemp('crux_vibe_ask_cont_');
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

  dynamic buildHistory() {
    return MultiBlocProvider(
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
          width: 120,
          height: 40,
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
    );
  }

  test(
    'vibe mode renders the ai reply that follows an ask-form continuation',
    () async {
      const sessionId = 1;
      final session = Session(
        id: sessionId,
        title: 'ask continuation',
        model: '',
        projectPath: tempDir.path,
        status: SessionStatus.idle,
      );

      // Mirror the exact row sequence from the live session:
      //   user → tool_call(ask) → tool(ask result) → user(answer)
      //   → tool_call(bash) → tool → ai(final reply)
      final answerMsg = Message(
        id: 4,
        sessionId: sessionId,
        role: 'user',
        content:
            '[prompt] test\n\n[g] render_ok\n\n[note] 123',
      );
      final messages = <Message>[
        Message(id: 1, sessionId: sessionId, role: 'user', content: '再 askform 试试看'),
        Message(
          id: 2,
          sessionId: sessionId,
          role: 'tool_call',
          content: '好，我直接调一次 ask 工具，你验证下表单渲染和交互是否正常：',
          reasoningContent: 'r' * 100,
          reasoningTokens: 25,
          thinkingDurationMs: 4200,
          reasoningEffort: 'max',
          toolCalls: const [
            ToolCallData(
              callId: 'ask-1',
              name: 'ask',
              input: {'groups': []},
            ),
          ],
        ),
        Message(
          id: 3,
          sessionId: sessionId,
          role: 'tool',
          toolCallId: 'ask-1',
          content: '[prompt] test\n\n[g] render_ok\n\n[note] 123',
        ),
        answerMsg,
        Message(
          id: 5,
          sessionId: sessionId,
          role: 'tool_call',
          content: '',
          toolCalls: const [
            ToolCallData(
              callId: 'bash-1',
              name: 'bash',
              input: {'command': 'git status --short'},
            ),
          ],
        ),
        Message(
          id: 6,
          sessionId: sessionId,
          role: 'tool',
          toolCallId: 'bash-1',
          content: ' M lib/src/components/chat_history.dart',
        ),
        Message(
          id: 7,
          sessionId: sessionId,
          role: 'ai',
          content: '表单测试成功，全部正常：\n\n- 单选组 render_ok ✓',
        ),
      ];

      sessionController
        ..sessions = [session]
        ..currentSessionId = sessionId
        ..putCachedMessages(sessionId, messages);
      sessionController.cubit.replaceSessions(
        sessions: [session],
        archivedCount: 0,
        currentSessionId: sessionId,
      );
      // Turn is DONE (continuation finished, ai persisted).
      sessionController.runtime(sessionId)
        ..chatDisplayMode = ChatDisplayMode.vibe
        ..isResponding = false;
      sessionController.mirrorTurnFlags(sessionId);

      // Register the answer recap exactly like chat_panel's onSubmit does.
      sessionController.registerAskAnswerView(
        answerMsg,
        const AskAnswerView(
          prompt: 'test',
          selections: [],
          note: '123',
        ),
      );

      await testNocterm(
        'ask continuation ai reply renders',
        (tester) async {
          await tester.pumpComponent(buildHistory());
          await tester.pump();

          final rendered = tester.renderToString(showBorders: false);
          print('===== RENDER =====');
          print(rendered);
          print('==================');

          expect(
            rendered,
            contains('表单测试成功'),
            reason: 'final ai reply must render in vibe mode\n$rendered',
          );

          // Ordering: the AskAnswerBubble must land at the answer's
          // TRUE position — after the ask call's tools box and its
          // opening prose, before the continuation's reply. Not at
          // the very top of the turn.
          final askCall = rendered.indexOf('好，我直接调一次 ask');
          final answer = rendered.indexOf('Ask'); // recap bubble chip
          final continuation = rendered.indexOf('表单测试成功');
          expect(askCall, greaterThanOrEqualTo(0), reason: rendered);
          expect(answer, greaterThan(askCall),
              reason: 'answer bubble after the ask call\n$rendered');
          expect(continuation, greaterThan(answer),
              reason: 'continuation reply after the answer\n$rendered');
        },
        size: const Size(120, 40),
      );
    },
  );
}

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
      'crux_vibe_streaming_merge_',
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

  test(
    'persisted pending rounds and the live round render one box per kind',
    () async {
      const sessionId = 1;
      final session = Session(
        id: sessionId,
        title: 'Vibe streaming merge',
        model: '',
        projectPath: tempDir.path,
        status: SessionStatus.running,
      );
      final messages = <Message>[
        Message(
          id: 1,
          sessionId: sessionId,
          role: 'user',
          content: 'reproduce the open segment',
        ),
        Message(
          id: 2,
          sessionId: sessionId,
          role: 'tool_call',
          content: '',
          reasoningContent: 'a' * 836,
          reasoningTokens: 209,
          thinkingDurationMs: 73800,
          reasoningEffort: 'normal',
          toolCalls: const [
            ToolCallData(
              callId: 'persisted-read',
              name: 'read',
              input: {'filePath': 'lib/a.dart'},
            ),
            ToolCallData(
              callId: 'persisted-edit',
              name: 'edit',
              input: {
                'filePath': 'lib/base.dart',
                'oldString': 'old',
                'newString': 'new',
              },
            ),
          ],
        ),
        Message(
          id: 3,
          sessionId: sessionId,
          role: 'tool',
          toolCallId: 'persisted-read',
          content: 'file contents',
        ),
        Message(
          id: 4,
          sessionId: sessionId,
          role: 'tool',
          toolCallId: 'persisted-edit',
          content: 'Edit applied',
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

      sessionController.runtime(sessionId)
        ..chatDisplayMode = ChatDisplayMode.vibe
        ..isResponding = true
        ..roundFirstTokenTime = DateTime.now().subtract(
          const Duration(milliseconds: 26400),
        );
      sessionController.mirrorTurnFlags(sessionId);

      // Current round: another 42 reasoning tokens and another read call.
      // Before the fix this produced a second think box and second tools box
      // below the persisted pending segment.
      streamingController.appendStreamingReasoning(sessionId, 'b' * 168);
      streamingController.updateStreamingToolCall(
        sessionId,
        const ToolUseChunk(
          index: 0,
          callId: 'live-read',
          name: 'read',
          inputDelta: '{"filePath":"lib/b.dart"}',
        ),
      );
      streamingController.updateStreamingToolCall(
        sessionId,
        const ToolUseChunk(
          index: 1,
          callId: 'live-edit',
          name: 'edit',
          inputDelta: '{"filePath":"lib/live.dart"}',
        ),
      );

      await testNocterm(
        'vibe open segment merges persisted and live boxes',
        (tester) async {
          await tester.pumpComponent(
            MultiBlocProvider(
              providers: [
                BlocProvider<SessionCubit>.value(
                  value: sessionController.cubit,
                ),
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
                  height: 24,
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

          final rendered = tester.renderToString(showBorders: false);
          expect(
            RegExp(r'\bthink\b').allMatches(rendered),
            hasLength(1),
            reason: rendered,
          );
          expect(
            RegExp(r'\btools\b').allMatches(rendered),
            hasLength(1),
            reason: rendered,
          );
          expect(
            RegExp(r'\bfiles\b').allMatches(rendered),
            hasLength(1),
            reason: rendered,
          );
          expect(rendered, contains('251 tokens'));
          expect(rendered, contains('read x2:'));
          expect(rendered, contains('edit x2:'));
          expect(rendered, contains('base.dart +1 -1'));
          expect(rendered, contains('live.dart'));
        },
        size: const Size(120, 24),
      );
    },
  );

  test(
    'live edit on a file already in baseSegment mods dedupes to one row',
    () async {
      // Regression: when the persisted open segment already
      // reported a file edit (`baseSegment.mods.paths`) and the
      // current round is editing the same file, the streaming
      // bubble used to render two rows for the same basename —
      // once with the `+N -M` diff from the persisted segment,
      // once as a bare basename from the live edit. The two
      // sources also pass different path strings (raw
      // `args['filePath']` from the walker vs. the
      // `_extractFilePathFromJson` regex match on the streaming
      // JSON), so a string-keyed dedupe misses them.
      // Files-box dedupe is basename-based.
      const sessionId = 2;
      final session = Session(
        id: sessionId,
        title: 'Duplicate file dedup',
        model: '',
        projectPath: tempDir.path,
        status: SessionStatus.running,
      );
      // The persisted round: a completed edit on `lib/foo.dart`.
      // The walker dedupes by basename, so this populates
      // `baseSegment.mods.paths` with one entry for foo.dart.
      // (If the walker ever re-introduced the path-string
      // dup, this test would fail with TWO foo.dart rows
      // even before the live edit arrives.)
      final messages = <Message>[
        Message(
          id: 1,
          sessionId: sessionId,
          role: 'user',
          content: 'tweak foo',
        ),
        Message(
          id: 2,
          sessionId: sessionId,
          role: 'tool_call',
          content: '',
          toolCalls: const [
            ToolCallData(
              callId: 'persisted-edit',
              name: 'edit',
              input: {
                'filePath': 'lib/foo.dart',
                'oldString': 'old',
                'newString': 'new long string',
              },
            ),
          ],
        ),
        Message(
          id: 3,
          sessionId: sessionId,
          role: 'tool',
          toolCallId: 'persisted-edit',
          content: 'Edit applied',
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

      sessionController.runtime(sessionId)
        ..chatDisplayMode = ChatDisplayMode.vibe
        ..isResponding = true
        ..roundFirstTokenTime = DateTime.now();
      sessionController.mirrorTurnFlags(sessionId);

      // Live edit on the SAME file (foo.dart) with a DIFFERENT
      // path string (absolute, prefixed with the project root).
      // Without basename-based dedup, the rendering loop would
      // produce a second foo.dart row beneath the persisted
      // `foo.dart +N -M` row.
      streamingController.updateStreamingToolCall(
        sessionId,
        ToolUseChunk(
          index: 0,
          callId: 'live-edit',
          name: 'edit',
          inputDelta: '{"filePath":"${tempDir.path}/lib/foo.dart"',
        ),
      );

      await testNocterm(
        'live edit dedupes against persisted mods by basename',
        (tester) async {
          await tester.pumpComponent(
            MultiBlocProvider(
              providers: [
                BlocProvider<SessionCubit>.value(
                  value: sessionController.cubit,
                ),
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
                  height: 24,
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

          final rendered = tester.renderToString(showBorders: false);
          // One files box (title appears once).
          expect(
            RegExp(r'\bfiles\b').allMatches(rendered),
            hasLength(1),
            reason: rendered,
          );
          // Exactly one foo.dart row. A duplicate bare-basename
          // row from the live edit (the regression) would
          // produce 2 matches.
          final fooRows = RegExp(
            r'foo\.dart(?: \+\d+ -\d+)?',
          ).allMatches(rendered).length;
          expect(fooRows, 1, reason: rendered);
        },
        size: const Size(120, 24),
      );
    },
  );
}

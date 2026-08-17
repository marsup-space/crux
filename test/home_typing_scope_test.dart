// Regression guard for the quick-chat input's repaint scope.
//
// Typing in home's new-chat field must only repaint the input row
// (and its popover): the dashboard boxes are NOT part of that
// subtree. The original wiring routed every keystroke through the
// chat panel's panel-wide setState, which rebuilt the whole home
// grid (~10 boxes, ~26ms of layout per frame) and made typing feel
// laggy. This test mounts a counting box beside the full-featured
// quick-chat input (real InputOverlay + InputKeyHandler over a real
// SessionController, all against a temp store — no LLM calls) and
// asserts the box's build count doesn't move while typing.

import 'dart:io';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/input_keys.dart';
import 'package:crux/src/components/input_overlay.dart';
import 'package:crux/src/components/overlay_controller.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/ui/toast.dart' show ToastMode;
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/theme/theme_config_store.dart';
import 'package:crux/src/theme/theme_controller.dart';
import 'package:crux/src/theme/theme_registry.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:test/test.dart';

/// A box that counts how many times home asks it to build.
class _CountingBox extends HomeWidget {
  int buildCount = 0;

  @override
  String get id => 'counting';

  @override
  String get title => 'counting';

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 2;

  @override
  void Function()? activate(HomeContext ctx) => null;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    buildCount++;
    return Text('counting box');
  }
}

void main() {
  test(
    'typing in the quick-chat field does not rebuild dashboard boxes',
    () async {
      await testNocterm('typing scope', (tester) async {
        final tempDir = await Directory.systemTemp.createTemp('crux_qc_');
        try {
          // Real production pieces over a temp store — same wiring as
          // context_bar_loaded_skills_e2e_test, minus the LLM paths.
          final providerService = ProviderService(
            userProvidersDir: tempDir.path,
          );
          await providerService.initialize();
          final store = SessionStore(CruxDatabase());
          final toolRegistry = ToolRegistry()
            ..registerDefaults(
              FileReadTracker(),
              sessionStore: store,
              webProviderRegistry: WebProviderRegistry(),
            );
          final chatService = ChatService(
            store,
            providerService,
            LlmClient(),
            ToolExecutor(toolRegistry),
          );
          final sessionController = SessionController(
            store: store,
            providerService: providerService,
            chatService: chatService,
            refresh: () {},
          );

          final controller = TextEditingController();
          final overlayController = OverlayController(
            maxVisibleItems: 6,
            textController: controller,
            executeCommandCallback: (_) async {},
          );
          // Real production pieces over a temp store — same wiring as
          // context_bar_loaded_skills_e2e_test, minus the LLM paths.
          final gitStatusService = GitStatusService();
          final tracker = FileReadTracker();
          final streamingController = StreamingController(
            sessionController: sessionController,
            refresh: () {},
          );
          final orchestrator = ChatTurnOrchestrator(
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
          // The quick-chat area registers its local setState here; the
          // refresh callbacks below count fires so the assertion sees the
          // real production path (typing → overlay refresh), not just
          // controller mutation.
          var rebuilds = 0;
          void countRebuild() => rebuilds++;
          final themeController = await ThemeController.create(
            registry: ThemeRegistry(
              themes: {'dracula': CruxThemeData.draculaFallback},
              orderedIds: const ['dracula'],
            ),
            configStore: ThemeConfigStore(File('${tempDir.path}/theme.toml')),
          );
          final overlay = InputOverlay(
            overlayController: overlayController,
            sessionController: sessionController,
            providerService: providerService,
            providerServiceReady: true,
            webProviderRegistry: WebProviderRegistry(),
            themeController: themeController,
            recentProjectsStore: null,
            textController: controller,
            projectPath: tempDir.path,
            refresh: countRebuild,
            onStateChanged: countRebuild,
          );
          final keyHandler = InputKeyHandler(
            sessionController: sessionController,
            turnOrchestrator: orchestrator,
            onQuitRequest: () {},
            textController: controller,
            overlayController: overlayController,
            refresh: countRebuild,
            onStateChanged: countRebuild,
            getCommandStash: () => null,
            setCommandStash: (_) {},
          );

          final box = _CountingBox();
          await tester.pumpComponent(
            Container(
              width: 120,
              height: 40,
              child: CruxTheme(
                data: CruxThemeData.draculaFallback,
                child: HomeScreen(
                  onExit: () {},
                  widgets: [box],
                  context_: HomeContext.minimal(close: () {}),
                  overlayController: overlayController,
                  inputController: controller,
                  inputOverlay: overlay,
                  inputKeyHandler: keyHandler,
                  onQuickChatAreaMounted: (_) {},
                ),
              ),
            ),
          );
          await tester.pump();
          final baseline = box.buildCount;
          expect(
            baseline,
            greaterThan(0),
            reason: 'the box built at least once',
          );
          // Sanity: the dashboard is on screen.
          expect(
            tester.terminalState.findText('counting box').isNotEmpty,
            isTrue,
          );

        // Simulate the user typing three characters. Each mutation is
        // what the TextField does per keystroke; in production the
        // chat panel's controller listener then runs onTextChanged (the
        // test has no panel, so that hop is replicated inline).
        for (final ch in ['h', 'e', 'l']) {
          controller.text += ch;
          controller.selection = TextSelection.collapsed(
            offset: controller.text.length,
          );
          overlay.onTextChanged();
          await tester.pump();
        }
        await tester.pump();await tester.pump();

          expect(
            box.buildCount,
            baseline,
            reason:
                'typing must only repaint the quick-chat area; the dashboard '
                'boxes keep their subtree (was ${box.buildCount}, baseline '
                '$baseline)',
          );
          expect(
            rebuilds,
            greaterThan(0),
            reason: 'the local rebuild path fired',
          );
        } finally {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }
      }, size: Size(120, 40));
    },
  );
}

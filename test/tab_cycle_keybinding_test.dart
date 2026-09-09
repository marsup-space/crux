// Wiring tests for the chat screen's Tab session-cycle shortcut.
//
// Plain Tab in the chat input (overlay off) must invoke the
// `onCycleSessions` callback wired by the chat panel; Shift+Tab and
// Tab while an overlay popover owns the keyboard must fall through.
// The cycle-order logic itself is covered by session_cycle_test.dart;
// this file only proves the key routing.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/input_keys.dart';
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
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;

void main() {
  late Directory tempDir;
  late ProviderService providerService;
  late SessionStore store;
  late SessionController sessionController;
  late ChatTurnOrchestrator orchestrator;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_tab_cycle_');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    await providerService.initialize();
    store = SessionStore(CruxDatabase());
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
    sessionController = SessionController(
      store: store,
      providerService: providerService,
      chatService: chatService,
      refresh: () {},
    );
    final streamingController = StreamingController(
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
      tracker: FileReadTracker(),
    );
  });

  tearDown(() async {
    sessionController.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // StreamingController needs no explicit teardown here — these tests
  // never start its timers.

  InputKeyHandler buildHandler({required void Function() onCycle}) {
    final controller = TextEditingController();
    final overlayController = OverlayController(
      maxVisibleItems: 6,
      textController: controller,
      executeCommandCallback: (_) async {},
    );
    return InputKeyHandler(
      sessionController: sessionController,
      turnOrchestrator: orchestrator,
      onQuitRequest: () {},
      onCycleSessions: onCycle,
      refresh: () {},
      onStateChanged: () {},
      textController: controller,
      overlayController: overlayController,
      getCommandStash: () => null,
      setCommandStash: (_) {},
    );
  }

  test('plain Tab invokes onCycleSessions and is consumed', () {
    var cycles = 0;
    final handler = buildHandler(onCycle: () => cycles++);

    final handled = handler.handleKeyEvent(
      KeyboardEvent(logicalKey: LogicalKey.tab),
    );

    expect(handled, isTrue);
    expect(cycles, 1);
  });

  test('Shift+Tab invokes onCycleSessionsPrevious and is consumed', () {
    var cycles = 0;
    var previous = 0;
    final controller = TextEditingController();
    final overlayController = OverlayController(
      maxVisibleItems: 6,
      textController: controller,
      executeCommandCallback: (_) async {},
    );
    final handler = InputKeyHandler(
      sessionController: sessionController,
      turnOrchestrator: orchestrator,
      onQuitRequest: () {},
      onCycleSessions: () => cycles++,
      onCycleSessionsPrevious: () => previous++,
      refresh: () {},
      onStateChanged: () {},
      textController: controller,
      overlayController: overlayController,
      getCommandStash: () => null,
      setCommandStash: (_) {},
    );

    final handled = handler.handleKeyEvent(
      KeyboardEvent(
        logicalKey: LogicalKey.tab,
        modifiers: const ModifierKeys(shift: true),
      ),
    );

    expect(handled, isTrue);
    expect(cycles, 0, reason: 'forward callback must not fire');
    expect(previous, 1, reason: 'backward callback fires');
  });

  test('Shift+Tab with a null previous callback falls through', () {
    var cycles = 0;
    final handler = buildHandler(onCycle: () => cycles++);

    final handled = handler.handleKeyEvent(
      KeyboardEvent(
        logicalKey: LogicalKey.tab,
        modifiers: const ModifierKeys(shift: true),
      ),
    );

    expect(handled, isFalse);
    expect(cycles, 0);
  });

  test('Ctrl+Tab does not cycle', () {
    var cycles = 0;
    final handler = buildHandler(onCycle: () => cycles++);

    final handled = handler.handleKeyEvent(
      KeyboardEvent(
        logicalKey: LogicalKey.tab,
        modifiers: const ModifierKeys(ctrl: true),
      ),
    );

    expect(handled, isFalse);
    expect(cycles, 0);
  });

  test('Tab with an open command overlay falls through to the picker', () {
    var cycles = 0;
    final controller = TextEditingController();
    final overlayController = OverlayController(
      maxVisibleItems: 6,
      textController: controller,
      executeCommandCallback: (_) async {},
    );
    final handler = InputKeyHandler(
      sessionController: sessionController,
      turnOrchestrator: orchestrator,
      onQuitRequest: () {},
      onCycleSessions: () => cycles++,
      refresh: () {},
      onStateChanged: () {},
      textController: controller,
      overlayController: overlayController,
      getCommandStash: () => null,
      setCommandStash: (_) {},
    );

    // Simulate the command picker owning the keyboard.
    overlayController.overlayMode = OverlayMode.command;

    final handled = handler.handleKeyEvent(
      KeyboardEvent(logicalKey: LogicalKey.tab),
    );

    // The command branch has no Tab binding → falls through.
    expect(handled, isFalse);
    expect(cycles, 0);
  });

  test('null onCycleSessions keeps Tab falling through (home quick-chat)', () {
    // No onCycleSessions callback, mirroring home's quick-chat wiring.
    final controller = TextEditingController();
    final overlayController = OverlayController(
      maxVisibleItems: 6,
      textController: controller,
      executeCommandCallback: (_) async {},
    );
    final bare = InputKeyHandler(
      sessionController: sessionController,
      turnOrchestrator: orchestrator,
      onQuitRequest: () {},
      refresh: () {},
      onStateChanged: () {},
      textController: controller,
      overlayController: overlayController,
      getCommandStash: () => null,
      setCommandStash: (_) {},
    );

    final handled = bare.handleKeyEvent(
      KeyboardEvent(logicalKey: LogicalKey.tab),
    );

    expect(handled, isFalse);
  });
}

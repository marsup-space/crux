// Tests for the context bar's session-switch snap behavior.
//
// Two layered fixes keep the bar from animating across session
// boundaries:
//
// 1. `_tick()` carries a `_currentSessionId != sessionId` guard
//    so a 16ms timer tick that lands between `switchSession`
//    updating `currentSessionId` and the next chat-panel rebuild
//    snaps to the new target instead of lerping from the old
//    session's value.
//
// 2. `SessionController.switchSession` is ordered so that
//    `currentSessionId` and the new session's
//    `contextTargetTokens` are committed in the SAME microtask
//    — with no awaits between them. Without that, a tick that
//    landed during the `await loadMessages` window would snap
//    to the OLD session's `contextTargetTokens` (still sitting
//    in the runtime), then once the target reset finally landed
//    the bar would lerp from that stale snap value toward the
//    real new target — visually indistinguishable from the
//    original "lerp across sessions" bug. The atomic commit
//    closes that window.

import 'dart:io';

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';

import 'package:crux/src/components/context_bar.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/ticker_registry.dart';

void main() {
  group('ContextBar session switch snap', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late SessionController sessionController;
    late StreamingController streamingController;

    setUp(() async {
      TickerRegistry.instance.resetForTest();
      tempDir = await Directory.systemTemp.createTemp('crux_ctxbar_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      await providerService.initialize();
      store = SessionStore(CruxDatabase());
      final toolRegistry = ToolRegistry()
        ..registerDefaults(FileReadTracker(), sessionStore: store);
      sessionController = SessionController(
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
      streamingController = StreamingController(
        sessionController: sessionController,
        refresh: () {},
      );
    });

    tearDown(() async {
      TickerRegistry.instance.resetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Drive the bar through the real `SessionController.switchSession`
    /// path. This is the path the chat panel uses in production, and
    /// it's where the atomic-commit bug lived (an `await loadMessages`
    /// between the `currentSessionId` flip and the target reset).
    Future<void> mountAndSwitchTo({
      required int initialSessionId,
      required int targetSessionId,
      required int initialTarget,
      required int newTarget,
      required int contextMax,
      required bool newIsResponding,
      required Future<void> Function(int) pump,
    }) async {
      // Seed the controller with both sessions and a known
      // initial streaming state on session A.
      sessionController.sessions = [
        Session(
          id: initialSessionId,
          title: 'A',
          model: 'test/model',
          status: SessionStatus.idle,
          contextTokens: initialTarget,
        ),
        Session(
          id: targetSessionId,
          title: 'B',
          model: 'test/model',
          status: SessionStatus.idle,
          contextTokens: newTarget,
        ),
      ];
      sessionController.currentSessionId = initialSessionId;
      final rtA = sessionController.runtime(initialSessionId);
      rtA.contextTargetTokens = initialTarget;
      rtA.isResponding = true;

      await pump(initialSessionId);

      // Now go through the real `switchSession` path, which is
      // async and contains the await window that used to leak
      // the old `contextTargetTokens` into a snap.
      await sessionController.switchSession(targetSessionId);
      if (newIsResponding) {
        sessionController.runtime(targetSessionId).isResponding = true;
      }
    }

    test('bar snaps to new session value via real switchSession '
        '(regression: target reset leaked through the loadMessages '
        'await, causing a brief lerp from the old session\'s '
        'contextTargetTokens)', () async {
      await testNocterm('context bar session switch snap', (tester) async {
        // 200 * 1024 → `_fmtCtx` renders as "200k". 200,000 and
        // 5,000 are far enough apart that one 16ms lerp tick
        // (≈1,872 tokens of movement at lerpSpeed=6) can't bridge
        // them — the post-tick value is unambiguously one or the
        // other, so a substring match is unambiguous.
        const contextMax = 200 * 1024;

        await mountAndSwitchTo(
          initialSessionId: 1,
          targetSessionId: 2,
          initialTarget: 200000,
          newTarget: 5000,
          contextMax: contextMax,
          newIsResponding: false,
          pump: (_) async {
            await tester.pumpComponent(
              Column(
                children: [
                  ContextBar(
                    sessionController: sessionController,
                    streamingController: streamingController,
                    contextMaxTokens: contextMax,
                  ),
                ],
              ),
            );
          },
        );

        // Sanity: bar should be showing session A's value, not B's.
        expect(
          tester.terminalState.findText('200,000 / 200k').isNotEmpty,
          isTrue,
          reason: 'bar should initially show session A\'s context value',
        );
        expect(
          tester.terminalState.findText('5,000 / 200k').isEmpty,
          isTrue,
          reason: 'bar should NOT show session B\'s value yet',
        );

        // Advance the clock through the `await loadMessages` window
        // that lives inside `switchSession`. This is exactly where
        // the old ordering (currentSessionId flip *before* target
        // reset) leaked the old session's `contextTargetTokens`
        // into a snap. With the atomic commit, the timer can't see
        // a half-flipped state — both fields move together.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        // The bar must show session B's base value. If the atomic
        // commit is broken, the snap would have used session A's
        // stale target (≈200,000) and the subsequent target reset
        // would have lerped down — we'd see ~198,128 here instead.
        expect(
          tester.terminalState.findText('5,000 / 200k').isNotEmpty,
          isTrue,
          reason: 'bar should snap to session B\'s base after '
              'switchSession commits currentSessionId + target atomically',
        );
      });
    });
  });
}
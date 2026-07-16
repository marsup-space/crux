// Tests for the [ContextBar]'s hover hint content listing the
// currently-loaded skills in the session.
//
// The hint lives on the [ContextBar] (not the toolbar), reads from
// `SessionRuntimeState.loadedSkillNames`, and — per the user's spec —
// always renders, even when the set is empty. The empty state reads
// `Loaded skills : none` as a positive "this feature works, just
// nothing loaded yet" signal.

import 'dart:io';

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;

import 'package:crux/src/components/context_bar.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/ticker_registry.dart';

void main() {
  // The hint is global state (HintController.instance), so always
  // start each test from a clean slate — a leftover hint from a
  // prior test would otherwise bleed into the assertions below.
  tearDown(() => HintController.instance.hide());

  group('ContextBar hover hint — loaded skills', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late SessionController sessionController;
    late StreamingController streamingController;

    setUp(() async {
      TickerRegistry.instance.resetForTest();
      tempDir = await Directory.systemTemp.createTemp('crux_ctxbar_hint_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      await providerService.initialize();
      store = SessionStore(CruxDatabase());
      final toolRegistry = ToolRegistry()
        ..registerDefaults(
          FileReadTracker(),
          sessionStore: store,
          webProviderRegistry: WebProviderRegistry(),
        );
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

    /// Mount the bar wrapped in [HintOverlay] so the hover tooltip
    /// can actually render. Without the overlay the
    /// [HintStateMixin]-driven MouseRegion fires but nothing paints
    /// the hint on screen.
    Future<void> mountBar(NoctermTester tester) async {
      await tester.pumpComponent(
        HintOverlay(
          child: Column(
            children: [
              ContextBar(
                sessionController: sessionController,
                streamingController: streamingController,
                contextMaxTokens: 200 * 1024,
              ),
            ],
          ),
        ),
      );
    }

    /// Find the X coordinate of any non-space cell in row 0 — the
    /// bar paints its token-count label there, so a non-space cell
    /// is guaranteed to be on the bar. The bar's exact X depends on
    /// the surrounding Column's layout (the bar uses a custom
    /// render object that fixes its own width but doesn't pin its
    /// position in the parent), so we discover it dynamically
    /// instead of hardcoding.
    int findBarCellX(NoctermTester tester) {
      final width = tester.terminalState.size.width.toInt();
      for (var x = 0; x < width; x++) {
        final ch = tester.terminalState.getCellAt(x, 0)?.char;
        if (ch != null && ch != ' ') return x;
      }
      fail('no bar cell found in row 0 — did the bar render?');
    }

    /// Drive a mouse-enter at the bar's visible cell (row 0,
    /// the bar's label column) and pump past the 500 ms default
    /// delay so the hint becomes visible.
    Future<void> hoverBarAndSettle(NoctermTester tester) async {
      final x = findBarCellX(tester);
      await tester.hover(x, 0);
      await tester.pump();
      // Default [HintStateMixin.hintDelay] is 500 ms. Pump past
      // that so the controller's pending timer fires and the hint
      // becomes visible — without the wait, `visible` is still
      // `false` even when `activeHint` is populated.
      await tester.pump(const Duration(milliseconds: 600));
    }

    test(
        'hint shows the merged usage + skills content; empty '
        'skills render as `Loaded skills : none`', () async {
      await testNocterm('hint empty', (tester) async {
        sessionController.sessions = [
          Session(
            id: 1,
            title: 'A',
            model: 'test/model',
            status: SessionStatus.idle,
            contextTokens: 0,
          ),
        ];
        sessionController.currentSessionId = 1;
        // Sanity: empty set up front.
        expect(sessionController.runtime(1).loadedSkillNames, isEmpty);
        await mountBar(tester);
        await hoverBarAndSettle(tester);
        // The hint is the usage block + a blank line + the
        // loaded-skills line. With no skills loaded, the last
        // line reads `Loaded skills : none` so the user gets a
        // positive "feature works, just empty" signal rather than
        // a missing section.
        expect(HintController.instance.visible, isTrue);
        expect(
          HintController.instance.activeHint,
          'Context window usage.\n'
              'Click to compact the session history.\n'
              '\n'
              'Loaded skills : none',
        );
      }, size: const Size(80, 20));
    });

    test(
        'hint lists loaded skills when present, alphabetical order, '
        'still merged with the usage block', () async {
      await testNocterm('hint populated', (tester) async {
        sessionController.sessions = [
          Session(
            id: 1,
            title: 'A',
            model: 'test/model',
            status: SessionStatus.idle,
            contextTokens: 0,
          ),
        ];
        sessionController.currentSessionId = 1;
        // Insertion order is unrelated to alphabetical — the hint
        // sorts internally so the tooltip text is stable across
        // mid-stream additions.
        sessionController.runtime(1).loadedSkillNames
            .addAll({'zeta', 'alpha', 'mu'});
        await mountBar(tester);
        await hoverBarAndSettle(tester);
        expect(HintController.instance.visible, isTrue);
        expect(
          HintController.instance.activeHint,
          'Context window usage.\n'
              'Click to compact the session history.\n'
              '\n'
              'Loaded skills : alpha, mu, zeta',
        );
      }, size: const Size(80, 20));
    });

    test(
        'hint reflects the running-state wording when the session '
        'is responding (compaction gated)', () async {
      await testNocterm('hint running', (tester) async {
        sessionController.sessions = [
          Session(
            id: 1,
            title: 'A',
            model: 'test/model',
            status: SessionStatus.running,
            contextTokens: 0,
          ),
        ];
        sessionController.currentSessionId = 1;
        // Production wires this in [ChatToolbar._buildContextBar]:
        //   disabled: isSessionRunning,
        // The bar passes that flag through to its [hintContent] so
        // the merged hint's first block reflects the gated wording
        // while the agent is streaming.
        await tester.pumpComponent(
          HintOverlay(
            child: Column(
              children: [
                ContextBar(
                  sessionController: sessionController,
                  streamingController: streamingController,
                  contextMaxTokens: 200 * 1024,
                  disabled: true,
                ),
              ],
            ),
          ),
        );
        await hoverBarAndSettle(tester);
        expect(
          HintController.instance.activeHint,
          contains('Compaction unavailable while the agent is responding.'),
          reason: 'running sessions must show the gated wording, not '
              'the click-to-compact wording',
        );
        expect(
          HintController.instance.activeHint,
          isNot(contains('Click to compact the session history.')),
        );
      }, size: const Size(80, 20));
    });

    test(
        'hint is hidden when there is no active session — prevents '
        '`runtime(null)` from crashing the tooltip resolver',
        () async {
      await testNocterm('hint no session', (tester) async {
        // No sessions mounted; the bar still builds (renders a
        // SizedBox). The hint should hide because the resolver
        // short-circuits on `currentSessionId == null`.
        await tester.pumpComponent(
          HintOverlay(
            child: Column(
              children: [
                ContextBar(
                  sessionController: sessionController,
                  streamingController: streamingController,
                  contextMaxTokens: 200 * 1024,
                ),
              ],
            ),
          ),
        );
        await tester.hover(0, 0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(HintController.instance.activeHint, isNull);
      }, size: const Size(80, 20));
    });

    test(
        'hintMaxLines grows with the skill count — single-line '
        'hint with 4 skills (no wrap) stays at the 4-line floor, '
        'a 20-skill session grows the tooltip to fit the full '
        'inventory', () async {
      // The user's complaint was that the tooltip was capped at 4
      // lines regardless of how many skills were loaded. We assert
      // the per-source override directly via [findState] — the
      // mixin reads [hintMaxLines] in `_updateHint` and passes it
      // to [HintController.show], so the getter returning a
      // larger value is what lets the overlay's `_HintTooltip`
      // grow past the 4-line default.
      await testNocterm('hintMaxLines scales', (tester) async {
        sessionController.sessions = [
          Session(
            id: 1,
            title: 'A',
            model: 'test/model',
            status: SessionStatus.idle,
            contextTokens: 0,
          ),
        ];
        sessionController.currentSessionId = 1;
        await tester.pumpComponent(
          HintOverlay(
            child: Column(
              children: [
                ContextBar(
                  sessionController: sessionController,
                  streamingController: streamingController,
                  contextMaxTokens: 200 * 1024,
                ),
              ],
            ),
          ),
        );

        // 1. Empty runtime: floor of 4 lines (the overlay's default
        //    height for the merged "usage + Loaded skills : none"
        //    hint — using less would clip the usage block).
        final emptyState =
            tester.findState<ContextBarState>();
        expect(emptyState.hintMaxLines, 4,
            reason: 'empty runtime must use the 4-line floor so the '
                'usage block + `Loaded skills : none` fit');

        // 2. Many skills: the hint grows to fit the comma-joined
        //    list. Build 20 names of ~10 chars each; joined that's
        //    ~240 chars. At a 40-cell tooltip width, that's 6
        //    wrap lines; +3 for usage block = 9 lines.
        final rt = sessionController.runtime(1);
        rt.loadedSkillNames.addAll({
          'alpha-skill', 'beta-skill', 'gamma-skill', 'delta-skill',
          'epsilon-skill', 'zeta-skill', 'eta-skill', 'theta-skill',
          'iota-skill', 'kappa-skill', 'lambda-skill', 'mu-skill',
          'nu-skill', 'xi-skill', 'omicron-skill', 'pi-skill',
          'rho-skill', 'sigma-skill', 'tau-skill', 'upsilon-skill',
        });
        final populatedState =
            tester.findState<ContextBarState>();
        expect(populatedState.hintMaxLines, greaterThan(4),
            reason:
                '20 skills must produce a taller tooltip than the '
                'empty-state 4-line floor — otherwise the comma-joined '
                'list gets truncated by the overlay default');
        // Sanity: the 4-line overlay default is what the user
        // complained about; this assertion proves we exceed it.
        expect(populatedState.hintMaxLines, greaterThanOrEqualTo(8),
            reason: 'rough lower bound — 20 skills + 3 fixed lines + '
                '6 wrap lines of skill list = ~9 lines');
      }, size: const Size(80, 30));
    });
  });
}
// End-to-end test for the loaded-skills hover hint on the [ContextBar].
//
// Wires the real production pieces together:
//   1. A [SessionController] with a real [SessionStore] and a
//      minimal [ProviderService] stub (no LLM calls).
//   2. A discovered [SkillInfo] written to a temp skill root so
//      `expandSkillChips` can resolve a `$skill-name` chip.
//   3. The chip-substitution + runtime-write path the production
//      `chat_turn_orchestrator.sendTurn` uses (we replicate the
//      write directly because the orchestrator spins up the LLM
//      service — but the side effect under test, "mutate the
//      runtime's loadedSkillNames set", is identical).
//   4. The [ContextBar] mounted inside a [HintOverlay] so the
//      hover tooltip can actually render.
//   5. A [nocterm] mouse event delivered to the bar's visible
//      cell, the default 500 ms delay pumped past, and the
//      resulting [HintController.activeHint] asserted.
//
// The point: prove the full sequence the user actually executes
// (type a `$skill-name` chip → submit → hover the bar) produces
// the expected hint. Earlier tests covered each piece in
// isolation; this one stitches them together.

import 'dart:io';

import 'package:crux/src/components/context_bar.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/skills/skill_discovery.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/skill_chip_substitution.dart';
import 'package:crux/src/utils/ticker_registry.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:test/test.dart';

void main() {
  // The hint is global state (HintController.instance). Start each
  // test from a clean slate so a leftover hint from a prior test
  // doesn't bleed into the next assertion.
  tearDown(() => HintController.instance.hide());

  group('ContextBar loaded-skills hint — end to end', () {
    late Directory tempDir;
    late Directory skillRoot;
    late ProviderService providerService;
    late SessionStore store;
    late SessionController sessionController;
    late StreamingController streamingController;

    setUp(() async {
      TickerRegistry.instance.resetForTest();
      tempDir = await Directory.systemTemp.createTemp('crux_e2e_');
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

      // Lay down a real skill on disk so `expandSkillChips` can
      // resolve `$e2e-skill`. `discoverSkills(cwd: ...)` walks
      // `<cwd>/.agents/skills/<name>/SKILL.md` by default — using
      // a temp dir as cwd keeps the test hermetic.
      skillRoot = await Directory('${tempDir.path}/.agents/skills/e2e-skill')
          .create(recursive: true);
      await File('${skillRoot.path}/SKILL.md').writeAsString('''
---
name: e2e-skill
description: A skill written by the e2e test to exercise the chip path.
---
# E2E Skill

Body of the skill — irrelevant; the e2e test only checks that the
*name* gets tracked, not that the body gets rendered anywhere.
''');
    });

    tearDown(() async {
      TickerRegistry.instance.resetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Mount the bar inside a [HintOverlay] so the hover tooltip
    /// can actually paint. The [Column] wrapper plus terminal size
    /// give the bar proper layout constraints; without them the
    /// custom render object's `performLayout` runs but the parent
    /// constraints may be unbounded.
    Future<void> mountBar(NoctermTester tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 5,
          child: HintOverlay(
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
        ),
      );
    }

    /// Walk row 0 to find the bar's first non-space cell. The bar
    /// uses a custom render object that pins its own width but
    /// doesn't pin its position in the parent, so hardcoding
    /// `(0, 0)` would miss the bar entirely on most layouts.
    int findBarCellX(NoctermTester tester) {
      final width = tester.terminalState.size.width.toInt();
      for (var x = 0; x < width; x++) {
        final ch = tester.terminalState.getCellAt(x, 0)?.char;
        if (ch != null && ch != ' ') return x;
      }
      fail('no bar cell found in row 0 — did the bar render?');
    }

    /// Drive a hover at the bar's visible cell, then pump past the
    /// default 500 ms delay so the tooltip's pending timer fires
    /// and the controller flips `visible` to true.
    Future<void> hoverAndSettle(NoctermTester tester) async {
      final x = findBarCellX(tester);
      await tester.hover(x, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    test('submitting a dollar-prefixed chip adds the name to the '
        'runtime and the bar hover hint reflects it', () async {
      await testNocterm('e2e chip submit', (tester) async {
        // 1. Mount the bar in an idle session — the hint should
        //    initially read `Loaded skills : none`.
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
        await mountBar(tester);
        await hoverAndSettle(tester);
        expect(
          HintController.instance.activeHint,
          contains('Loaded skills : none'),
          reason: 'sanity: empty runtime must read `none`',
        );

        // 2. Replicate the production chip-substitution + write
        //    path. `chat_turn_orchestrator.sendTurn` does exactly
        //    this when the user submits a message with a chip
        //    (see lib/src/components/chat_turn_orchestrator.dart
        //    line 184). We avoid calling the orchestrator directly
        //    because it spins up the LLM service — the side
        //    effect under test is "resolve the chip + mutate the
        //    runtime's loadedSkillNames set".
        final expansion = expandSkillChips(
          input: 'please review \$e2e-skill by EOD',
          available: discoverSkills(cwd: tempDir.path),
        );
        expect(expansion.includedSkills, [
          'e2e-skill',
        ], reason: 'discoverSkills should resolve the test skill');
        final rt = sessionController.runtime(1);
        rt.loadedSkillNames.addAll(expansion.includedSkills);

        // 3. The chat panel's `_refresh()` would normally trigger a
        //    rebuild here. The mixin's mouse-wiring re-reads
        //    `hintContent` on the next mouse event — so a second
        //    hover should surface the updated list. The first
        //    hover's tooltip is still painted; without a follow-up
        //    hover it stays stale (that's the
        //    `refreshHintFromLastEvent` contract: a stationary
        //    cursor only re-reads on rebuild).
        await mountBar(tester);
        await hoverAndSettle(tester);

        // 4. The merged hint must now include `e2e-skill` in the
        //    skills line AND keep the usage block.
        final hint = HintController.instance.activeHint!;
        expect(
          hint,
          contains('Context window usage.'),
          reason: 'usage block must remain after merging skills',
        );
        expect(hint, contains('Click to compact the session history.'));
        expect(
          hint,
          contains('Loaded skills : e2e-skill'),
          reason:
              'submitted chip name must surface in the skills '
              'section of the merged hint',
        );
        expect(hint, isNot(contains('Loaded skills : none')));
      }, size: const Size(80, 20));
    });

    test('mixing a chip-loaded skill with a tool-loaded skill '
        'produces a combined hint list', () async {
      await testNocterm('e2e both paths', (tester) async {
        // Mount a session and load one skill via the chip path.
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
        final rt = sessionController.runtime(1);

        // Chip path: expand a chip and add to the runtime.
        final expansion = expandSkillChips(
          input: '\$e2e-skill',
          available: discoverSkills(cwd: tempDir.path),
        );
        rt.loadedSkillNames.addAll(expansion.includedSkills);

        // Tool path: simulate `SkillTool.execute` succeeding for a
        // second skill. The real tool resolves a discovered skill
        // by name and adds it to `ctx.sessionRuntime?.loadedSkillNames`.
        // We bypass the real ToolContext plumbing because the
        // side effect under test is just the set mutation.
        rt.loadedSkillNames.add('synthetic-mid-turn-skill');

        await mountBar(tester);
        await hoverAndSettle(tester);

        // Both skills appear, alphabetical, comma-separated.
        final hint = HintController.instance.activeHint!;
        expect(
          hint,
          contains('Loaded skills : e2e-skill, synthetic-mid-turn-skill'),
        );
      }, size: const Size(80, 20));
    });
  });
}

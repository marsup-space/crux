// Regression coverage for the "null check operator on a null value"
// build error in [ChatToolbar] when `runtime == null` or the runtime
// has no loaded skills.
//
// The bug: the chips-block budget was computed as
// `LoadedSkillChips.widthBudget(names) + smallSpacer`. For an empty
// `names` set, `widthBudget` returns 0 — but the `+ smallSpacer`
// bumps the result to 1. The `showSkillChips` flag then evaluates
// to true on the width-budget check, but the actual builder returns
// null because `rt == null`. The `!` on the call site threw.
//
// The fix collapses `skillChipsW` back to 0 whenever no skills are
// loaded, so `showSkillChips` stays false and the `!` is never
// reached. These tests pin both branches of that fix.

import 'dart:io';

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;

import 'package:crux/src/components/chat_toolbar.dart';
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
  group('ChatToolbar — loaded-skill chips null safety', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late SessionController sessionController;
    late StreamingController streamingController;

    setUp(() async {
      TickerRegistry.instance.resetForTest();
      tempDir = await Directory.systemTemp.createTemp('crux_toolbar_chips_');
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

    /// Mount a [ChatToolbar] with the supplied runtime pointer.
    /// `runtime: null` exercises the "transient state" path that
    /// triggered the original `Null check operator used on a null
    /// value` error. A non-null runtime with an empty
    /// `loadedSkillNames` exercises the second branch of the same
    /// bug — the budget formula must collapse to zero when there's
    /// nothing to render.
    Future<void> mount(
      NoctermTester tester, {
      SessionController? controller,
      bool withSession = true,
    }) async {
      await tester.pumpComponent(
        Column(
          children: [
            ChatToolbar(
              sessionController:
                  controller ?? sessionController,
              streamingController: streamingController,
              providerService: providerService,
              providerServiceReady: true,
              runtime: withSession
                  ? sessionController.runtime(
                      sessionController.currentSessionId!)
                  : null,
              contextMaxTokens: 200 * 1024,
              onModelPressed: () {},
              onCompactPressed: () {},
              onAuxiliaryPressed: () {},
              onCycleThinking: (_) {},
            ),
          ],
        ),
      );
    }

    test(
        'mounts without throwing when runtime is null '
        '(regression: `_buildLoadedSkillChips(context)!` crashed '
        'the layout builder when no skills were loaded)', () async {
      await testNocterm('toolbar null runtime', (tester) async {
        // Bug repro: with no active session, the original code
        // computed `skillChipsW = 0 + smallSpacer = 1`, which
        // tripped the `showSkillChips` flag and led the layout
        // builder to evaluate `_buildLoadedSkillChips(context)!`
        // — that method returns null when `rt == null`, so the
        // `!` threw a `Null check operator used on a null value`
        // build error. With the fix, `skillChipsW` collapses to
        // 0 and the `!` is never reached.
        await mount(tester, withSession: false);
        // If the build crashed, `pumpComponent` would have
        // propagated the error; reaching this line means the
        // toolbar rendered successfully.
        expect(tester.terminalState, isNotNull);
      }, size: const Size(120, 5));
    });

    test(
        'mounts without throwing when runtime is attached but has '
        'no loaded skills '
        '(same regression, second branch)', () async {
      await testNocterm('toolbar empty skills', (tester) async {
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
        // Sanity: no skills loaded.
        expect(sessionController.runtime(1).loadedSkillNames, isEmpty);
        await mount(tester);
        expect(tester.terminalState, isNotNull);
      }, size: const Size(120, 5));
    });

    test(
        'mounts without throwing when runtime has loaded skills '
        '(the happy path)', () async {
      await testNocterm('toolbar with skills', (tester) async {
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
        sessionController.runtime(1).loadedSkillNames.add('alpha');
        await mount(tester);
        // The chip name must appear in the rendered output — a
        // regression where the budget check pushed the chips off
        // screen would show up here.
        expect(
          tester.terminalState.findText('alpha'),
          isNotEmpty,
        );
      }, size: const Size(120, 5));
    });
  });
}
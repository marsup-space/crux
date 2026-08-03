import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm.dart' as nocterm show isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/git_status_widget.dart';
import 'package:crux/src/components/home/widgets/quick_actions_widget.dart';
import 'package:crux/src/components/home/widgets/recent_sessions_widget.dart';
import 'package:crux/src/components/home/widgets/tokens_widget.dart';
import 'package:crux/src/components/home/widgets/workspace_widget.dart';
import 'package:crux/src/components/home/widgets/yesterday_widget.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/utils/run_metrics.dart';

/// Renders a widget's content (no box chrome) at a fixed width inside a
/// themed container, and returns the tester for text assertions.
Future<void> _pump(
  NoctermTester tester,
  HomeWidget widget,
  HomeContext ctx,
) async {
  await tester.pumpComponent(
    Container(
      width: 60,
      height: 12,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Builder(
          builder: (context) => widget.build(context, ctx, 1),
        ),
      ),
    ),
  );
  await tester.pump();
}

HomeContext _ctx() => HomeContext.minimal(close: () {});

Session _session(
  int id,
  String title, {
  required DateTime updatedAt,
  String kind = '',
}) {
  return Session(id: id, title: title, kind: kind, updatedAt: updatedAt);
}

void main() {
  group('tokens', () {
    test('empty state when no LLM calls this run', () async {
      await testNocterm('tokens empty', (tester) async {
        final widget = TokensHomeWidget(
          snapshot: () => const RunMetricsSnapshot(
            duration: Duration.zero,
            turnCount: 0,
            totalTokensIn: 0,
            totalTokensOut: 0,
            cacheHitTokens: 0,
            cacheMissTokens: 0,
          ),
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('no LLM calls yet this run'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('renders real token breakdown', () async {
      await testNocterm('tokens data', (tester) async {
        final widget = TokensHomeWidget(
          snapshot: () => const RunMetricsSnapshot(
            duration: Duration(minutes: 3, seconds: 12),
            turnCount: 7,
            totalTokensIn: 12800,
            totalTokensOut: 3400,
            cacheHitTokens: 8000,
            cacheMissTokens: 2000,
          ),
        );
        await _pump(tester, widget, _ctx());
        expect(tester.terminalState.findText('7'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('12,800'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('3,400'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('3m 12s'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('80%'), nocterm.isNotEmpty);
      });
    });

    test('is passive (activate returns null)', () {
      expect(TokensHomeWidget().activate(_ctx()), isNull);
    });
  });

  group('git-status', () {
    test('empty state when not a git repo', () async {
      await testNocterm('git empty', (tester) async {
        final service = GitStatusService(); // starts as GitStatus.empty
        await _pump(tester, GitStatusHomeWidget(service), _ctx());
        expect(
          tester.terminalState.findText('not a git repository'),
          nocterm.isNotEmpty,
        );
        service.dispose();
      });
    });

    test('is actionable (refresh on activate)', () {
      final service = GitStatusService();
      expect(GitStatusHomeWidget(service).activate(_ctx()), isNotNull);
      service.dispose();
    });
  });

  group('recent-sessions', () {
    test('empty state when no sessions', () async {
      await testNocterm('recent empty', (tester) async {
        final widget = RecentSessionsHomeWidget(
          sessions: () => const [],
          currentSessionId: () => null,
          onSwitch: (_) => false,
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('no sessions yet'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('renders sessions most-recent first with a current marker',
        () async {
      await testNocterm('recent data', (tester) async {
        final now = DateTime.now();
        final widget = RecentSessionsHomeWidget(
          sessions: () => [
            _session(1, 'newest refactor', updatedAt: now),
            _session(2, 'older bugfix',
                updatedAt: now.subtract(const Duration(hours: 3))),
          ],
          currentSessionId: () => 1,
          onSwitch: (_) => true,
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('newest refactor'),
          nocterm.isNotEmpty,
        );
        expect(
          tester.terminalState.findText('older bugfix'),
          nocterm.isNotEmpty,
        );
        // The current session carries the ▸ marker.
        expect(tester.terminalState.findText('▸'), nocterm.isNotEmpty);
      });
    });

    test('activate switches to the most recent session and closes', () {
      var switchedTo = -1;
      var closed = false;
      final now = DateTime.now();
      final widget = RecentSessionsHomeWidget(
        sessions: () => [_session(9, 'x', updatedAt: now)],
        currentSessionId: () => null,
        onSwitch: (id) {
          switchedTo = id;
          return true;
        },
      );
      final ctx = HomeContext(
        runCommand: (_) => true,
        close: () => closed = true,
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activate(ctx)!();
      expect(switchedTo, 9);
      expect(closed, isTrue);
    });

    test('activate keeps home open when the switch is refused', () {
      var closed = false;
      final now = DateTime.now();
      final widget = RecentSessionsHomeWidget(
        sessions: () => [_session(9, 'x', updatedAt: now)],
        currentSessionId: () => null,
        onSwitch: (_) => false, // mid-stream refusal
      );
      final ctx = HomeContext(
        runCommand: (_) => true,
        close: () => closed = true,
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activate(ctx)!();
      expect(closed, isFalse);
    });

    test('is passive when the list is empty', () {
      final widget = RecentSessionsHomeWidget(
        sessions: () => const [],
        currentSessionId: () => null,
        onSwitch: (_) => true,
      );
      expect(widget.activate(_ctx()), isNull);
    });
  });

  group('yesterday', () {
    test('empty state when nothing was active yesterday', () async {
      await testNocterm('yesterday empty', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            // Updated today → not yesterday.
            _session(1, 'today work', updatedAt: DateTime(2024, 6, 15, 9)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('nothing active yesterday'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('summarizes sessions active yesterday', () async {
      await testNocterm('yesterday data', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            _session(1, 'morning thing', updatedAt: DateTime(2024, 6, 14, 8)),
            _session(2, 'evening thing', updatedAt: DateTime(2024, 6, 14, 20)),
            _session(3, 'today', updatedAt: DateTime(2024, 6, 15, 9)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('2 sessions active'),
          nocterm.isNotEmpty,
        );
        expect(
          tester.terminalState.findText('evening thing'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('is passive (activate returns null)', () {
      final widget = YesterdayHomeWidget(sessions: () => const []);
      expect(widget.activate(_ctx()), isNull);
    });
  });

  group('quick-actions', () {
    test('renders the default action rows', () async {
      await testNocterm('quick actions render', (tester) async {
        await _pump(
          tester,
          QuickActionsHomeWidget(seedInput: (_) {}),
          _ctx(),
        );
        expect(tester.terminalState.findText('/new'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('/chat'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('/project'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('primary action runs the first command and closes on success', () {
      var ran = '';
      var closed = false;
      final widget = QuickActionsHomeWidget(seedInput: (_) {});
      final ctx = HomeContext(
        runCommand: (c) {
          ran = c;
          return true;
        },
        close: () => closed = true,
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activate(ctx)!();
      expect(ran, '/new');
      expect(closed, isTrue);
    });

    test('primary action keeps home open when runCommand is refused', () {
      var closed = false;
      final widget = QuickActionsHomeWidget(seedInput: (_) {});
      final ctx = HomeContext(
        runCommand: (_) => false, // mid-stream refusal
        close: () => closed = true,
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activate(ctx)!();
      expect(closed, isFalse);
    });

    test('seed-only action seeds the input, never runs a command', () {
      var seeded = '';
      var ran = false;
      var closed = false;
      final widget = QuickActionsHomeWidget(
        seedInput: (t) => seeded = t,
        actions: const [
          QuickAction('/project', 'switch project…', '/project ', seed: true),
        ],
      );
      final ctx = HomeContext(
        runCommand: (_) {
          ran = true;
          return true;
        },
        close: () => closed = true,
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      // The box only has the seed action; activate runs actions.first.
      widget.activate(ctx)!();
      expect(seeded, '/project ');
      expect(ran, isFalse);
      expect(closed, isTrue);
    });

    test('moveSelection wraps within the action list', () {
      final widget = QuickActionsHomeWidget(seedInput: (_) {});
      expect(widget.itemCount, 4);
      expect(widget.selectedIndex, 0);
      widget.moveSelection(1);
      expect(widget.selectedIndex, 1);
      widget.moveSelection(-1);
      widget.moveSelection(-1); // wraps to last
      expect(widget.selectedIndex, 3);
      widget.moveSelection(1); // wraps to first
      expect(widget.selectedIndex, 0);
    });

    test('activateItem runs the chosen action, not always the first', () {
      var ran = '';
      final widget = QuickActionsHomeWidget(seedInput: (_) {});
      final ctx = HomeContext(
        runCommand: (c) {
          ran = c;
          return true;
        },
        close: () {},
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activateItem(ctx, 1)!(); // /chat, not /new
      expect(ran, '/chat');
    });
  });

  group('recent-sessions item selection', () {
    RecentSessionsHomeWidget threeSessions(List<Session> list) =>
        RecentSessionsHomeWidget(
          sessions: () => list,
          currentSessionId: () => null,
          onSwitch: (_) => true,
        );

    test('itemCount reflects the capped row count', () {
      final now = DateTime.now();
      final list = [
        for (var i = 0; i < 8; i++) _session(i, 's$i', updatedAt: now),
      ];
      final widget = threeSessions(list);
      expect(widget.itemCount, 5); // _maxRows caps at 5
    });

    test('activateItem switches to the chosen session', () {
      var switchedTo = -1;
      final now = DateTime.now();
      final widget = RecentSessionsHomeWidget(
        sessions: () => [
          _session(1, 'a', updatedAt: now),
          _session(2, 'b', updatedAt: now),
          _session(3, 'c', updatedAt: now),
        ],
        currentSessionId: () => null,
        onSwitch: (id) {
          switchedTo = id;
          return true;
        },
      );
      final ctx = HomeContext(
        runCommand: (_) => true,
        close: () {},
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => const [],
        currentSessionId: () => null,
        switchSession: (_) => false,
      );
      widget.activateItem(ctx, 2)!();
      expect(switchedTo, 3);
    });
  });

  group('workspace', () {
    HomeContext wsCtx({String path = '/work/crux', String? model = 'k/k3'}) {
      final now = DateTime.now();
      return HomeContext(
        runCommand: (_) => true,
        close: () {},
        seedInput: (_) {},
        gitStatusService: GitStatusService(),
        sessions: () => [
          _session(1, 'a', updatedAt: now),
          _session(2, 'b', updatedAt: now, kind: 'chat'),
        ],
        currentSessionId: () => 1,
        switchSession: (_) => false,
        projectPath: path,
        activeModel: () => model,
      );
    }

    test('renders dir, model, and workspace session count', () async {
      await testNocterm('workspace render', (tester) async {
        await _pump(tester, WorkspaceHomeWidget(), wsCtx());
        expect(tester.terminalState.findText('crux'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('k/k3'), nocterm.isNotEmpty);
        // Only the project session counts (the chat has empty
        // projectPath → excluded).
        expect(
          tester.terminalState.findText('1 in this workspace'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('shows a setup hint when no model is configured', () async {
      await testNocterm('workspace no model', (tester) async {
        await _pump(tester, WorkspaceHomeWidget(), wsCtx(model: null));
        expect(
          tester.terminalState.findText('no model — /provider to connect'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('is passive (activate returns null)', () {
      expect(WorkspaceHomeWidget().activate(_ctx()), isNull);
    });
  });
}

import 'dart:async';

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm.dart' as nocterm show isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/polling_coordinator.dart';
import 'package:crux/src/components/home/widgets/git_status_widget.dart';
import 'package:crux/src/components/home/widgets/coding_plan_widget.dart';
import 'package:crux/src/components/home/widgets/quick_actions_widget.dart';
import 'package:crux/src/components/home/widgets/recent_sessions_widget.dart';
import 'package:crux/src/components/home/widgets/setup_widget.dart';
import 'package:crux/src/components/home/widgets/settings_widget.dart';
import 'package:crux/src/components/home/widgets/skills_widget.dart';
import 'package:crux/src/components/home/widgets/tokens_widget.dart';
import 'package:crux/src/components/home/widgets/workspace_widget.dart';
import 'package:crux/src/components/home/widgets/yesterday_widget.dart';
import 'package:crux/src/services/auxiliary_service.dart' show YesterdaySummary;
import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/coding_plan_usage.dart';
import 'package:crux/src/models/credit_balance.dart';
import 'package:crux/src/models/daily_usage_stats.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/coding_plan_provider.dart';
import 'package:crux/src/services/providers/credit_balance_provider.dart';
import 'package:crux/src/services/providers/openai_compatible_provider.dart';
import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/theme/crux_theme.dart';

/// Renders a widget's content (no box chrome) at a fixed width inside a
/// themed container, and returns the tester for text assertions.
///
/// The host wires [HomeWidget.onChanged] to a rebuild — the same
/// contract HomeScreen honors via `_wireWidgetListeners`. Without it,
/// an async loader that lands after the first pump calls
/// `notifyChanged()` into the void and the terminal stays on the
/// "loading…" frame forever.
class _PumpHost extends StatefulComponent {
  final HomeWidget widget;
  final HomeContext ctx;

  const _PumpHost(this.widget, this.ctx);

  @override
  State<_PumpHost> createState() => _PumpHostState();
}

class _PumpHostState extends State<_PumpHost> {
  @override
  void initState() {
    super.initState();
    component.widget.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Component build(BuildContext context) {
    return Container(
      width: 60,
      height: 12,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Builder(
          builder: (context) =>
              component.widget.build(context, component.ctx, 1),
        ),
      ),
    );
  }
}

Future<void> _pump(
  NoctermTester tester,
  HomeWidget widget,
  HomeContext ctx,
) async {
  await tester.pumpComponent(_PumpHost(widget, ctx));
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

/// Test-only coding-plan provider with a deterministic snapshot (no HTTP).
class _FakeCodingPlanProvider extends AnthropicCompatibleProvider
    with CodingPlanProvider {
  _FakeCodingPlanProvider({this.intervalPct = 88, this.weeklyPct = 55});

  final int intervalPct;
  final int weeklyPct;

  @override
  String get name => 'fake';

  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    // Yield so a subscription registered right after `start*Polling`
    // still observes the immediate tick's snapshot.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return CodingPlanUsage(
      providerName: name,
      modelName: 'general',
      intervalRemainingPct: intervalPct,
      weeklyRemainingPct: weeklyPct,
      intervalRemains: const Duration(hours: 4, minutes: 32),
      weeklyRemains: const Duration(days: 6, hours: 4),
      fetchedAt: DateTime.now(),
    );
  }
}

/// Test-only credit-balance provider with a deterministic balance (no HTTP).
class _FakeCreditBalanceProvider extends OpenAICompatibleProvider
    with CreditBalanceProvider {
  _FakeCreditBalanceProvider({this.totalBalance = '110.00'});

  final String totalBalance;

  @override
  String get name => 'fake';

  @override
  Future<CreditBalance> getCreditBalance() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return CreditBalance(
      providerName: name,
      isAvailable: true,
      balanceInfos: [
        BalanceInfo(
          currency: 'CNY',
          totalBalance: totalBalance,
          grantedBalance: '80.00',
          toppedUpBalance: '30.00',
        ),
      ],
      fetchedAt: DateTime.now(),
    );
  }
}

void main() {
  group('tokens', () {
    /// `'yyyy-MM-dd'` for the day [daysAgo] before [now].
    String dayKey(DateTime now, int daysAgo) {
      final d = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: daysAgo));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    test('empty state when no activity today', () async {
      await testNocterm('tokens empty', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => const {},
        );
        await _pump(tester, widget, _ctx());
        await tester.pump(); // let the loader land
        expect(widget.title, 'Today');
        expect(
          tester.terminalState.findText('no activity'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('renders one horizontal bar per model, busiest first', () async {
      await testNocterm('tokens today', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(
              tokens: 17800,
              turns: 34,
              sessions: 3,
              byModel: {'claude-opus-4': 12800, 'gpt-5.2': 5000},
            ),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        expect(widget.title, 'Today');
        // Both models show, labelled with a compact count.
        expect(tester.terminalState.findText('claude-opus-4'), isNotEmpty);
        expect(tester.terminalState.findText('gpt-5.2'), isNotEmpty);
        expect(tester.terminalState.findText('12.8k'), isNotEmpty);
        expect(tester.terminalState.findText('5k'), isNotEmpty);
        // Turns/sessions stay visible on a trailing one-liner.
        expect(
          tester.terminalState.findText('turns 34 · sessions 3'),
          isNotEmpty,
        );
      });
    });

    test('bars sort by descending usage regardless of map order', () async {
      await testNocterm('tokens bars sorted', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(
              tokens: 1000,
              byModel: {'aaa-small': 100, 'bbb-big': 900},
            ),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        // The busiest model's bar sits above the smaller one.
        final big = tester.terminalState.findText('bbb-big').single;
        final small = tester.terminalState.findText('aaa-small').single;
        expect(big.y, lessThan(small.y));
      });
    });

    test('more models than fit the box scroll into view', () async {
      await testNocterm('tokens bars scroll', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        // 8 models: 8 bar rows + 1 summary line, taller than the box's
        // 5-row viewport — the box chrome's scrollview must clip (not
        // overflow) and let the wheel bring the rest into view.
        // Values descend with the index so the busiest (model-01)
        // tops the chart and the quiet tail (model-08) is clipped
        // below the fold — matching the busiest-first sort.
        final byModel = <String, int>{
          for (var i = 1; i <= 8; i++) 'model-0$i': 900 - i * 100,
        };
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): DailyUsageStats(tokens: 3600, byModel: byModel),
          },
        );
        final base = HomeContext.minimal(close: () {});
        final ctx = HomeContext(
          runCommand: (_) => true,
          close: () {},
          seedInput: (_) {},
          gitStatusService: base.gitStatusService,
          sessions: () => const [],
          currentSessionId: () => null,
          switchSession: (_) => false,
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: HomeScreen(
                onExit: () {},
                widgets: [widget],
                context_: ctx,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(); // loader lands
        expect(widget.title, 'Today');

        // Sorted busiest-first: model-01 tops the chart; the tail
        // (model-08) is clipped below the fold.
        expect(tester.terminalState.findText('model-01'), isNotEmpty);
        expect(tester.terminalState.containsText('model-08'), isFalse);

        // Wheel down over the box → the clipped tail scrolls into view.
        final top = tester.terminalState.findText('model-01').first;
        for (var i = 0; i < 2; i++) {
          await tester.sendMouseEvent(
            MouseEvent(
              button: MouseButton.wheelDown,
              x: top.x + 2,
              y: top.y,
              pressed: false,
            ),
          );
          await tester.pump();
        }
        expect(tester.terminalState.containsText('model-08'), isTrue);
      }, size: const Size(80, 24));
    });

    test('falls back to plain totals without a per-model breakdown', () async {
      await testNocterm('tokens legacy totals', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(
              tokens: 12800,
              turns: 34,
              sessions: 3,
            ),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        expect(tester.terminalState.findText('12,800'), isNotEmpty);
        expect(tester.terminalState.findText('turns  34'), isNotEmpty);
        expect(tester.terminalState.findText('sessions  3'), isNotEmpty);
      });
    });

    test('‹ navigates to previous days, › back toward today', () async {
      await testNocterm('tokens navigate', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(tokens: 5000),
            dayKey(now, 1): const DailyUsageStats(tokens: 12800),
            dayKey(now, 3): const DailyUsageStats(tokens: 3400),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        // Defaults to today.
        expect(widget.title, 'Today');
        expect(tester.terminalState.findText('5,000'), nocterm.isNotEmpty);

        // ‹ → yesterday.
        widget.goBack();
        await tester.pump();
        expect(widget.daysAgo, 1);
        expect(widget.title, 'Yesterday');
        expect(tester.terminalState.findText('12,800'), nocterm.isNotEmpty);

        // ‹ → 2 days ago (no data → empty state).
        widget.goBack();
        await tester.pump();
        expect(widget.daysAgo, 2);
        expect(widget.title, '2 days ago');
        expect(
          tester.terminalState.findText('no activity'),
          nocterm.isNotEmpty,
        );

        // ‹ → 3 days ago.
        widget.goBack();
        await tester.pump();
        expect(widget.title, '3 days ago');
        expect(tester.terminalState.findText('3,400'), nocterm.isNotEmpty);

        // › back toward today.
        widget.goForward();
        await tester.pump();
        expect(widget.daysAgo, 2);
        widget.goForward();
        widget.goForward();
        await tester.pump();
        expect(widget.daysAgo, 0);
        expect(widget.title, 'Today');
        // › at today is a no-op.
        widget.goForward();
        expect(widget.daysAgo, 0);
      });
    });

    test('empty today falls back to the latest day with activity', () async {
      await testNocterm('tokens empty-today fallback', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        // Today and yesterday are empty; 2 days ago has data.
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(tokens: 0),
            dayKey(now, 1): const DailyUsageStats(tokens: 0),
            dayKey(now, 3): const DailyUsageStats(tokens: 3400),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump(); // let the loader land + seeding settle
        // The box shifted its default view to 3 days ago — the most
        // recent day WITH activity (day 1 and 2 have none)… note day-2
        // is simply absent from the map; day 3 is the latest non-empty.
        expect(widget.daysAgo, 3);
        expect(widget.title, '3 days ago');
        expect(tester.terminalState.findText('3,400'), nocterm.isNotEmpty);

        // Manual navigation still works from the seeded day.
        widget.goForward();
        await tester.pump();
        expect(widget.daysAgo, 2);
        expect(widget.title, '2 days ago');
      });
    });

    test('today with activity keeps the default view', () async {
      await testNocterm('tokens today active', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(now, 0): const DailyUsageStats(tokens: 500),
            dayKey(now, 5): const DailyUsageStats(tokens: 99999),
          },
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        // Today has activity — no seeding, even though an older day is
        // busier.
        expect(widget.daysAgo, 0);
        expect(widget.title, 'Today');
        expect(tester.terminalState.findText('500'), nocterm.isNotEmpty);
      });
    });

    test('entirely empty window stays on today with the placeholder', () async {
      await testNocterm('tokens all empty', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {},
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        expect(widget.daysAgo, 0);
        expect(widget.title, 'Today');
        expect(
          tester.terminalState.findText('no activity'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('title switches to MM-DD beyond a week', () async {
      await testNocterm('tokens title date', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => const {},
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          widget.goBack();
        }
        await tester.pump();
        expect(widget.daysAgo, 8);
        // 8 days before 2024-06-15 is 2024-06-07.
        expect(widget.title, '06-07');
      });
    });

    test('‹ always enabled, › disabled at today', () async {
      await testNocterm('tokens buttons', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => const {},
        );
        await _pump(tester, widget, _ctx());
        await tester.pump();
        var buttons = widget.titleButtons!;
        expect(buttons[0].onPressed, isNotNull); // ‹ always available
        expect(buttons[1].onPressed, isNull); // › disabled at today

        widget.goBack();
        buttons = widget.titleButtons!;
        expect(buttons[1].onPressed, isNotNull); // › enabled once back
      });
    });

    test('[ ] keys navigate days on the home screen', () async {
      await testNocterm('tokens keys', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        String dayKey(int d) {
          final date = DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: d));
          return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
              '${date.day.toString().padLeft(2, '0')}';
        }

        final widget = TokensHomeWidget(
          now: () => now,
          loader: (_) async => {
            dayKey(0): const DailyUsageStats(tokens: 5000),
            dayKey(1): const DailyUsageStats(tokens: 12800),
          },
        );
        final base = HomeContext.minimal(close: () {});
        final ctx = HomeContext(
          runCommand: (_) => true,
          close: () {},
          seedInput: (_) {},
          gitStatusService: base.gitStatusService,
          sessions: () => const [],
          currentSessionId: () => null,
          switchSession: (_) => false,
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: HomeScreen(
                onExit: () {},
                widgets: [widget],
                context_: ctx,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(); // loader
        expect(widget.title, 'Today');

        // `[` → yesterday.
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.bracketLeft),
        );
        await tester.pump();
        expect(widget.title, 'Yesterday');
        expect(tester.terminalState.findText('12,800'), nocterm.isNotEmpty);

        // `]` → back to today.
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.bracketRight),
        );
        await tester.pump();
        expect(widget.title, 'Today');
        expect(tester.terminalState.findText('5,000'), nocterm.isNotEmpty);
      }, size: const Size(80, 24));
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

    test('renders sessions most-recent first with a current marker', () async {
      await testNocterm('recent data', (tester) async {
        final now = DateTime.now();
        final widget = RecentSessionsHomeWidget(
          sessions: () => [
            _session(1, 'newest refactor', updatedAt: now),
            _session(
              2,
              'older bugfix',
              updatedAt: now.subtract(const Duration(hours: 3)),
            ),
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
    test('empty state when nothing was active in the last 7 days', () async {
      await testNocterm('yesterday empty', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            // Updated today → outside the lookback window.
            _session(1, 'today work', updatedAt: DateTime(2024, 6, 15, 9)),
            // 8 days ago → just past the window.
            _session(2, 'old work', updatedAt: DateTime(2024, 6, 7, 9)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        expect(
          tester.terminalState.findText('nothing yesterday'),
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

    test('title says "Yesterday" when yesterday had activity', () {
      final now = DateTime(2024, 6, 15, 12);
      final widget = YesterdayHomeWidget(
        sessions: () => [
          _session(1, 'work', updatedAt: DateTime(2024, 6, 14, 8)),
        ],
        now: () => now,
      );
      expect(widget.title, 'Yesterday');
    });

    test('falls back to an earlier day when yesterday was quiet', () async {
      await testNocterm('yesterday lookback', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            // Nothing on 6/14 (yesterday); last activity 3 days ago.
            _session(1, 'older thing', updatedAt: DateTime(2024, 6, 12, 8)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        expect(widget.title, '3 days ago');
        expect(
          tester.terminalState.findText('1 session active'),
          nocterm.isNotEmpty,
        );
        expect(
          tester.terminalState.findText('older thing'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('keeps the "Yesterday" title when nothing was active all week', () {
      final widget = YesterdayHomeWidget(
        sessions: () => const [],
        now: () => DateTime(2024, 6, 15, 12),
      );
      expect(widget.title, 'Yesterday');
    });

    test('‹ navigates to the previous day, › back to the latest', () async {
      await testNocterm('yesterday navigate', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            // Active yesterday, 2 days ago, and 3 days ago.
            _session(1, 'yesterday work', updatedAt: DateTime(2024, 6, 14, 8)),
            _session(
              2,
              'two days ago work',
              updatedAt: DateTime(2024, 6, 13, 9),
            ),
            _session(
              3,
              'three days ago work',
              updatedAt: DateTime(2024, 6, 12, 9),
            ),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        // Opens on the most recent active day: yesterday.
        expect(widget.title, 'Yesterday');
        expect(widget.daysAgo, 1);

        // ‹ → previous day (2 days ago).
        widget.goBack();
        await tester.pump();
        expect(widget.daysAgo, 2);
        expect(widget.title, '2 days ago');
        expect(
          tester.terminalState.findText('two days ago work'),
          nocterm.isNotEmpty,
        );

        // ‹ again → 3 days ago.
        widget.goBack();
        await tester.pump();
        expect(widget.daysAgo, 3);
        expect(widget.title, '3 days ago');
        expect(
          tester.terminalState.findText('three days ago work'),
          nocterm.isNotEmpty,
        );

        // › → back toward the latest (2 days ago).
        widget.goLatest();
        await tester.pump();
        expect(widget.daysAgo, 2);
        // › again → yesterday (the latest active day).
        widget.goLatest();
        await tester.pump();
        expect(widget.daysAgo, 1);
        expect(widget.title, 'Yesterday');
        // › at the latest is a no-op.
        widget.goLatest();
        expect(widget.daysAgo, 1);
      });
    });

    test('‹ is capped at the 7-day window edge', () async {
      await testNocterm('yesterday navigate cap', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            _session(1, 'recent', updatedAt: DateTime(2024, 6, 14, 8)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        for (var i = 0; i < 10; i++) {
          widget.goBack();
        }
        await tester.pump();
        expect(widget.daysAgo, 7); // clamped at the window edge
        expect(widget.canGoBack, isFalse);
        expect(widget.title, '7 days ago');
      });
    });

    test('title buttons reflect navigation state', () async {
      await testNocterm('yesterday title buttons', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            _session(1, 'yesterday work', updatedAt: DateTime(2024, 6, 14, 8)),
          ],
          now: () => now,
        );
        await _pump(tester, widget, _ctx());
        var buttons = widget.titleButtons!;
        expect(buttons, hasLength(2));
        // At the latest active day: ‹ enabled, › disabled.
        expect(buttons[0].onPressed, isNotNull);
        expect(buttons[1].onPressed, isNull);

        // After stepping back, both are enabled (› can return).
        widget.goBack();
        buttons = widget.titleButtons!;
        expect(buttons[0].onPressed, isNotNull);
        expect(buttons[1].onPressed, isNotNull);
      });
    });

    test('no title buttons when nothing was active all week', () async {
      await testNocterm('yesterday no buttons', (tester) async {
        final widget = YesterdayHomeWidget(
          sessions: () => const [],
          now: () => DateTime(2024, 6, 15, 12),
        );
        await _pump(tester, widget, _ctx());
        expect(widget.titleButtons, isNull);
      });
    });

    test('title buttons render on the home screen and [ ] navigate', () async {
      await testNocterm('yesterday home screen', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            _session(1, 'yesterday work', updatedAt: DateTime(2024, 6, 14, 8)),
            _session(2, 'older work', updatedAt: DateTime(2024, 6, 13, 9)),
          ],
          now: () => now,
        );
        final base = HomeContext.minimal(close: () {});
        final ctx = HomeContext(
          runCommand: (_) => true,
          close: () {},
          seedInput: (_) {},
          gitStatusService: base.gitStatusService,
          sessions: widget.sessions,
          currentSessionId: () => null,
          switchSession: (_) => false,
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: HomeScreen(
                onExit: () {},
                widgets: [widget],
                context_: ctx,
              ),
            ),
          ),
        );
        await tester.pump();

        // Opens on yesterday; the ‹ › buttons render next to the title.
        expect(widget.title, 'Yesterday');
        expect(
          tester.terminalState.findText('‹').isNotEmpty,
          isTrue,
          reason: 'the ‹ button renders on the title row',
        );
        expect(tester.terminalState.findText('›').isNotEmpty, isTrue);

        // Hovering ‹ highlights it (raised background via the shared
        // Button component).
        final back = tester.terminalState.findText('‹').first;
        await tester.hover(back.x, back.y);
        await tester.pump();
        final hovered = tester.terminalState.getStyledText().where(
          (s) => s.text.contains('‹') && s.style.backgroundColor != null,
        );
        expect(
          hovered.isNotEmpty,
          isTrue,
          reason: 'hovering ‹ gives it a hover background',
        );

        // `[` → previous day (2 days ago); title + content follow.
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.bracketLeft),
        );
        await tester.pump();
        expect(widget.title, '2 days ago');
        expect(
          tester.terminalState.findText('older work').isNotEmpty,
          isTrue,
          reason: '[ navigates the box content to the previous day',
        );

        // `]` → back to the latest (yesterday).
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.bracketRight),
        );
        await tester.pump();
        expect(widget.title, 'Yesterday');
        expect(
          tester.terminalState.findText('yesterday work').isNotEmpty,
          isTrue,
        );

        // A mouse tap on the ‹ title button navigates a day back (the
        // click path, as opposed to the [ key above). › is disabled at
        // the latest day, so ‹ is the one to tap here.
        final back2 = tester.terminalState.findText('‹').first;
        await tester.tap(back2.x, back2.y);
        await tester.pump();
        expect(
          widget.title,
          '2 days ago',
          reason: 'tapping the ‹ title button navigates a day back',
        );
      }, size: const Size(80, 24));
    });

    test('renders the LLM summary when the summarizer returns one', () async {
      await testNocterm('yesterday summary', (tester) async {
        final now = DateTime(2024, 6, 15, 12);
        final widget = YesterdayHomeWidget(
          sessions: () => [
            _session(1, 'morning thing', updatedAt: DateTime(2024, 6, 14, 8)),
          ],
          now: () => now,
        );
        final ctx = HomeContext(
          runCommand: (_) => true,
          close: () {},
          seedInput: (_) {},
          gitStatusService: GitStatusService(),
          sessions: () => const [],
          currentSessionId: () => null,
          switchSession: (_) => false,
          summarizeYesterday: (_) async => (
            text: '- fixed the parser\n- shipped the home screen',
            daysAgo: 1,
          ),
        );
        await _pump(tester, widget, ctx);
        // Let the async summary land.
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(
          tester.terminalState.findText('- fixed the parser'),
          nocterm.isNotEmpty,
        );
        expect(
          tester.terminalState.findText('- shipped the home screen'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('shows a pending hint while the summary is in flight', () async {
      await testNocterm('yesterday pending', (tester) async {
        final widget = YesterdayHomeWidget(sessions: () => const []);
        final ctx = HomeContext(
          runCommand: (_) => true,
          close: () {},
          seedInput: (_) {},
          gitStatusService: GitStatusService(),
          sessions: () => const [],
          currentSessionId: () => null,
          switchSession: (_) => false,
          // Never completes → stays in the pending state.
          summarizeYesterday: (_) => Completer<YesterdaySummary?>().future,
        );
        await _pump(tester, widget, ctx);
        expect(
          tester.terminalState.findText('summarizing yesterday…'),
          nocterm.isNotEmpty,
        );
      });
    });

    test(
      'falls back to the session list when the summarizer returns null',
      () async {
        await testNocterm('yesterday null summary', (tester) async {
          final now = DateTime(2024, 6, 15, 12);
          final widget = YesterdayHomeWidget(
            sessions: () => [
              _session(1, 'morning thing', updatedAt: DateTime(2024, 6, 14, 8)),
            ],
            now: () => now,
          );
          final ctx = HomeContext(
            runCommand: (_) => true,
            close: () {},
            seedInput: (_) {},
            gitStatusService: GitStatusService(),
            sessions: () => const [],
            currentSessionId: () => null,
            switchSession: (_) => false,
            summarizeYesterday: (_) async => null,
          );
          await _pump(tester, widget, ctx);
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
          // Null summary → static fallback list.
          expect(
            tester.terminalState.findText('1 session active'),
            nocterm.isNotEmpty,
          );
          expect(
            tester.terminalState.findText('morning thing'),
            nocterm.isNotEmpty,
          );
        });
      },
    );
  });

  group('quick-actions', () {
    test('renders the default action rows', () async {
      await testNocterm('quick actions render', (tester) async {
        await _pump(tester, QuickActionsHomeWidget(seedInput: (_) {}), _ctx());
        expect(tester.terminalState.findText('/new'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('/chat'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('/project'), nocterm.isNotEmpty);
        final fresh = tester.terminalState.findText('/new').first;
        final chat = tester.terminalState.findText('/chat').first;
        expect(
          chat.y,
          fresh.y + 1,
          reason: 'each compact action occupies exactly one terminal row',
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

  group('coding-plan', () {
    test('declares id, title, span, and height', () {
      final widget = CodingPlanHomeWidget();
      expect(widget.id, 'coding-plan');
      expect(widget.title, 'Coding plan');
      expect(widget.supportedSpans, {1});
      expect(widget.heightFor(1), 4);
      expect(widget.verticallyCenter, isFalse);
    });

    test(
      'renders an empty state with no connected providers and is passive',
      () async {
        await testNocterm('coding-plan empty', (tester) async {
          await _pump(tester, CodingPlanHomeWidget(), _ctx());
          expect(
            tester.terminalState.findText('no usage data'),
            nocterm.isNotEmpty,
          );
          expect(CodingPlanHomeWidget().activate(_ctx()), isNull);
        });
      },
    );

    test('renders every connected provider with its name and usage', () async {
      await testNocterm('coding-plan all providers', (tester) async {
        final deepseek = _FakeCreditBalanceProvider(totalBalance: '110.00');
        final kimi = _FakeCodingPlanProvider(intervalPct: 88, weeklyPct: 55);
        final zhipu = _FakeCodingPlanProvider(intervalPct: 40, weeklyPct: 80);

        deepseek.startCreditBalancePolling(apiKey: 'x');
        kimi.startCodingPlanPolling(apiKey: 'x');
        zhipu.startCodingPlanPolling(apiKey: 'x');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        deepseek.stopCreditBalancePolling();
        kimi.stopCodingPlanPolling();
        zhipu.stopCodingPlanPolling();

        final entries = [
          ConnectedProviderUsage(name: 'deepseek', creditBalance: deepseek),
          ConnectedProviderUsage(name: 'kimi', codingPlan: kimi),
          ConnectedProviderUsage(name: 'zhipu', codingPlan: zhipu),
        ];
        final widget = CodingPlanHomeWidget(entriesOverride: () => entries);
        await _pump(tester, widget, _ctx());

        // DeepSeek → API credit (inline).
        expect(tester.terminalState.findText('DeepSeek'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('credit'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('¥110.00'), nocterm.isNotEmpty);

        // Kimi → 5h / 7d coding plan.
        expect(tester.terminalState.findText('Kimi'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('5h'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('88%'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('7d'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('55%'), nocterm.isNotEmpty);

        // Zhipu → distinct values prove per-provider separation.
        expect(tester.terminalState.findText('Zhipu'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('40%'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('80%'), nocterm.isNotEmpty);

        await deepseek.disposeCreditBalancePolling();
        await kimi.disposeCodingPlanPolling();
        await zhipu.disposeCodingPlanPolling();
      });
    });

    test(
      'hovering a coding-plan row swaps percentages for the countdown',
      () async {
        await testNocterm('coding-plan hover countdown', (tester) async {
          final kimi = _FakeCodingPlanProvider(intervalPct: 88, weeklyPct: 55);
          kimi.startCodingPlanPolling(apiKey: 'x');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          kimi.stopCodingPlanPolling();

          final entries = [
            ConnectedProviderUsage(name: 'kimi', codingPlan: kimi),
          ];
          final widget = CodingPlanHomeWidget(entriesOverride: () => entries);
          await _pump(tester, widget, _ctx());

          // Steady state shows percentages.
          expect(tester.terminalState.findText('88%'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('55%'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('4h 32m'), isEmpty);

          // Hover the row → percentages swap to the remaining-time countdown.
          await tester.hover(0, 0);
          expect(tester.terminalState.findText('4h 32m'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('6d 4h'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('88%'), isEmpty);
          expect(tester.terminalState.findText('55%'), isEmpty);

          // Hover away → percentages come back.
          await tester.hover(0, 5);
          expect(tester.terminalState.findText('88%'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('55%'), nocterm.isNotEmpty);
          expect(tester.terminalState.findText('4h 32m'), isEmpty);

          await kimi.disposeCodingPlanPolling();
        });
      },
    );

    test('shows a waiting state before the first snapshot', () async {
      await testNocterm('coding-plan waiting', (tester) async {
        final provider = _FakeCodingPlanProvider(); // no polling started
        final entries = [
          ConnectedProviderUsage(name: 'kimi', codingPlan: provider),
        ];
        final widget = CodingPlanHomeWidget(entriesOverride: () => entries);
        await _pump(tester, widget, _ctx());
        expect(tester.terminalState.findText('Kimi'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('waiting'), nocterm.isNotEmpty);
      });
    });

    test('activate refreshes every connected provider, else is passive', () {
      final cp = _FakeCodingPlanProvider();
      final cb = _FakeCreditBalanceProvider();
      final entries = [
        ConnectedProviderUsage(name: 'kimi', codingPlan: cp),
        ConnectedProviderUsage(name: 'deepseek', creditBalance: cb),
      ];
      final widget = CodingPlanHomeWidget(entriesOverride: () => entries);
      expect(widget.activate(_ctx()), isNotNull);

      expect(CodingPlanHomeWidget().activate(_ctx()), isNull);
    });
  });

  group('settings', () {
    HomeContext settingsCtx({
      String? themeId = 'dracula',
      String? aux,
      String? viewMode = 'vibe',
      void Function(String)? onSeed,
      void Function()? onClose,
    }) => HomeContext(
      runCommand: (_) => true,
      close: onClose ?? () {},
      seedInput: onSeed ?? (_) {},
      gitStatusService: GitStatusService(),
      sessions: () => const [],
      currentSessionId: () => null,
      switchSession: (_) => false,
      themeId: () => themeId,
      auxModelName: () => aux,
      viewMode: () => viewMode,
    );

    test('declares id, title, span, and item count', () {
      final widget = SettingsHomeWidget();
      expect(widget.id, 'settings');
      expect(widget.title, 'Settings');
      expect(widget.supportedSpans, {1, 2});
      expect(widget.heightFor(1), 4);
      expect(widget.itemCount, 5);
      expect(widget.verticallyCenter, isFalse);
    });

    test('renders every setting with its current value', () async {
      await testNocterm('settings render', (tester) async {
        await _pump(
          tester,
          SettingsHomeWidget(),
          settingsCtx(aux: 'deepseek-v4-flash'),
        );
        expect(tester.terminalState.findText('theme'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('dracula'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('auxiliary'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('deepseek-v4-flash'),
          nocterm.isNotEmpty,
        );
        expect(tester.terminalState.findText('view'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('vibe'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('language'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('en'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('reply language'),
          nocterm.isNotEmpty,
        );
        expect(
          tester.terminalState.findText('Follow language'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('activating a row seeds its command and stays on home', () {
      var seeded = '';
      var closed = false;
      final widget = SettingsHomeWidget();

      final ctx = settingsCtx(
        onSeed: (t) => seeded = t,
        onClose: () => closed = true,
      );

      widget.activateItem(ctx, 0)!();
      expect(seeded, '/theme ');
      expect(closed, isFalse);

      widget.activateItem(ctx, 1)!();
      expect(seeded, '/auxiliary ');

      widget.activateItem(ctx, 2)!();
      expect(seeded, '/view ');

      widget.activateItem(ctx, 4)!();
      expect(seeded, '/reply-language ');

      // None of the activations closed home.
      expect(closed, isFalse);
    });

    test('the language row is read-only', () {
      final widget = SettingsHomeWidget();
      expect(widget.activateItem(settingsCtx(), 3), isNull);
    });
  });

  group('setup', () {
    HomeContext setupCtx({
      bool hasKey = false,
      String? aux,
      bool hasWeb = false,
      String path = '',
      void Function(String)? onSeed,
      void Function()? onClose,
    }) => HomeContext(
      runCommand: (_) => true,
      close: onClose ?? () {},
      seedInput: onSeed ?? (_) {},
      gitStatusService: GitStatusService(),
      sessions: () => const [],
      currentSessionId: () => null,
      switchSession: (_) => false,
      projectPath: path,
      hasProviderKey: () => hasKey,
      auxModelName: () => aux,
      hasWebProvider: () => hasWeb,
    );

    test('renders the pending checklist with command hints', () async {
      await testNocterm('setup pending', (tester) async {
        await _pump(tester, SetupHomeWidget(), setupCtx());
        expect(
          tester.terminalState.findText('provider key'),
          nocterm.isNotEmpty,
        );
        expect(tester.terminalState.findText('aux model'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('web provider'),
          nocterm.isNotEmpty,
        );
        expect(tester.terminalState.findText('workspace'), nocterm.isNotEmpty);
        // Pending rows advertise the command they'll seed.
        expect(tester.terminalState.findText('/provider'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('/auxiliary'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('/web-provider'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('done rows show their detail instead of the command hint', () async {
      await testNocterm('setup partial', (tester) async {
        await _pump(
          tester,
          SetupHomeWidget(),
          setupCtx(hasKey: true, aux: 'glm-5.3-flash', path: '/work/crux'),
        );
        // Done rows carry their detail.
        expect(tester.terminalState.findText('connected'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('glm-5.3-flash'),
          nocterm.isNotEmpty,
        );
        expect(tester.terminalState.findText('crux'), nocterm.isNotEmpty);
        // The one pending row still shows its command hint.
        expect(
          tester.terminalState.findText('/web-provider'),
          nocterm.isNotEmpty,
        );
        // And done rows no longer advertise theirs.
        expect(tester.terminalState.findText('/provider'), isEmpty);
        expect(tester.terminalState.findText('/auxiliary'), isEmpty);
      });
    });

    test('is titled Quick Start and spans the full width', () {
      final widget = SetupHomeWidget();
      expect(widget.title, 'Quick Start');
      expect(widget.supportedSpans, containsAll([1, 2, 4]));
    });

    test('hides (visibleWhen false) only when every row is done', () {
      final widget = SetupHomeWidget();
      // All four done → the box drops out of the grid entirely.
      expect(
        widget.visibleWhen(
          setupCtx(hasKey: true, aux: 'glm', hasWeb: true, path: '/work/x'),
        ),
        isFalse,
      );
      // Any one pending row keeps it visible.
      expect(
        widget.visibleWhen(
          setupCtx(hasKey: true, aux: 'glm', hasWeb: false, path: '/work/x'),
        ),
        isTrue,
      );
      expect(widget.visibleWhen(setupCtx()), isTrue);
    });

    test('activating a pending row seeds its command and closes', () {
      var seeded = '';
      var closed = false;
      final widget = SetupHomeWidget();
      final ctx = setupCtx(
        onSeed: (t) => seeded = t,
        onClose: () => closed = true,
      );
      // Row 0 (provider key) is pending.
      widget.activateItem(ctx, 0)!();
      expect(seeded, '/provider ');
      expect(closed, isTrue);
    });

    test('activating a done row or the workspace row is a no-op', () {
      var seeded = false;
      final widget = SetupHomeWidget();
      final ctx = setupCtx(
        hasKey: true,
        aux: 'glm',
        path: '/work/crux',
        onSeed: (_) => seeded = true,
      );
      // Row 0 is done → null.
      expect(widget.activateItem(ctx, 0), isNull);
      // Row 2 (web provider) is the only actionable one.
      expect(widget.activateItem(ctx, 2), isNotNull);
      // Row 3 (workspace) has no command even though it's done.
      expect(widget.activateItem(ctx, 3), isNull);
      expect(seeded, isFalse);
    });

    test('selection wraps across the four rows', () {
      final widget = SetupHomeWidget();
      expect(widget.itemCount, 4);
      expect(widget.selectedIndex, 0);
      widget.moveSelection(-1);
      expect(widget.selectedIndex, 3);
      widget.moveSelection(1);
      expect(widget.selectedIndex, 0);
    });

    test('default context reports everything pending', () {
      // HomeContext.minimal (tests/previews) renders the full checklist.
      final items = SetupHomeWidget().itemsFor(_ctx());
      expect(items, hasLength(4));
      expect(items.where((i) => i.done), isEmpty);
    });
  });

  group('skills', () {
    SkillInfo skill(String name, [String desc = 'does things']) => SkillInfo(
      name: name,
      description: desc,
      location: '/tmp/$name/SKILL.md',
      baseDirectory: '/tmp/$name',
      content: '# $name',
    );

    HomeContext skillCtx({void Function(SkillInfo)? showSkill}) => HomeContext(
      runCommand: (_) => true,
      close: () {},
      seedInput: (_) {},
      gitStatusService: GitStatusService(),
      sessions: () => const [],
      currentSessionId: () => null,
      switchSession: (_) => false,
      showSkill: showSkill,
    );

    test('empty state when no skills are found', () async {
      await testNocterm('skills empty', (tester) async {
        final widget = SkillsHomeWidget(skills: () => const []);
        await _pump(tester, widget, skillCtx());
        expect(
          tester.terminalState.findText('no skills found'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('renders every skill with its description', () async {
      await testNocterm('skills render', (tester) async {
        final widget = SkillsHomeWidget(
          skills: () => [
            skill('crux-release', 'release a version'),
            skill('nocterm', 'debug the tui'),
          ],
        );
        await _pump(tester, widget, skillCtx());
        expect(
          tester.terminalState.findText('crux-release'),
          nocterm.isNotEmpty,
        );
        expect(tester.terminalState.findText('nocterm'), nocterm.isNotEmpty);
        expect(
          tester.terminalState.findText('release a version'),
          nocterm.isNotEmpty,
        );
      });
    });

    test('item interface covers every skill (scrollable, not truncated)', () {
      final widget = SkillsHomeWidget(
        skills: () => [for (var i = 0; i < 20; i++) skill('skill-$i')],
      );
      // Unlike recent-sessions (truncated to _maxRows), all 20 are
      // selectable — the list scrolls.
      expect(widget.itemCount, 20);
      widget.moveSelection(1);
      expect(widget.selectedIndex, 1);
      // Wraparound over the whole list.
      widget.resetSelection();
      widget.moveSelection(-1);
      expect(widget.selectedIndex, 19);
    });

    test('activation calls showSkill with the tapped skill', () {
      SkillInfo? opened;
      final all = [skill('alpha'), skill('beta')];
      final widget = SkillsHomeWidget(skills: () => all);
      final action = widget.activateItem(
        skillCtx(showSkill: (s) => opened = s),
        1,
      );
      expect(action, isNotNull);
      action!();
      expect(opened?.name, 'beta');
    });

    test('activation is a no-op when no viewer is wired', () {
      final widget = SkillsHomeWidget(skills: () => [skill('alpha')]);
      expect(widget.activateItem(skillCtx(), 0), isNull);
      // And the box is passive when the list is empty.
      final empty = SkillsHomeWidget(skills: () => const []);
      expect(empty.activate(skillCtx()), isNull);
    });

    test(
      'selectItemAt translates a viewport row through the scroll offset',
      () async {
        await testNocterm('skills hover offset', (tester) async {
          final widget = SkillsHomeWidget(
            skills: () => [for (var i = 0; i < 12; i++) skill('skill-$i')],
          );
          // Move the selection past the viewport so the list scrolls, then
          // build so the view mirrors its scroll offset back to the widget.
          for (var i = 0; i < 8; i++) {
            widget.moveSelection(1);
          }
          expect(widget.selectedIndex, 8);
          await _pump(tester, widget, skillCtx());
          for (var i = 0; i < 3; i++) {
            await tester.pump();
          }
          // Viewport row 0 must map through the scroll offset to a valid
          // absolute index (not crash / not out-of-range), and hovering it
          // changes the selection from 8 to the hovered row.
          expect(widget.selectItemAt(0), isTrue);
          expect(widget.selectedIndex, isNot(8));
          expect(widget.selectedIndex, greaterThanOrEqualTo(0));
          expect(widget.selectedIndex, lessThan(12));
        });
      },
    );

    test('is not vertically centered (it scrolls)', () {
      expect(
        SkillsHomeWidget(skills: () => const []).verticallyCenter,
        isFalse,
      );
    });
  });
}

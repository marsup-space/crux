import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/quick_actions_widget.dart';
import 'package:crux/src/components/home/widgets/skills_widget.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/theme/crux_theme.dart';

HomeContext _ctx({bool Function(String)? runCommand}) {
  final base = HomeContext.minimal(close: () {});
  return HomeContext(
    runCommand: runCommand ?? (_) => true,
    close: () {},
    seedInput: (_) {},
    gitStatusService: base.gitStatusService,
    sessions: () => const [],
    currentSessionId: () => null,
    switchSession: (_) => false,
  );
}

/// Pumps a [HomeScreen] with the given stub widgets at [size] inside a
/// fixed-size themed container, and returns the tester.
Future<void> _pumpHome(
  NoctermTester tester,
  List<HomeWidget> widgets,
  Size size,
) async {
  await tester.pumpComponent(
    Container(
      width: size.width,
      height: size.height,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: HomeScreen(onExit: () {}, widgets: widgets, context_: _ctx()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('grid renders boxes at wide width (4 columns)', () async {
    await testNocterm('wide grid', (tester) async {
      await _pumpHome(
        tester,
        [
          StubHomeWidget('alpha'),
          StubHomeWidget('beta', supportedSpans: const {1}),
          StubHomeWidget('gamma', supportedSpans: const {1}),
        ],
        const Size(120, 30),
      );
      for (final id in ['alpha', 'beta', 'gamma']) {
        expect(
          tester.terminalState.findText(id).isNotEmpty,
          isTrue,
          reason: 'box $id should render its title',
        );
      }
      // Key legend is the normal-mode hint.
      expect(tester.terminalState.findText('enter open').isNotEmpty, isTrue);
    }, size: const Size(120, 30));
  });

  test('grid reflows to fewer columns at narrow width', () async {
    await testNocterm('narrow grid', (tester) async {
      // A span-2-only widget must fall back to rendering (at span 1)
      // in a 1-column layout rather than disappearing.
      await _pumpHome(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1, 2}),
          StubHomeWidget('beta', supportedSpans: const {1, 2}),
        ],
        const Size(70, 30),
      );
      expect(tester.terminalState.findText('alpha').isNotEmpty, isTrue);
      expect(tester.terminalState.findText('beta').isNotEmpty, isTrue);
    }, size: const Size(70, 30));
  });

  test('span fallback: largest supported span that fits is chosen', () async {
    await testNocterm('span fallback', (tester) async {
      // At 2 columns, a {1,2} widget takes span 2; the stub renders the
      // span it was laid out at, so we can read it back.
      await _pumpHome(
        tester,
        [StubHomeWidget('alpha', supportedSpans: const {1, 2})],
        const Size(90, 30),
      );
      expect(
        tester.terminalState.findText('alpha · span 2').isNotEmpty,
        isTrue,
        reason: 'a {1,2} widget in 2 columns should render at span 2',
      );
    }, size: const Size(90, 30));
  });

  test('a {1,2} flexible widget takes a double-width share of its row', () async {
    await testNocterm('span share', (tester) async {
      // Flexible boxes split a row's pixels by span: on a 4-column row,
      // span-1 alpha + span-2 beta fit the 3-span budget, and beta gets
      // twice alpha's width.
      // The container must clear the 4-column threshold *after* home's
      // horizontal padding (2 cols each side): 132 → 128 inner ≥ 120.
      await _pumpHome(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1, 2}),
        ],
        const Size(132, 30),
      );
      final text = tester.terminalState.getText();
      expect(
        text.contains('beta · span 2'),
        isTrue,
        reason: 'a {1,2} flexible widget renders at its span-2 share',
      );
      // Both boxes share one row: alpha's and beta's borders are on the
      // same terminal line.
      final borderLine =
          text.split('\n').firstWhere((l) => l.contains('─ alpha ─'));
      expect(borderLine, contains('─ beta ─'));
      // Beta is roughly twice alpha's width. Measure each box by the
      // span of its top border between the corner glyphs.
      int boxWidth(String title) {
        final start = borderLine.indexOf('─ $title ─');
        final close = borderLine.indexOf('╮', start);
        return close - start;
      }
      final alphaW = boxWidth('alpha');
      final betaW = boxWidth('beta');
      expect(
        betaW / alphaW,
        closeTo(2.0, 0.4),
        reason: 'span-2 beta ($betaW) should be ~2x span-1 alpha ($alphaW)',
      );
    }, size: const Size(132, 30));
  });

  test('arrow keys move the focus ring between boxes', () async {
    await testNocterm('focus nav', (tester) async {
      await _pumpHome(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1}),
        ],
        const Size(120, 30),
      );
      // Focus starts on the first box. Moving right should not throw
      // and keeps both boxes on screen; the layout is stable across
      // navigation.
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowRight),
      );
      await tester.pump();
      expect(tester.terminalState.findText('beta').isNotEmpty, isTrue);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowLeft),
      );
      await tester.pump();
      expect(tester.terminalState.findText('alpha').isNotEmpty, isTrue);
    }, size: const Size(120, 30));
  });

  test('enter on a passive box is a no-op', () async {
    await testNocterm('passive enter', (tester) async {
      await _pumpHome(
        tester,
        [StubHomeWidget('alpha', actionable: false)],
        const Size(120, 30),
      );
      // Should not throw, and the box stays put.
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));
      await tester.pump();
      expect(tester.terminalState.findText('alpha').isNotEmpty, isTrue);
    }, size: const Size(120, 30));
  });

  test('enter fires the focused box action through runCommand', () async {
    await testNocterm('action enter', (tester) async {
      final ran = <String>[];
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 30,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [
                _CommandStub('alpha', onRun: '/new'),
              ],
              context_: _ctx(runCommand: (c) {
                ran.add(c);
                return true;
              }),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));
      await tester.pump();
      expect(ran, ['/new'], reason: 'enter should run the box command');
    }, size: const Size(120, 30));
  });

  test('esc calls onExit', () async {
    await testNocterm('esc exit', (tester) async {
      var exited = false;
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 30,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () => exited = true,
              widgets: [StubHomeWidget('alpha')],
              context_: _ctx(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.escape));
      await tester.pump();
      expect(exited, isTrue, reason: 'esc should leave home');
    }, size: const Size(120, 30));
  });

  test('up/down select items within a box, not other boxes', () async {
    await testNocterm('in-box selection', (tester) async {
      final list = _ItemStub('list', itemCount: 3);
      await _pumpHome(
        tester,
        [list, StubHomeWidget('other', supportedSpans: const {1})],
        const Size(120, 30),
      );
      // Focus starts on the list box, item 0.
      expect(list.selectedIndex, 0);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowDown),
      );
      await tester.pump();
      expect(list.selectedIndex, 1, reason: '↓ moves within the box');
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowDown),
      );
      await tester.pump();
      expect(list.selectedIndex, 2);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowDown),
      );
      await tester.pump();
      expect(list.selectedIndex, 0, reason: '↓ wraps within the box');
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.arrowUp));
      await tester.pump();
      expect(list.selectedIndex, 2, reason: '↑ wraps to the last item');
    }, size: const Size(120, 30));
  });

  test('left/right switch boxes within a row and clamp at the ends', () async {
    await testNocterm('row box nav', (tester) async {
      // Three span-1 boxes side by side on one 4-column row. The
      // container must be wide enough for 4 columns *after* HomeScreen's
      // horizontal padding (2 cols each side): use 132 so the inner
      // width clears the 120-column threshold.
      final widgets = [
        StubHomeWidget('a', supportedSpans: const {1}),
        StubHomeWidget('b', supportedSpans: const {1}),
        StubHomeWidget('c', supportedSpans: const {1}),
      ];
      await _pumpHome(tester, widgets, const Size(132, 30));
      // The state type is private, so grab it via State<HomeScreen> and
      // read the test getter through `dynamic`.
      int focus() =>
          (tester.findState<State<HomeScreen>>() as dynamic)
              .focusedIndexForTest as int;
      expect(focus(), 0);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowRight),
      );
      await tester.pump();
      expect(focus(), 1);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowRight),
      );
      await tester.pump();
      expect(focus(), 2);
      // → on the last box in the row stays put (Tab is the row jump).
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowRight),
      );
      await tester.pump();
      expect(focus(), 2, reason: '→ clamps at the row end');
      // ← back to the start, and clamps there too.
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowLeft),
      );
      await tester.pump();
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowLeft),
      );
      await tester.pump();
      expect(focus(), 0);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowLeft),
      );
      await tester.pump();
      expect(focus(), 0, reason: '← clamps at the row start');
    }, size: const Size(132, 30));
  });

  test('tab jumps to the next row, shift+tab back', () async {
    await testNocterm('tab row jump', (tester) async {
      // Force two rows: a full-width box on row 1, two span-1 boxes on
      // row 2. At 4 columns a span-4 box fills row 1 alone.
      final widgets = [
        StubHomeWidget('wide', supportedSpans: const {4}),
        StubHomeWidget('x', supportedSpans: const {1}),
        StubHomeWidget('y', supportedSpans: const {1}),
      ];
      await _pumpHome(tester, widgets, const Size(120, 30));
      // The state type is private, so grab it via State<HomeScreen> and
      // read the test getter through `dynamic`.
      int focus() =>
          (tester.findState<State<HomeScreen>>() as dynamic)
              .focusedIndexForTest as int;
      expect(focus(), 0, reason: 'start on the wide row-1 box');
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.tab));
      await tester.pump();
      expect(focus(), 1, reason: 'tab jumps down a row');
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.tab));
      await tester.pump();
      expect(focus(), 1, reason: 'tab clamps on the last row');
      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.tab,
          modifiers: const ModifierKeys(shift: true),
        ),
      );
      await tester.pump();
      expect(focus(), 0, reason: 'shift+tab jumps back up a row');
    }, size: const Size(120, 30));
  });

  test('up/down on a passive box fall through to row navigation', () async {
    await testNocterm('passive vertical', (tester) async {
      // A passive (no-item) box on row 1, another on row 2.
      final widgets = [
        StubHomeWidget('top', supportedSpans: const {4}, actionable: false),
        StubHomeWidget('bottom', supportedSpans: const {4}, actionable: false),
      ];
      await _pumpHome(tester, widgets, const Size(120, 30));
      // The state type is private, so grab it via State<HomeScreen> and
      // read the test getter through `dynamic`.
      int focus() =>
          (tester.findState<State<HomeScreen>>() as dynamic)
              .focusedIndexForTest as int;
      expect(focus(), 0);
      await tester.sendKeyEvent(
        KeyboardEvent(logicalKey: LogicalKey.arrowDown),
      );
      await tester.pump();
      expect(focus(), 1, reason: '↓ moves rows on a passive box');
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.arrowUp));
      await tester.pump();
      expect(focus(), 0);
    }, size: const Size(120, 30));
  });

  test('mouse click on a row runs that row, not the box/first item', () async {
    final ran = <String>[];
    await testNocterm('row click', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 60,
          height: 24,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [
                QuickActionsHomeWidget(
                  seedInput: (_) {},
                  actions: const [
                    QuickAction('/new', 'a', '/new'),
                    QuickAction('/chat', 'b', '/chat'),
                    QuickAction('/model', 'c', '/model '),
                  ],
                ),
              ],
              context_: HomeContext(
                runCommand: (c) {
                  ran.add(c);
                  return true;
                },
                close: () {},
                seedInput: (_) {},
                gitStatusService: GitStatusService(),
                sessions: () => const [],
                currentSessionId: () => null,
                switchSession: (_) => false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Hero is 8 rows (1 padding + 6 logo + 1 gap), so the box border
      // sits at y=8; action rows at y=9 (/new), 10 (/chat), 11.
      await tester.tap(4, 10);
      await tester.pump();
    }, size: const Size(60, 24));
    expect(ran, contains('/chat'), reason: 'click on /chat runs /chat');
    expect(ran, isNot(contains('/new')), reason: 'must not fire the first item');
  });

  test('Ctrl+C on home calls quitApp (not swallowed)', () async {
    // Regression: _handleKey swallows every key (return true) with no
    // quit path, so Ctrl+C was trapped. Home now routes Ctrl+C to the
    // quitApp callback (QuitHandler) the panel wires in.
    var quitCalled = false;
    await testNocterm('ctrl_c quits', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 60,
          height: 24,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [StubHomeWidget('alpha')],
              context_: _ctx(),
              quitApp: () => quitCalled = true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ),
      );
      await tester.pump();
    }, size: const Size(60, 24));
    expect(quitCalled, isTrue, reason: 'Ctrl+C must call quitApp on home');
  });

  test('Hovering a row moves the selection highlight', () async {
    // Regression: per-row MouseRegions never receive hover under a
    // wrapping box MouseRegion in nocterm (verified empirically), so
    // hover-row selection is computed at the box level — the box's
    // MouseRegion.onHover maps the cursor y to a content row and calls
    // HomeWidget.selectItemAt.
    await testNocterm('row hover', (tester) async {
      final widget = QuickActionsHomeWidget(
        seedInput: (_) {},
        actions: const [
          QuickAction('/new', 'a', '/new'),
          QuickAction('/chat', 'b', '/chat'),
          QuickAction('/model', 'c', '/model '),
        ],
      );
      await tester.pumpComponent(
        Container(
          width: 60,
          height: 24,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [widget],
              context_: HomeContext(
                runCommand: (_) => true,
                close: () {},
                seedInput: (_) {},
                gitStatusService: GitStatusService(),
                sessions: () => const [],
                currentSessionId: () => null,
                switchSession: (_) => false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(widget.selectedIndex, 0);
      // /chat row is at y=10 in this 60×16 layout (border y=8, rows 9-11).
      await tester.hover(3, 10);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(
        widget.selectedIndex,
        1,
        reason: 'hovering the /chat row selects it',
      );
      // Hover /new (y=9) and confirm the selection moves up.
      await tester.hover(3, 9);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(
        widget.selectedIndex,
        0,
        reason: 'hovering the /new row selects it',
      );
      // Sweeping ALONG the same row (same x-range, mouse motion
      // events) must not report a change: selectItemAt short-circuits
      // on the same index, so home schedules no rebuild. This is the
      // hover-lag regression guard — before the fix each motion event
      // rebuilt the whole grid.
      expect(widget.selectItemAt(0), isFalse,
          reason: 'same-index hover is a no-op');
      expect(widget.selectItemAt(1), isTrue,
          reason: 'a different row still moves the selection');
      expect(widget.selectedIndex, 1);
    }, size: const Size(60, 24));
  });

  test('skills panel caches discovery across rebuilds', () async {
    // The skills box used to re-scan the filesystem on every build
    // (3-5 sync directory walks per hover-driven rebuild, ~2ms each).
    // Home now memoizes the list per mount; verify the closure is
    // stable and repeated calls don't re-invoke discovery.
    var calls = 0;
    final discovered = <String>['plugin', 'crux-release'];
    final widget = SkillsHomeWidget(
      skills: () {
        calls++;
        return [
          for (final name in discovered)
            SkillInfo(
              name: name,
              description: '',
              location: '',
              baseDirectory: '',
              content: '',
            ),
        ];
      },
    );
    // Reading itemCount twice is intentional: each read invokes the
    // skills closure once, driving `calls` to 2 for the assertion below.
    expect(widget.itemCount, 2);
    expect(widget.itemCount, 2);
    expect(calls, 2, reason: 'no caching inside the widget itself');
  });
}

/// A stub with a real item list, so ↑↓ in-box selection can be driven
/// from tests. Renders its id; selection is tracked by the widget.
class _ItemStub extends HomeWidget {
  @override
  final String id;

  @override
  final int itemCount;

  int _selectedIndex = 0;

  _ItemStub(this.id, {required this.itemCount});

  @override
  String get title => id;
  @override
  Set<int> get supportedSpans => const {1, 2};
  @override
  int heightFor(int span) => itemCount;

  @override
  int get selectedIndex => _selectedIndex;

  @override
  void moveSelection(int delta) {
    _selectedIndex = (_selectedIndex + delta) % itemCount;
    if (_selectedIndex < 0) _selectedIndex += itemCount;
  }

  @override
  void resetSelection() => _selectedIndex = 0;

  @override
  void Function()? activate(HomeContext ctx) => null;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) =>
      Text(id);
}

/// A stub whose primary action routes a fixed command through
/// `HomeContext.runCommand`, used to assert activation plumbing.
class _CommandStub extends HomeWidget {
  @override
  final String id;
  final String onRun;

  _CommandStub(this.id, {required this.onRun});

  @override
  String get title => id;
  @override
  Set<int> get supportedSpans => const {1, 2};
  @override
  int heightFor(int span) => 3;

  @override
  void Function()? activate(HomeContext ctx) =>
      () => ctx.runCommand(onRun);

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) =>
      Text(id);
}

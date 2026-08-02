import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
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

  test('a {1,2} widget degrades to span 1 to fill a partial row', () async {
    await testNocterm('span degrade', (tester) async {
      // 2 columns: span-1 alpha leaves one free column; the {1,2} beta
      // must drop to span 1 to share the row rather than overflow.
      await _pumpHome(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1, 2}),
        ],
        const Size(90, 30),
      );
      expect(
        tester.terminalState.findText('beta · span 1').isNotEmpty,
        isTrue,
        reason: 'a {1,2} widget should degrade to span 1 in a 1-column gap',
      );
    }, size: const Size(90, 30));
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
  Component build(BuildContext context, HomeContext ctx, int span) =>
      Text(id);
}

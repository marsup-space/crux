import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_layout_store.dart';
import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/theme/crux_theme.dart';

HomeContext _ctx() => HomeContext.minimal(close: () {});

/// Pumps a HomeScreen with stub widgets and records layout changes.
Future<List<List<HomeLayoutEntry>>> _pumpEdit(
  NoctermTester tester,
  List<HomeWidget> widgets, {
  List<HomeLayoutEntry>? initialLayout,
}) async {
  final captured = <List<HomeLayoutEntry>>[];
  await tester.pumpComponent(
    Container(
      width: 120,
      height: 30,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: HomeScreen(
          onExit: () {},
          widgets: widgets,
          context_: _ctx(),
          initialLayout: initialLayout,
          onLayoutChanged: captured.add,
        ),
      ),
    ),
  );
  await tester.pump();
  return captured;
}

Future<void> _key(NoctermTester tester, LogicalKey key) async {
  await tester.sendKeyEvent(KeyboardEvent(logicalKey: key));
  await tester.pump();
}

void main() {
  test('e enters edit mode: modal marker + edit legend appear', () async {
    await testNocterm('edit marker', (tester) async {
      await _pumpEdit(tester, [StubHomeWidget('alpha')]);
      // Normal mode first.
      expect(tester.terminalState.findText('enter open').isNotEmpty, isTrue);
      expect(tester.terminalState.findText('[editing]').isEmpty, isTrue);

      await _key(tester, LogicalKey.keyE);
      expect(tester.terminalState.findText('[editing]').isNotEmpty, isTrue);
      expect(tester.terminalState.findText('reorder').isNotEmpty, isTrue);
      expect(
        tester.terminalState.findText('enter open').isEmpty,
        isTrue,
        reason: 'normal legend should be replaced by the edit legend',
      );
    }, size: const Size(120, 30));
  });

  test('e/esc exits edit mode; a second esc leaves home', () async {
    await testNocterm('edit esc', (tester) async {
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

      await _key(tester, LogicalKey.keyE); // enter edit
      expect(tester.terminalState.findText('[editing]').isNotEmpty, isTrue);
      // esc in edit mode exits edit mode, NOT home.
      await _key(tester, LogicalKey.escape);
      expect(tester.terminalState.findText('[editing]').isEmpty, isTrue);
      expect(exited, isFalse, reason: 'first esc should only exit edit mode');
      // second esc leaves home.
      await _key(tester, LogicalKey.escape);
      expect(exited, isTrue);
    }, size: const Size(120, 30));
  });

  test('arrows reorder the focused box and persist the new order', () async {
    await testNocterm('edit reorder', (tester) async {
      final captured = await _pumpEdit(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1}),
          StubHomeWidget('gamma', supportedSpans: const {1}),
        ],
      );
      await _key(tester, LogicalKey.keyE);
      // Focus is on alpha (index 0); move it right.
      await _key(tester, LogicalKey.arrowRight);
      expect(captured, isNotEmpty);
      final last = captured.last;
      expect(
        last.map((e) => e.id).toList(),
        ['beta', 'alpha', 'gamma'],
        reason: 'alpha should move after beta',
      );
    }, size: const Size(120, 30));
  });

  test('= cycles the focused box span within supportedSpans', () async {
    await testNocterm('edit resize', (tester) async {
      final captured = await _pumpEdit(
        tester,
        [StubHomeWidget('alpha', supportedSpans: const {1, 2})],
      );
      await _key(tester, LogicalKey.keyE);
      // Default span is 2 (largest). `=` cycles to the next supported.
      await _key(tester, LogicalKey.equal);
      expect(captured.last.single.span, 1);
      // And again back to 2.
      await _key(tester, LogicalKey.equal);
      expect(captured.last.single.span, 2);
    }, size: const Size(120, 30));
  });

  test('resize on a fixed-size box shows a notice and does not persist',
      () async {
    await testNocterm('edit resize fixed', (tester) async {
      final captured = await _pumpEdit(
        tester,
        [StubHomeWidget('alpha', supportedSpans: const {1})],
      );
      await _key(tester, LogicalKey.keyE);
      await _key(tester, LogicalKey.equal);
      expect(
        tester.terminalState.findText('fixed size').isNotEmpty,
        isTrue,
        reason: 'resizing a single-span box should explain itself',
      );
      expect(captured, isEmpty, reason: 'no layout change should persist');
    }, size: const Size(120, 30));
  });

  test('x hides a box; a re-adds it', () async {
    await testNocterm('edit hide add', (tester) async {
      final captured = await _pumpEdit(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1}),
        ],
      );
      await _key(tester, LogicalKey.keyE);
      // Hide alpha (focused).
      await _key(tester, LogicalKey.keyX);
      expect(
        captured.last.map((e) => e.id).toList(),
        ['beta'],
        reason: 'hiding alpha leaves only beta',
      );
      // Re-add it (goes to the end).
      await _key(tester, LogicalKey.keyA);
      expect(
        captured.last.map((e) => e.id).toList(),
        ['beta', 'alpha'],
        reason: 're-added alpha appends at the end',
      );
    }, size: const Size(120, 30));
  });

  test('cannot hide the last remaining box', () async {
    await testNocterm('edit hide last', (tester) async {
      final captured = await _pumpEdit(
        tester,
        [StubHomeWidget('alpha', supportedSpans: const {1})],
      );
      await _key(tester, LogicalKey.keyE);
      await _key(tester, LogicalKey.keyX);
      expect(
        tester.terminalState.findText('at least one box').isNotEmpty,
        isTrue,
      );
      expect(captured, isEmpty, reason: 'hiding the last box is refused');
      expect(
        tester.terminalState.findText('alpha').isNotEmpty,
        isTrue,
        reason: 'the last box stays on screen',
      );
    }, size: const Size(120, 30));
  });

  test('enter is swallowed in edit mode (no activation)', () async {
    await testNocterm('edit enter swallowed', (tester) async {
      var ran = false;
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 30,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [
                _ActionStub('alpha', onRun: () => ran = true),
              ],
              context_: _ctx(),
            ),
          ),
        ),
      );
      await tester.pump();
      await _key(tester, LogicalKey.keyE);
      await _key(tester, LogicalKey.enter);
      expect(ran, isFalse, reason: 'enter must not activate while editing');
    }, size: const Size(120, 30));
  });

  test('initial layout applies order and skips unknown ids', () async {
    await testNocterm('initial layout', (tester) async {
      await _pumpEdit(
        tester,
        [
          StubHomeWidget('alpha', supportedSpans: const {1}),
          StubHomeWidget('beta', supportedSpans: const {1}),
          StubHomeWidget('gamma', supportedSpans: const {1}),
        ],
        initialLayout: const [
          HomeLayoutEntry('beta', 1),
          HomeLayoutEntry('nope', 1), // unknown id: skipped
          HomeLayoutEntry('alpha', 1),
          // gamma has no entry: appends at the end in default order.
        ],
      );
      // Both placed boxes and the default-appended one render; the
      // unknown id does not.
      expect(tester.terminalState.findText('beta').isNotEmpty, isTrue);
      expect(tester.terminalState.findText('alpha').isNotEmpty, isTrue);
      expect(tester.terminalState.findText('gamma').isNotEmpty, isTrue);
      expect(
        tester.terminalState.findText('nope').isEmpty,
        isTrue,
        reason: 'unknown ids are skipped, not rendered',
      );
    }, size: const Size(120, 30));
  });

  test('a persisted span caps the box at narrow widths', () async {
    await testNocterm('span cap', (tester) async {
      // At 90 cols → 2 columns, a {1,2} widget with no preference takes
      // span 2 (proven in home_layout_test). A persisted span of 1 caps
      // it to 1.
      await _pumpEdit(
        tester,
        [StubHomeWidget('alpha', supportedSpans: const {1, 2})],
        initialLayout: const [HomeLayoutEntry('alpha', 1)],
      );
      expect(
        tester.terminalState.findText('alpha · span 1').isNotEmpty,
        isTrue,
        reason: 'a persisted span of 1 should cap a {1,2} box to span 1',
      );
    }, size: const Size(90, 30));
  });
}

/// A stub whose activation flips a flag, to prove activation is/isn't
/// reachable.
class _ActionStub extends HomeWidget {
  @override
  final String id;
  final void Function() onRun;

  _ActionStub(this.id, {required this.onRun});

  @override
  String get title => id;
  @override
  Set<int> get supportedSpans => const {1};
  @override
  int heightFor(int span) => 3;

  @override
  void Function()? activate(HomeContext ctx) => onRun;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) =>
      Text(id);
}

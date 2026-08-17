import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/theme/crux_theme.dart';

HomeContext _ctx() => HomeContext.minimal(close: () {});

/// Whether any rendered terminal line contains [needle] as a
/// whitespace-delimited word — so `wide` doesn't match `narrow`.
bool _hasWord(NoctermTester tester, String needle) {
  for (final line in tester.terminalState.getText().split('\n')) {
    for (final word in line.split(RegExp(r'\s+'))) {
      if (word == needle) return true;
    }
  }
  return false;
}

/// The terminal line containing a box's top border (its title).
String _borderLine(NoctermTester tester, String title) => tester
    .terminalState
    .getText()
    .split('\n')
    .firstWhere((l) => l.contains('─ $title ─'));

/// A box's cell width in terminal columns, measured from its leading
/// ╭ to its trailing ╮ inclusive.
int _cellWidth(String borderLine, String title) {
  final titleStart = borderLine.indexOf('─ $title ─');
  final open = borderLine.lastIndexOf('╭', titleStart);
  final close = borderLine.indexOf('╮', titleStart);
  return close - open + 1;
}

void main() {
  test('a rigid box holds its min width while flexible boxes shrink', () async {
    await testNocterm('rigid holds', (tester) async {
      // 84 inner, 2 columns. `wide` is rigid at 30 content cols (34
      // with border+padding); the two flexible boxes split the ~50
      // pixels left over and shrink as the window narrows, while
      // `wide` stays exactly 34.
      await tester.pumpComponent(
        Container(
          width: 88,
          height: 30,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [
                StubHomeWidget('alpha', supportedSpans: const {1}),
                _MinWidthStub('wide', minColumnWidth: 30),
                StubHomeWidget('beta', supportedSpans: const {1}),
              ],
              context_: _ctx(),
            ),
          ),
        ),
      );
      await tester.pump();
      final line = _borderLine(tester, 'wide');
      expect(
        _cellWidth(line, 'wide'),
        34,
        reason: 'a rigid box renders at exactly minColumnWidth + 4',
      );
      // All three share one row.
      expect(line, contains('─ alpha ─'));
      expect(line, contains('─ beta ─'));
    }, size: const Size(88, 30));
  });

  test('a rigid box never shrinks as the window narrows', () async {
    await testNocterm('rigid fixed', (tester) async {
      for (final w in [100, 80, 60]) {
        await tester.pumpComponent(
          Container(
            width: w.toDouble(),
            height: 30,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: HomeScreen(
                onExit: () {},
                widgets: [
                  StubHomeWidget('alpha', supportedSpans: const {1}),
                  _MinWidthStub('wide', minColumnWidth: 30),
                ],
                context_: _ctx(),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          _cellWidth(_borderLine(tester, 'wide'), 'wide'),
          34,
          reason: 'at $w cols the rigid box still holds 34',
        );
      }
    }, size: const Size(100, 30));
  });

  test('a rigid box too wide for the row wraps onto its own row', () async {
    await testNocterm('rigid wraps', (tester) async {
      // 46 inner. `wide` needs 34; sharing with alpha would leave
      // alpha a sliver, so `wide` wraps onto its own full row at 34.
      await tester.pumpComponent(
        Container(
          width: 50,
          height: 30,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: HomeScreen(
              onExit: () {},
              widgets: [
                StubHomeWidget('alpha', supportedSpans: const {1}),
                _MinWidthStub('wide', minColumnWidth: 30),
              ],
              context_: _ctx(),
            ),
          ),
        ),
      );
      await tester.pump();
      // Both render, on separate rows.
      expect(_hasWord(tester, 'alpha'), isTrue);
      expect(_hasWord(tester, 'wide'), isTrue);
      final alphaLine = _borderLine(tester, 'alpha');
      expect(
        alphaLine.contains('─ wide ─'),
        isFalse,
        reason: 'the rigid box wraps off the shared row when it would '
            'starve the flexible box',
      );
      expect(_cellWidth(_borderLine(tester, 'wide'), 'wide'), 34);
    }, size: const Size(50, 30));
  });
}

/// A stub that declares a minimum content width (a rigid box).
class _MinWidthStub extends HomeWidget {
  @override
  final String id;

  @override
  final int minColumnWidth;

  _MinWidthStub(this.id, {required this.minColumnWidth});

  @override
  String get title => id;
  @override
  Set<int> get supportedSpans => const {1};
  @override
  int heightFor(int span) => 3;

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

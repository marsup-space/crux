import 'package:crux/src/components/ui/round_limit_slider.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// Standalone tests for [RoundLimitSlider], mounted the way the config
/// fullpane mounts it: inside a scroll view with horizontal padding.
/// This exercises the global↔local coordinate path (the scroll view
/// drops the accumulated paint offset; the slider must rebuild it from
/// the parent chain) without pulling in the whole subagent stack.
void main() {
  test(
    'renders the default 40 thumb, the track stops and the ∞ end state',
    () async {
      await testNocterm('round limit slider render', (tester) async {
        await _mount(tester, value: 40, onChanged: (_) {});
        final ts = tester.terminalState;
        final left = ts.findText('├').single;
        final inf = ts.findText('∞').single;
        final thumb = ts.findText('█').single;

        expect(inf.y, left.y); // one row: track + ∞ end state
        expect(thumb.y, left.y);
        expect(thumb.x, greaterThan(left.x));
        expect(thumb.x, lessThan(inf.x));
        expect(inf.x - left.x, greaterThan(60)); // wide draggable track
      }, size: const Size(100, 40));
    },
  );

  test('drag maps cells to values and repaints the thumb', () async {
    final changes = <int?>[];
    await testNocterm('round limit slider drag', (tester) async {
      await _mount(tester, value: 40, onChanged: changes.add);
      final ts = tester.terminalState;
      final left = ts.findText('├').single;
      final inf = ts.findText('∞').single;
      final width = inf.x - left.x + 1; // includes the ∞ cell

      // Midpoint of the finite range 32..100 → 66 rounds.
      final midCell = (width - 2) ~/ 2;
      await _drag(tester, left.x + midCell, inf.y, left.x + midCell);
      expect(changes, contains(66));
      // The thumb repainted — no longer at the 40-default cell.
      final thumb = tester.terminalState.findText('█').single;
      expect(thumb.x, greaterThan(left.x + midCell - 2));

      // Far right of the finite range → 100 rounds.
      await _drag(tester, left.x + midCell, inf.y, inf.x - 1);
      expect(changes, contains(100));

      // Onto the ∞ cell → unlimited (no thumb: the ∞ cell wins).
      await _drag(tester, inf.x - 1, inf.y, inf.x);
      expect(changes, contains(isNull));
      expect(tester.terminalState.findText('█'), isEmpty);
    }, size: const Size(100, 40));
  });

  test('press alone (no motion) jumps the thumb and fires onChanged', () async {
    final changes = <int?>[];
    await testNocterm('round limit slider tap', (tester) async {
      await _mount(tester, value: 40, onChanged: changes.add);
      final ts = tester.terminalState;
      final left = ts.findText('├').single;
      final inf = ts.findText('∞').single;
      final width = inf.x - left.x + 1;
      final midCell = (width - 2) ~/ 2;

      await _drag(tester, left.x + midCell, inf.y, left.x + midCell);
      expect(changes, contains(66));

      // Tap the ∞ cell with no move: press then release at the same spot.
      await _drag(tester, inf.x, inf.y, inf.x);
      expect(changes, contains(isNull));
    }, size: const Size(100, 40));
  });
}

Future<void> _mount(
  dynamic tester, {
  required int? value,
  required void Function(int?) onChanged,
}) async {
  await tester.pumpComponent(
    Container(
      width: 100,
      height: 40,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 5),
                RoundLimitSlider(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _pumpAsync(tester);
}

/// Press on the track, let the tracker flush the parked press, then
/// move (still held) to the target cell and release — a real drag.
Future<void> _drag(dynamic tester, int x0, int y, int x1) async {
  await tester.press(x0, y);
  // The tracker parks the first left press for 50ms; wait it out so the
  // press is delivered before the move.
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await tester.pump();
  await tester.sendMouseEvent(
    MouseEvent(button: MouseButton.left, x: x1, y: y, pressed: true),
  );
  await tester.pump();
  await tester.release(x1, y);
  await _pumpAsync(tester);
}

Future<void> _pumpAsync(dynamic tester) async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

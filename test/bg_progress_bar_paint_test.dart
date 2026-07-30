// Tests for the leading-edge color-interpolation behavior in
// [BgProgressBar]. The bar is N discrete cells wide, so without
// interpolation a fill of 0.37 on a 20-cell bar would render as
// exactly 7 cells filled (and 13 empty), losing ~40% of the
// resolution. With interpolation, the 8th cell's background is
// lerped 40% of the way from empty-color to fill-color, giving
// continuous visual progress.

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:crux/src/components/ui/bg_progress_bar.dart';

void main() {
  // Distinct, easy-to-compare colors so test failures point at the
  // exact color we expected.
  const empty = Color.fromRGB(0, 0, 0); // black
  const fill = Color.fromRGB(255, 255, 255); // white
  const labelFillFg = Color.fromRGB(10, 10, 10);
  const labelEmptyFg = Color.fromRGB(200, 200, 200);

  // Width matches what `ContextBar` uses in production so the test
  // mirrors real usage.
  const width = 20;

  // For a given fill ratio, find the x of the leading-edge cell (the
  // one whose bg is interpolated between empty and fill). Returns -1
  // when there's no partial cell (fill snaps exactly to a cell count).
  int boundaryIdx(double value) {
    final raw = value.clamp(0.0, 1.0) * width;
    final filled = raw.floor();
    final partial = raw - filled;
    if (partial <= 0.0 || filled >= width) return -1;
    return filled;
  }

  Color expectedBoundaryBg(double value) {
    final raw = value.clamp(0.0, 1.0) * width;
    final filled = raw.floor();
    final partial = raw - filled;
    return Color.lerp(empty, fill, partial)!;
  }

  // Wrap the bar in a Column so nocterm's test framework lays out
  // the internal Row correctly. (A Row as the root of pumpComponent
  // doesn't render its children in the test pipeline — see the
  // existing nocterm tests for the Column-wrapped Row pattern.)
  Component mount(double value, {String? label}) {
    return Column(
      children: [
        BgProgressBar(
          value: value,
          width: width,
          label: label,
          fillColor: fill,
          emptyColor: empty,
          labelFillFg: labelFillFg,
          labelEmptyFg: labelEmptyFg,
        ),
      ],
    );
  }

  group('BgProgressBar leading-edge interpolation', () {
    test('exact 0% renders all-empty with no partial cell', () async {
      await testNocterm('0%', (tester) async {
        await tester.pumpComponent(mount(0.0));
        expect(
          boundaryIdx(0.0),
          -1,
          reason: 'no partial cell when value is exactly 0',
        );
        for (var i = 0; i < width; i++) {
          final cell = tester.terminalState.getCellAt(i, 0)!;
          expect(
            cell.style.backgroundColor,
            empty,
            reason: 'cell $i should be empty at 0%',
          );
        }
      });
    });

    test('exact 100% renders all-filled with no partial cell', () async {
      await testNocterm('100%', (tester) async {
        await tester.pumpComponent(mount(1.0));
        expect(
          boundaryIdx(1.0),
          -1,
          reason: 'no partial cell when value is exactly 1',
        );
        for (var i = 0; i < width; i++) {
          final cell = tester.terminalState.getCellAt(i, 0)!;
          expect(
            cell.style.backgroundColor,
            fill,
            reason: 'cell $i should be filled at 100%',
          );
        }
      });
    });

    test('5% fill snaps to exactly one cell, no partial', () async {
      await testNocterm('5%', (tester) async {
        await tester.pumpComponent(mount(0.05));
        // 0.05 * 20 = 1.0 exactly, so no partial.
        expect(boundaryIdx(0.05), -1);
        expect(
          tester.terminalState.getCellAt(0, 0)!.style.backgroundColor,
          fill,
        );
        expect(
          tester.terminalState.getCellAt(1, 0)!.style.backgroundColor,
          empty,
          reason: 'cell 1 onward must be empty at exactly 5%',
        );
      });
    });

    test('1% fill produces a tiny partial on cell 0 (was invisible '
        'before interpolation)', () async {
      await testNocterm('1%', (tester) async {
        await tester.pumpComponent(mount(0.01));
        // 0.01 * 20 = 0.2, partial = 0.2 on cell 0.
        expect(boundaryIdx(0.01), 0);
        expect(
          tester.terminalState.getCellAt(0, 0)!.style.backgroundColor,
          expectedBoundaryBg(0.01),
          reason: 'cell 0 should be lerped 20% toward fill',
        );
        expect(
          tester.terminalState.getCellAt(1, 0)!.style.backgroundColor,
          empty,
          reason: 'cell 1 should be fully empty at 1%',
        );
      });
    });

    test('37% fill: cells 0..6 fully filled, cell 7 is 40% blend', () async {
      await testNocterm('37%', (tester) async {
        await tester.pumpComponent(mount(0.37));
        // 0.37 * 20 = 7.4 → 7 fully filled, cell 7 at 0.4 lerp.
        expect(boundaryIdx(0.37), 7);
        for (var i = 0; i < 7; i++) {
          expect(
            tester.terminalState.getCellAt(i, 0)!.style.backgroundColor,
            fill,
            reason: 'cell $i should be fully filled',
          );
        }
        expect(
          tester.terminalState.getCellAt(7, 0)!.style.backgroundColor,
          expectedBoundaryBg(0.37),
          reason: 'cell 7 should be lerped 40% toward fill',
        );
        for (var i = 8; i < width; i++) {
          expect(
            tester.terminalState.getCellAt(i, 0)!.style.backgroundColor,
            empty,
            reason: 'cell $i should be fully empty',
          );
        }
      });
    });

    test('boundary cell never goes out of bounds at exactly 1.0', () async {
      // Regression: at fillRatio == 1.0, filledCount == width and
      // partial == 0.0. Without the boundaryIdx guard the code
      // would try to lerp the (non-existent) cell at index `width`.
      await testNocterm('regression 1.0', (tester) async {
        await tester.pumpComponent(mount(1.0));
        // No exception, and the last cell is fully filled (not a
        // lerp toward empty).
        expect(
          tester.terminalState.getCellAt(width - 1, 0)!.style.backgroundColor,
          fill,
        );
      });
    });

    test('label spanning the boundary cell picks the dominant fg', () async {
      // With a width-20 bar, a 20-char label covers the whole bar.
      // Verify the fg-color threshold at the boundary label char:
      // partial < 0.5 → labelEmptyFg; partial >= 0.5 → labelFillFg.
      await testNocterm('label fg threshold', (tester) async {
        await tester.pumpComponent(mount(0.22, label: '12345678901234567890'));
        // 0.22 * 20 = 4.4, boundary at cell 4, partial = 0.4 → empty.
        expect(
          tester.terminalState.getCellAt(4, 0)!.style.color,
          labelEmptyFg,
          reason: 'partial 0.4 < 0.5 → empty-side fg on label char',
        );

        await tester.pumpComponent(mount(0.78, label: '12345678901234567890'));
        // 0.78 * 20 = 15.6, boundary at cell 15, partial = 0.6 → fill.
        expect(
          tester.terminalState.getCellAt(15, 0)!.style.color,
          labelFillFg,
          reason: 'partial 0.6 >= 0.5 → fill-side fg on label char',
        );
      });
    });
  });
}

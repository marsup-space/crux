/// Reproduction test matching the actual toolbar layout.
///
/// The toolbar items sit at a positive Y offset (not at screen top),
/// so "above" placement should fit without clamping.
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

String _r(NoctermTester t, int y, {int w = 70}) {
  final b = StringBuffer();
  for (var x = 0; x < w; x++) {
    b.write(t.terminalState.getCellAt(x, y)?.char ?? ' ');
  }
  return b.toString();
}

void main() {
  tearDown(() => HintController.instance.hide());

  // Helper that pumps a toolbar-style layout with the hint overlay,
  // hovers the first item, and returns the position details.
  Future<(Rect?, String?)> hoverItem(
    NoctermTester tester,
    Component hintChild,
  ) async {
    // Toolbar at a non-zero Y (simulating a real chat panel layout
    // where the toolbar sits below the chat history).
    await tester.pumpComponent(
      HintOverlay(
        child: Container(
          child: Column(children: [
            SizedBox(height: 10), // simulate chat history taking 10 rows
            Row(children: [
              Hinted(hint: 'Tooltip here', child: hintChild),
              SizedBox(width: 2),
              Hinted(hint: 'Another hint', child: Text('Btn2')),
            ]),
          ]),
        ),
      ),
    );

    // Hover the first item at y=10 (the toolbar row).
    await tester.hover(1, 10);
    // Process the mouse event + one frame for paint offset.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final sb = HintController.instance.activeSourceBounds;
    final hint = HintController.instance.activeHint;

    // Print the layout for debugging
    print('--- sourceBounds=$sb hint="$hint" visible=${HintController.instance.visible} ---');
    for (var y = 8; y < 15; y++) {
      print('row $y: "${_r(tester, y)}"');
    }

    return (sb, hint);
  }

  test('Text child at y=10 — above placement should fit with gap', () async {
    await testNocterm('text-y10', (tester) async {
      final (sb, hint) = await hoverItem(tester, Text('Txt'));
      // Source at y=10, height=1. Tooltip 3 cells tall.
      // Above: y = 10 - 3 - 1 = 6. Should fit.
      expect(hint, 'Tooltip here');
      // Row 9 should be the 1-cell gap (empty).
      expect(_r(tester, 9).trim(), '');
      // Row 10 should show the source text, not tooltip.
      expect(_r(tester, 10).trim(), contains('Txt'));
    }, size: const Size(80, 20));
  });

  test('MouseRegion child at y=10 — above placement should fit with gap', () async {
    await testNocterm('mouseregion-y10', (tester) async {
      final (sb, hint) = await hoverItem(
        tester,
        // Simulates what Button/MetricsDisplay/GlossyModelButton do:
        // own MouseRegion → Container → Text
        MouseRegion(
          opaque: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text('Btn'),
          ),
        ),
      );
      expect(hint, 'Tooltip here');
      expect(_r(tester, 9).trim(), '');
      expect(_r(tester, 10).trim(), contains('Btn'));
    }, size: const Size(80, 20));
  });

  test('Nested MouseRegion — verify sourceBounds uses outer MouseRegion', () async {
    await testNocterm('nested-mr', (tester) async {
      final (sb, _) = await hoverItem(
        tester,
        MouseRegion(
          opaque: false,
          child: Text('Nst'),
        ),
      );
      expect(sb, isNotNull);
      print('sourceBounds = $sb');
      // The sourceBounds should come from the outer MouseRegion
      // (the HintStateMixin's one), not the inner one.
      // It should be at the toolbar row (y=10).
      if (sb != null) {
        expect(sb.top, greaterThanOrEqualTo(10));
      }
    }, size: const Size(80, 20));
  });
}

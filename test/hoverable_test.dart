import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/ui/hoverable.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  test('shared hover wrapper updates visuals and preserves taps', () async {
    var taps = 0;
    await testNocterm('hoverable', (tester) async {
      await tester.pumpComponent(
        CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: Hoverable(
            onTap: () => taps++,
            builder: (context, hovered) => Container(
              width: 12,
              decoration: BoxDecoration(
                color: hovered
                    ? CruxTheme.of(context).buttonBackgroundHover
                    : CruxTheme.of(context).buttonBackground,
              ),
              child: const Text('click me'),
            ),
          ),
        ),
      );

      expect(
        tester.terminalState.getCellAt(1, 0)?.style.backgroundColor,
        CruxThemeData.draculaFallback.buttonBackground,
      );
      await tester.hover(1, 0);
      expect(
        tester.terminalState.getCellAt(1, 0)?.style.backgroundColor,
        CruxThemeData.draculaFallback.buttonBackgroundHover,
      );
      await tester.tap(1, 0);
      expect(taps, 1);
    }, size: const Size(20, 4));
  });
}

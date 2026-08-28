import 'package:crux/src/components/vibe_box.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  group('VibeBox rendering', () {
    test('renders title and body rows with rounded border', () async {
      await testNocterm('vibe box default', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 40,
              height: 8,
              child: VibeBox(
                title: 'think',
                bodyRows: ['8.2s', '1.2k tokens', 'high'],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(255, 255, 0),
              ),
            ),
          ),
        );

        // Title should be embedded in the border.
        expect(tester.terminalState.findText('think'), isNotEmpty);
        // Body rows should appear.
        expect(tester.terminalState.findText('8.2s'), isNotEmpty);
        expect(tester.terminalState.findText('1.2k tokens'), isNotEmpty);
        expect(tester.terminalState.findText('high'), isNotEmpty);
      });
    });

    test('renders with active styling when active=true', () async {
      await testNocterm('vibe box active', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 40,
              height: 8,
              child: VibeBox(
                title: 'tools',
                bodyRows: ['read: 3× 2.1k tokens'],
                active: true,
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(0, 255, 255),
              ),
            ),
          ),
        );

        expect(tester.terminalState.findText('tools'), isNotEmpty);
        expect(tester.terminalState.findText('read'), isNotEmpty);
      });
    });

    test('renders empty body rows list without error', () async {
      await testNocterm('vibe box empty body', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 20,
              height: 5,
              child: VibeBox(
                title: 'files',
                bodyRows: [],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(255, 255, 0),
              ),
            ),
          ),
        );

        expect(tester.terminalState.findText('files'), isNotEmpty);
      });
    });

    test('narrow content still leaves room for the full title', () async {
      // Regression: content narrower than the title ("0.3s" / "max")
      // shrink-wrapped the box to ~4 columns, so the top border skipped
      // the title entirely. minWidth = title + padding + corners must
      // keep the title visible.
      await testNocterm('vibe box narrow content', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 60,
              height: 8,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VibeBox(
                    title: 'think',
                    bodyRows: ['0.3s', 'max'],
                    mutedColor: const Color.fromRGB(128, 128, 128),
                    activeColor: const Color.fromRGB(255, 255, 0),
                  ),
                ],
              ),
            ),
          ),
        );

        expect(tester.terminalState.findText('think'), isNotEmpty);
        expect(tester.terminalState.findText('0.3s'), isNotEmpty);
        expect(tester.terminalState.findText('max'), isNotEmpty);
      });
    });

    test('box width never exceeds parent when parent is narrower', () async {
      // Parent tighter than title+4: minWidth must clamp, not overflow.
      await testNocterm('vibe box clamped by parent', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 6,
              height: 8,
              child: VibeBox(
                title: 'tools',
                bodyRows: ['x'],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(255, 255, 0),
              ),
            ),
          ),
        );

        // Clamped to 6 columns; body row still renders.
        expect(tester.terminalState.findText('x'), isNotEmpty);
      });
    });
  });
}

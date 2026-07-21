import 'package:crux/src/components/ui/spinner.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/utils/ticker_registry.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('spinner frame logic', () {
    test('frame list matches terminal capability', () {
      final frames = spinnerFrames();
      // Tests run on a rich terminal (non-Windows), so braille.
      expect(frames, kSpinnerFramesBraille);
    });

    test('frameAt cycles through every frame in order', () {
      final frames = spinnerFrames();
      for (var i = 0; i < frames.length; i++) {
        expect(spinnerFrameAt(i), frames[i]);
      }
    });

    test('frameAt wraps around the frame list', () {
      final frames = spinnerFrames();
      expect(spinnerFrameAt(frames.length), frames[0]);
      expect(spinnerFrameAt(frames.length + 3), frames[3]);
    });

    test('braille and ascii fallbacks are distinct and non-empty', () {
      expect(kSpinnerFramesBraille.length, greaterThan(0));
      expect(kSpinnerFramesAscii.length, greaterThan(0));
      expect(kSpinnerFramesBraille, isNot(kSpinnerFramesAscii));
      expect(kSpinnerFramesBraille, hasLength(10));
      expect(kSpinnerFramesAscii, hasLength(4));
    });
  });

  group('Spinner component', () {
    test('renders the first frame and advances on ticks', () async {
      await testNocterm('spinner advances', (tester) async {
        TickerRegistry.instance.resetForTest();
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: const Spinner(),
          ),
        );

        final frames = spinnerFrames();
        expect(tester.terminalState, containsText(frames[0]));

        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.terminalState, containsText(frames[1]));

        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.terminalState, containsText(frames[2]));
      });
    });

    test('dispose cancels the ticker subscription', () async {
      await testNocterm('spinner dispose', (tester) async {
        TickerRegistry.instance.resetForTest();
        // No CruxTheme wrapper needed — the spinner falls back to
        // the dracula default theme when no CruxTheme is in scope,
        // and the bare root makes the subsequent unmount synchronous.
        await tester.pumpComponent(const Spinner());
        expect(TickerRegistry.instance.subscriberCount, 1);

        // Unmount the spinner — its ticker must go away. Pumping a
        // different root component type forces the old subtree to
        // unmount (same-type roots update in place and defer it).
        await tester.pumpComponent(const SizedBox(width: 1, height: 1));
        expect(TickerRegistry.instance.subscriberCount, 0);
      });
    });
  });
}

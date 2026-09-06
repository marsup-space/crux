// Tests for streaming-related toolbar behaviors:
//
// The toolbar's model button has two modes: idle → opens the `/model`
// picker, streaming → interrupts the in-flight response (the button
// flashes while streaming, so clicking it to stop reads naturally).
// Auto-scroll and tok/s ticker registration are covered in
// test/ticker_registry_test.dart and the AutoScrollController
// tests shipped upstream with nocterm.

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:crux/src/components/ui/glossy_model_button.dart';

void main() {
  // ── Model/auxiliary button not clickable during streaming ──

  group('GlossyModelButton clickability', () {
    test(
      'does not fire onPressed when onPressed is null (streaming)',
      () async {
        await testNocterm('glossy-btn-null', (tester) async {
          var tapCount = 0;

          await tester.pumpComponent(
            GlossyModelButton(
              label: 'test/model',
              isAnimating: true,
              onPressed: null,
            ),
          );

          // Tap on the button. With onPressed=null, nothing should happen.
          await tester.tap(2, 0);
          await tester.pump();

          expect(
            tapCount,
            0,
            reason: 'Button with null onPressed must not invoke callback',
          );
        }, size: const Size(40, 5));
      },
    );

    test('fires onPressed when set (not streaming)', () async {
      await testNocterm('glossy-btn-set', (tester) async {
        var tapCount = 0;

        await tester.pumpComponent(
          GlossyModelButton(
            label: 'test/model',
            isAnimating: false,
            onPressed: () => tapCount++,
          ),
        );

        await tester.tap(2, 0);
        await tester.pump();

        expect(
          tapCount,
          1,
          reason: 'Button with onPressed must invoke callback on tap',
        );
      }, size: const Size(40, 5));
    });

    test('fires onPressed while animating (the interrupt path)', () async {
      await testNocterm('glossy-btn-interrupt', (tester) async {
        var interruptCount = 0;

        // Streaming mode: the button animates AND stays clickable —
        // the tap is the interrupt gesture.
        await tester.pumpComponent(
          GlossyModelButton(
            label: 'test/model',
            isAnimating: true,
            onPressed: () => interruptCount++,
          ),
        );

        await tester.tap(2, 0);
        await tester.pump();

        expect(
          interruptCount,
          1,
          reason: 'Streaming model button must fire onPressed (interrupt)',
        );
      }, size: const Size(40, 5));
    });

    test(
      'swaps the label to the hoverLabel on hover while animating',
      () async {
        await testNocterm('glossy-btn-hover-swap', (tester) async {
          await tester.pumpComponent(
            GlossyModelButton(
              label: 'test/model',
              hoverLabel: 'Interrupt',
              isAnimating: true,
              onPressed: () {},
            ),
          );

          // Before hover: the base label is on screen, hover label is not.
          expect(
            tester.renderToString().contains('test/model'),
            isTrue,
            reason: 'base label should render before hover',
          );
          expect(
            tester.renderToString().contains('Interrupt'),
            isFalse,
            reason: 'hover label should be hidden before hover',
          );

          // Hover over the button → the label swaps to the hover label.
          await tester.hover(2, 0);
          await tester.pump();

          expect(
            tester.renderToString().contains('Interrupt'),
            isTrue,
            reason: 'hovering should swap the label to Interrupt',
          );
        }, size: const Size(40, 5));
      },
    );

    test(
      'centers a CJK hover label without changing the button width',
      () async {
        await testNocterm('glossy-btn-hover-cjk-width', (tester) async {
          await tester.pumpComponent(
            Row(
              children: [
                GlossyModelButton(
                  label: 'model-name',
                  hoverLabel: '中断',
                  isAnimating: true,
                  onPressed: () {},
                ),
                const Text('|'),
              ],
            ),
          );

          // 10-column base label + two outer padding cells.
          final markerBefore = tester.terminalState.findText('|').single;
          expect(markerBefore.x, 12);

          await tester.hover(2, markerBefore.y);
          await tester.pump();

          // `中断` is four terminal columns. It is centered in the
          // 10-column label area (three blank columns precede it), and the
          // following widget stays at exactly the same column.
          expect(tester.terminalState.getCellAt(4, markerBefore.y)?.char, '中');
          expect(tester.terminalState.getCellAt(12, markerBefore.y)?.char, '|');
        }, size: const Size(40, 5));
      },
    );

    test('centers a busy min-width auxiliary label', () async {
      await testNocterm('glossy-btn-min-width-centered', (tester) async {
        await tester.pumpComponent(
          Row(
            children: [
              GlossyModelButton(
                label: 'titling…',
                isAnimating: true,
                centerLabel: true,
                minWidth: 12,
              ),
              const Text('|'),
            ],
          ),
        );

        final marker = tester.terminalState.findText('|').single;
        // The 8-column busy label is centered in ten content columns.
        expect(tester.terminalState.getCellAt(2, marker.y)?.char, 't');
        expect(marker.x, 12);
      }, size: const Size(40, 5));
    });

    test('keeps an idle min-width auxiliary label left-aligned', () async {
      await testNocterm('glossy-btn-min-width-idle', (tester) async {
        await tester.pumpComponent(
          Row(
            children: [
              GlossyModelButton(
                label: 'AUX: model',
                isAnimating: false,
                minWidth: 14,
              ),
              const Text('|'),
            ],
          ),
        );

        final marker = tester.terminalState.findText('|').single;
        expect(tester.terminalState.getCellAt(1, marker.y)?.char, 'A');
        expect(marker.x, 14);
      }, size: const Size(40, 5));
    });

    test('renders label even when animating and not clickable', () async {
      await testNocterm('glossy-btn-render', (tester) async {
        await tester.pumpComponent(
          GlossyModelButton(
            label: 'claude/opus',
            isAnimating: true,
            onPressed: null,
          ),
        );

        final rendered = tester.renderToString();
        expect(
          rendered.contains('c'),
          isTrue,
          reason: 'Button label must render even when animating',
        );
      }, size: const Size(40, 5));
    });
  });

  // (Auto-scroll behavior is tested upstream in nocterm's
  // auto_scroll_controller_test.dart.)
}

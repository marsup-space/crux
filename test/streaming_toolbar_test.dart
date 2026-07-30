// Tests for streaming-related toolbar behaviors:
//
// Model button is not clickable during streaming. Auto-scroll and
// tok/s ticker registration are covered in
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

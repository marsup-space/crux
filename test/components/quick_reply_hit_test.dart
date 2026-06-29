// Quick-reply hit-test regression tests.
//
// The ask:// button in the chat panel is hit-tested by reading the
// character index at the local mouse position and asking each
// parsed reply whether that index sits in [renderedStart, renderedStart +
// renderedLength). These tests exercise the full pump → render →
// tap pipeline through a real HighlightedMarkdownText instance so
// regressions in the offset tracking, the MouseRegion wiring, or
// the hit-test comparison surface here.

import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/utils/quick_reply_parser.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('QuickReply button hit-testing', () {
    test('tap on a single button label fires onQuickReplyTap', () async {
      String? tappedAnswer;
      String? tappedLabel;
      await testNocterm('ask single', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 60,
              height: 5,
              child: HighlightedMarkdownText(
                'please pick: ask://Continue{yes, please continue}',
                onQuickReplyTap: (reply) {
                  tappedLabel = reply.label;
                  tappedAnswer = reply.answer;
                },
              ),
            ),
          ),
        );

        // "please pick: " is 13 chars. "Continue" occupies columns
        // 13..20. Click in the middle of the label.
        await tester.tap(16, 0);

        expect(tappedLabel, equals('Continue'));
        expect(tappedAnswer, equals('yes, please continue'));
      }, size: const Size(60, 5));
    });

    test('tap on space between two buttons misses both', () async {
      var tapCount = 0;
      QuickReply? tappedReply;
      await testNocterm('ask miss space', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 60,
              height: 5,
              child: HighlightedMarkdownText(
                'ask://Yes ask://No',
                onQuickReplyTap: (r) {
                  tapCount++;
                  tappedReply = r;
                },
              ),
            ),
          ),
        );

        // Regression: the parser used to capture the trailing
        // space between two shorthand tokens as part of the first
        // token's source range. The renderer then substituted the
        // space along with the `ask://Yes` prefix, producing the
        // rendered text "YesNo" with no separator — clicking on
        // the cell where the space should be (col 3) actually
        // landed on the "N" of "No" and fired that button. The
        // fix trims trailing whitespace off the source range so
        // the space stays as ordinary "before text" for the next
        // token, giving the rendered text "Yes No" with a real
        // gap. Clicking on the space at col 3 now misses.
        await tester.tap(3, 0);
        expect(tapCount, equals(0));
        expect(tappedReply, isNull);

        // But clicking ON the "Yes" label (col 0..2) still hits.
        await tester.tap(0, 0);
        expect(tapCount, equals(1));
        expect(tappedReply?.label, equals('Yes'));

        // And clicking ON the "No" label (col 4..5) hits.
        await tester.tap(4, 0);
        expect(tapCount, equals(2));
        expect(tappedReply?.label, equals('No'));
      }, size: const Size(60, 5));
    });

    test('hover effect applies the hover style to the active label',
        () async {
      await testNocterm('ask hover', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 60,
              height: 5,
              child: HighlightedMarkdownText(
                'pick: ask://Continue{yes}',
                onQuickReplyTap: (_) {},
              ),
            ),
          ),
        );

        // Pump once with no hover — button uses the default
        // (buttonBackground) color, NOT the hover color.
        final theme = CruxThemeData.draculaFallback;
        final cellBefore = tester.terminalState.getCellAt(6, 0)!;
        expect(
          cellBefore.style.backgroundColor,
          isNot(equals(theme.buttonBackgroundHover)),
          reason: 'no hover → button bg is the default, not the hover one',
        );

        // Move cursor onto the "Continue" label (col 6..13). The
        // CJK-free ASCII label lets us test the simple case.
        await tester.hover(8, 0);

        // After hover, the cell at col 8 must use the hover
        // background, not the default.
        final cellAfter = tester.terminalState.getCellAt(8, 0)!;
        expect(
          cellAfter.style.backgroundColor,
          equals(theme.buttonBackgroundHover),
          reason: 'hovering on the label must swap to the hover bg',
        );
      }, size: const Size(60, 5));
    });
  });
}

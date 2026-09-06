import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty;
import 'package:crux/src/components/ui/multi_button.dart';

void main() {
  group('MultiButton', () {
    Future<void> pumpButton(
      NoctermTester tester, {
      required String label,
      required List<MultiButtonSegment> segments,
      double width = 40,
    }) {
      return tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: width,
                child: MultiButton(label: label, segments: segments),
              ),
            ],
          ),
        ),
      );
    }

    test('hover does not change the button width', () async {
      await testNocterm('stable width', (tester) async {
        await pumpButton(
          tester,
          label: '~/projects/crux:main',
          segments: [
            MultiButtonSegment(label: 'open', onPressed: () {}),
            MultiButtonSegment(label: 'switch', onPressed: () {}),
          ],
        );

        // Idle: label fills the 40-cell-wide container.
        expect(tester.terminalState, containsText('~/projects/crux:main'));
        final before = tester.renderToString();

        await tester.hover(5, 0);
        // Advance a handful of frames; the component must settle on its
        // own without an ever-growing frame queue.
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        final after = tester.renderToString();
        final idleRow = before.split('\n')[0];
        final hoverRow = after.split('\n')[0];
        expect(hoverRow.trimRight().length, idleRow.trimRight().length);
      });
    });

    test('hover does not cause a rebuild loop', () async {
      await testNocterm('no rebuild loop', (tester) async {
        await pumpButton(
          tester,
          label: 'project',
          segments: [
            MultiButtonSegment(label: 'open', onPressed: () {}),
            MultiButtonSegment(label: 'switch', onPressed: () {}),
          ],
        );

        await tester.hover(5, 0);
        for (var i = 0; i < 10; i++) {
          await tester.pump();
        }

        final state = tester.findState<State<MultiButton>>() as dynamic;
        // Mount + width-capture + hover enter + a couple of hovers
        // between segments — nowhere near a per-frame rebuild.
        expect(state.debugBuildCount as int, lessThan(15));
      });
    });

    test('segments are evenly distributed across the button', () async {
      await testNocterm('even distribution', (tester) async {
        await pumpButton(
          tester,
          label: 'project',
          segments: [
            MultiButtonSegment(label: 'open', onPressed: () {}),
            MultiButtonSegment(label: 'switch', onPressed: () {}),
          ],
        );

        await tester.hover(5, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        final openPos = tester.terminalState.findText('open');
        final switchPos = tester.terminalState.findText('switch');
        expect(openPos, isNotNull);
        expect(switchPos, isNotNull);

        // 40-cell button, 2 segments → each share is 20 cells wide.
        // 'open' centred in the first share, 'switch' in the second.
        expect(openPos.first.x, lessThan(20));
        expect(switchPos.first.x, greaterThanOrEqualTo(20));
      });
    });

    test('hover never widens beyond the idle footprint', () async {
      await testNocterm('no growth', (tester) async {
        // Long segment labels that would previously overflow.
        await pumpButton(
          tester,
          label: 'p',
          segments: [
            MultiButtonSegment(label: 'open-in-explorer', onPressed: () {}),
            MultiButtonSegment(label: 'switch-project', onPressed: () {}),
          ],
        );

        await tester.hover(2, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        // The button must not paint any non-blank content past the
        // 40-cell container, regardless of how wide the terminal is.
        for (var x = 40; x < 80; x++) {
          final cell = tester.terminalState.getCellAt(x, 0);
          final ch = cell?.char ?? ' ';
          expect(ch, ' ', reason: 'cell at x=$x should be blank');
        }
      });
    });

    test('tapping a segment fires its callback', () async {
      await testNocterm('tap segment', (tester) async {
        var opened = false;
        var switched = false;
        await pumpButton(
          tester,
          label: 'project',
          segments: [
            MultiButtonSegment(label: 'open', onPressed: () => opened = true),
            MultiButtonSegment(
              label: 'switch',
              onPressed: () => switched = true,
            ),
          ],
        );

        await tester.hover(5, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        // 'switch' lives in the second half of the 40-cell button.
        await tester.tap(30, 0);
        expect(switched, isTrue);
        expect(opened, isFalse);
      });
    });

    test('hover preserves multi-row height when label wraps', () async {
      await testNocterm('multi-row height', (tester) async {
        // A 20-cell-wide button with a 38-cell label wraps to 2 rows.
        await pumpButton(
          tester,
          width: 20,
          label: 'averylongprojectnamethatwraps',
          segments: [
            MultiButtonSegment(label: 'open', onPressed: () {}),
            MultiButtonSegment(label: 'switch', onPressed: () {}),
          ],
        );

        final before = tester.renderToString();
        final idleLines = before.split('\n');
        // The idle label wraps to at least 2 rows.
        expect(idleLines.length, greaterThanOrEqualTo(2));

        await tester.hover(5, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }

        final after = tester.renderToString();
        final hoverLines = after.split('\n');
        // Hover must keep the same number of rows — not collapse to 1.
        expect(hoverLines.length, idleLines.length);
      });
    });

    test('constrained idle label reserves every wrapped row', () async {
      await testNocterm('constrained idle height', (tester) async {
        // The label is intrinsically wider than the parent. The button must
        // calculate its footprint from the 20-cell constraint, not its
        // unconstrained label width, so its second line cannot paint below
        // the enclosing box.
        await tester.pumpComponent(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                child: MultiButton(
                  label: 'averylongprojectnamethatwraps',
                  segments: [MultiButtonSegment(label: 'open')],
                ),
              ),
              const Text('after'),
            ],
          ),
        );

        final labelRows = tester.terminalState
            .findText('averylongprojectna')
            .map((hit) => hit.y)
            .toSet();
        expect(labelRows.length, 1);
        // The rest of the label has wrapped, and the next sibling is placed
        // after both content rows rather than overlapping the second one.
        expect(tester.terminalState.findText('methatwraps'), isNotEmpty);
        final wrappedText = tester.terminalState.findText('methatwraps');
        final afterText = tester.terminalState.findText('after');
        expect(afterText.first.y, greaterThan(wrappedText.first.y));
      }, size: const Size(20, 10));
    });
  });
}

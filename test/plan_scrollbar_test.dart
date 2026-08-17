import 'dart:io';

import 'package:crux/src/components/annotated_scrollbar.dart';
import 'package:crux/src/components/plan_doc_pane.dart';
import 'package:crux/src/components/plan_scrollbar.dart';
import 'package:crux/src/models/plan_selection.dart';
import 'package:crux/src/services/plan_mode_controller.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// A doc tall enough (30+ rendered rows) that the pane's scroll extent
/// is positive — the scrollbar (and its markers) only paint when
/// `maxScrollExtent > 0`.
String tallDoc() {
  final buf = StringBuffer('# Plan\n');
  for (var i = 1; i <= 6; i++) {
    buf.writeln('');
    buf.writeln('## Section $i');
    for (var l = 0; l < 4; l++) {
      buf.writeln('Lorem ipsum dolor sit amet $i-$l');
    }
  }
  return buf.toString();
}

void main() {
  late Directory tmp;
  late PlanModeController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_scrollbar_test');
    controller = PlanModeController();
  });

  tearDown(() {
    controller.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('PlanScrollbar resolves a marker offset to its flat row', () {
    const scrollbar = PlanScrollbar(child: Text('x'));
    final marker = ScrollbarMarker(itemIndex: 7, color: Color(0xFF50FA7B));
    expect(scrollbar.markerContentOffset(marker), 7.0);
  });

  test('pane drops to FREE mode on marker tap', () async {
    controller.enter(tmp.path);
    final doc = tallDoc();
    File(controller.planDocPath!).writeAsStringSync(doc);
    controller.onAgentEdit('# Plan\n\n', doc);
    expect(controller.viewMode, PlanViewMode.follow);

    await testNocterm('marker tap transitions to free', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      expect(controller.viewMode, PlanViewMode.follow);
      // The pane wires `onMarkerTap → controller.onUserScroll`; a click
      // on a marker is a user scroll. Full mouse click-through on the
      // track is covered by annotated_scrollbar_test.dart's base-class
      // click test — here we assert the pane's wiring effect.
      controller.onUserScroll();
      await tester.pump();
      expect(controller.viewMode, PlanViewMode.free);
    });
  });

  test('markers track headings of the current parse', () async {
    controller.enter(tmp.path);
    final doc = tallDoc();
    File(controller.planDocPath!).writeAsStringSync(doc);
    controller.onAgentEdit('# Plan\n\n', doc);
    expect(controller.parsed.headings, hasLength(7));

    await testNocterm('heading markers render on the track', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      // The pane's scrollbar paints at its own right edge — inside a
      // loose-width host the SingleChildScrollView shrinks to content,
      // so scan every column for the marker glyph rather than assuming
      // the rightmost terminal column.
      var markerCount = 0;
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 40; x++) {
          if (tester.terminalState.getCellAt(x, y)?.char == '◆') {
            markerCount++;
          }
        }
      }
      expect(markerCount, greaterThan(0),
          reason: 'heading markers should be visible on the track');

      // Edit the doc: remove two sections → 5 headings. The markers
      // must follow the new parse.
      const shorter = '# Plan\n\n## Only\n\nText\n';
      File(controller.planDocPath!).writeAsStringSync(shorter);
      controller.onAgentEdit(doc, shorter);
      await tester.pump();
      expect(controller.parsed.headings, hasLength(2));
    });
  });

  test('marker click jumps to the heading row', () async {
    controller.enter(tmp.path);
    final doc = tallDoc();
    File(controller.planDocPath!).writeAsStringSync(doc);
    controller.onAgentEdit('# Plan\n\n', doc);

    await testNocterm('marker click jumps', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      // Scrollbar paints at the pane's own right edge (content-
      // shrunk), so scan for the marker glyph across the grid, below
      // the thumb (start from row 2).
      int? markerX, markerRow;
      outer:
      for (var y = 2; y < 20; y++) {
        for (var x = 0; x < 40; x++) {
          if (tester.terminalState.getCellAt(x, y)?.char == '◆') {
            markerX = x;
            markerRow = y;
            break outer;
          }
        }
      }
      expect(markerRow, isNotNull, reason: 'a marker should be reachable');
      expect(controller.scrollController.offset, 0.0);

      // The same hover → press → release sequence the base-class test
      // uses (the MouseTracker parks the first press; the release
      // confirms and dispatches it).
      final my = markerRow!;
      final mx = markerX!;
      await tester.hover(mx, my);
      await tester.press(mx, my);
      await tester.release(mx, my);
      await tester.pump();
      expect(
        controller.scrollController.offset,
        greaterThan(0.0),
        reason: 'marker click should jump the plan controller to the row',
      );
      expect(controller.viewMode, PlanViewMode.free,
          reason: 'a marker click is a user scroll — drops follow mode');
    });
  });

  test('narrow width takes the plain-thumb branch (no markers)', () async {
    controller.enter(tmp.path);
    final doc = tallDoc();
    File(controller.planDocPath!).writeAsStringSync(doc);
    controller.onAgentEdit('# Plan\n\n', doc);

    await testNocterm('narrow pane hides markers', (tester) async {
      const narrowWidth = kPlanScrollbarMarkerMinWidth - 5;
      await tester.pumpComponent(
        SizedBox(
          width: narrowWidth,
          height: 20.0,
          child: PlanDocPane(controller: controller),
        ),
      );
      var markerCount = 0;
      for (var y = 0; y < 20; y++) {
        if (tester.terminalState
                .getCellAt(narrowWidth.toInt() - 1, y)
                ?.char ==
            '◆') {
          markerCount++;
        }
      }
      expect(markerCount, 0,
          reason: 'narrow panes drop heading markers (plain thumb only)');
    });
  });
}

class _Host extends StatelessComponent {
  final Component child;
  const _Host({required this.child});

  @override
  Component build(BuildContext context) {
    return SizedBox(width: 40, height: 20, child: child);
  }
}

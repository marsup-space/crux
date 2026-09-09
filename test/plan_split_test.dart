import 'package:crux/src/components/plan_doc_pane.dart';
import 'package:test/test.dart';

void main() {
  group('resolvePlanSplit', () {
    test('plan inactive: keeps the bare sidebar decision', () {
      // Wide terminal — sidebar shown at its natural width.
      final wide = resolvePlanSplit(140, planActive: false, sidebarWidth: 40);
      expect(wide.showSidebar, isTrue);
      expect(wide.sidebarWidth, 40);
      expect(wide.planPaneWidth, 0);

      // Narrow terminal — caller passes null (below threshold).
      final narrow = resolvePlanSplit(
        90,
        planActive: false,
        sidebarWidth: null,
      );
      expect(narrow.showSidebar, isFalse);
      expect(narrow.planPaneWidth, 0);
    });

    test('very wide terminal: sidebar + plan, even split with no cap', () {
      // 220 cols (≥ kPlanSidebarShowThreshold): sidebar 40, two
      // dividers, remaining 178 halves to 89 plan / 89 chat — no max.
      final l = resolvePlanSplit(220, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isTrue);
      expect(l.planPaneWidth, 88.5);
    });

    test('sidebar hides outright below the 210-col threshold', () {
      // 160 cols: even though the three-pane split would leave chat
      // roomy (58.5 plan / 59.5 chat), the hard width floor drops the
      // sidebar; two-pane split: avail 159 → plan 79, chat 80.
      final l = resolvePlanSplit(160, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isFalse);
      expect(l.sidebarWidth, 0);
      expect(l.planPaneWidth, 79);
    });

    test('sidebar survives at exactly the threshold', () {
      // 210 cols: sidebar 40 → avail 168 → plan 83.5, chat 84.5 ≥ 56.
      final l = resolvePlanSplit(210, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isTrue);
      expect(l.planPaneWidth, 83.5);
    });

    test('sidebar drops one column below the threshold', () {
      // 209 cols: below the floor → drop; two-pane: avail 208 →
      // plan 103.5, chat 104.5.
      final l = resolvePlanSplit(209, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isFalse);
      expect(l.planPaneWidth, 103.5);
    });

    test('narrow: sidebar already gone, plan halves with chat', () {
      // 80 cols, no sidebar: avail 79 → plan 39, chat 40.
      final l = resolvePlanSplit(80, planActive: true, sidebarWidth: null);
      expect(l.showSidebar, isFalse);
      expect(l.planPaneWidth, 39);
    });

    test('extreme narrow: plan still halves with no minimum', () {
      // 50 cols: avail 49 → plan 24, chat 25 — no 30-col floor.
      final l = resolvePlanSplit(50, planActive: true, sidebarWidth: null);
      expect(l.planPaneWidth, 24);
    });

    test('plan pane is never wider than chat at common widths', () {
      // Sweep the realistic terminal widths; plan ≤ chat everywhere
      // (chat keeps the odd column of the halved split).
      for (var w = 60.0; w <= 260; w++) {
        for (final sidebar in <double?>[null, 28, 34, 40]) {
          final l = resolvePlanSplit(
            w,
            planActive: true,
            sidebarWidth: sidebar,
          );
          final dividers = l.showSidebar ? 2 : 1;
          final chat =
              w -
              l.planPaneWidth -
              (l.showSidebar ? l.sidebarWidth : 0) -
              dividers;
          expect(
            l.planPaneWidth <= chat + 1,
            isTrue,
            reason:
                'w=$w sidebar=$sidebar: plan ${l.planPaneWidth} '
                'vs chat $chat',
          );
        }
      }
    });
  });
}

import 'package:crux/src/components/plan_doc_pane.dart';
import 'package:test/test.dart';

void main() {
  group('resolvePlanSplit', () {
    test('plan inactive: keeps the bare sidebar decision', () {
      // Wide terminal — sidebar shown at its natural width.
      final wide = resolvePlanSplit(
        140,
        planActive: false,
        sidebarWidth: 40,
      );
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

    test('very wide terminal: sidebar + plan, plan == chat', () {
      // 160 cols: sidebar 40, two dividers, remaining 118 halves
      // (plan takes the floor) so chat keeps the extra column.
      final l = resolvePlanSplit(160, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isTrue);
      expect(l.planPaneWidth, 58.5);
    });

    test('plan drops the sidebar when chat would starve', () {
      // 120 cols: sidebar 34 → avail 84 → plan 41.5, chat 42.5 < 56
      // → sidebar drops; two-pane split: avail 119 → plan 59,
      // chat 60 ≥ plan. ✓
      final l = resolvePlanSplit(120, planActive: true, sidebarWidth: 34);
      expect(l.showSidebar, isFalse);
      expect(l.sidebarWidth, 0);
      expect(l.planPaneWidth, 59);
    });

    test('sidebar survives when three panes still leave chat roomy', () {
      // 160 cols: sidebar 40 → avail 118 → plan 58.5, chat 59.5 ≥ 56.
      final l = resolvePlanSplit(160, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isTrue);
      expect(l.planPaneWidth, 58.5);
    });

    test('sidebar drops at 150 cols (below the 56-col chat floor)', () {
      // 150 cols: sidebar 40 → avail 108 → plan 53.5, chat 54.5 < 56
      // → drop; two-pane: avail 149 → plan 74, chat 75.
      final l = resolvePlanSplit(150, planActive: true, sidebarWidth: 40);
      expect(l.showSidebar, isFalse);
      expect(l.planPaneWidth, 74);
    });

    test('narrow: sidebar already gone, plan halves with chat', () {
      // 80 cols, no sidebar: avail 79 → plan 39, chat 40.
      final l = resolvePlanSplit(
        80,
        planActive: true,
        sidebarWidth: null,
      );
      expect(l.showSidebar, isFalse);
      expect(l.planPaneWidth, 39);
    });

    test('extreme narrow: plan clamps to its 30-col minimum', () {
      final l = resolvePlanSplit(
        50,
        planActive: true,
        sidebarWidth: null,
      );
      expect(l.planPaneWidth, kPlanPaneMinWidth);
    });

    test('plan pane is never wider than chat at common widths', () {
      // Sweep the realistic terminal widths; plan ≤ chat everywhere
      // except the documented ≲60-col single-column territory.
      for (var w = 60.0; w <= 220; w++) {
        for (final sidebar in <double?>[null, 28, 34, 40]) {
          final l = resolvePlanSplit(
            w,
            planActive: true,
            sidebarWidth: sidebar,
          );
          final dividers = l.showSidebar ? 2 : 1;
          final chat = w - l.planPaneWidth - (l.showSidebar ? l.sidebarWidth : 0) - dividers;
          expect(l.planPaneWidth <= chat + 1, isTrue,
              reason: 'w=$w sidebar=$sidebar: plan ${l.planPaneWidth} '
                  'vs chat $chat');
        }
      }
    });
  });
}

// Regression test: the plan pane must sync the real theme into the
// controller on FIRST mount. Previously the sync lived only in the
// pane's controller-listener callback, but `PlanModeController.enter`
// fires its `notifyListeners()` before the pane exists — so the first
// open painted spans parsed with the colorless mono fallback until
// some later controller event happened to run the sync. Re-opening
// looked correct only because the controller's `_theme` survived the
// previous lifecycle.
import 'dart:io';

import 'package:crux/src/components/plan_doc_pane.dart';
import 'package:crux/src/services/plan_mode_controller.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PlanModeController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_theme_sync_test');
    controller = PlanModeController();
    // `enter` parses with the mono fallback (no theme set yet) —
    // exactly the production sequence when `/plan` runs before the
    // pane mounts.
    controller.enter(tmp.path);
  });

  tearDown(() {
    controller.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('pane first mount syncs the real theme before painting', () async {
    expect(controller.theme, isNull,
        reason: 'precondition: enter() parsed with the mono fallback');
    await testNocterm('plan theme sync', (tester) async {
      await tester.pumpComponent(
        SizedBox(width: 60, height: 20, child: PlanDocPane(controller: controller)),
      );
      // No controller event fired after the pane mounted — the theme
      // must already be the CruxThemeData context's theme via
      // didChangeDependencies, not via a listener-only path.
      expect(controller.theme, isA<CruxThemeData>(),
          reason: 'pane must inject the real theme on first mount');
    });
  });
}

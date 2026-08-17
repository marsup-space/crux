import 'dart:io';

import 'package:crux/src/components/plan_doc_pane.dart';
import 'package:crux/src/services/plan_mode_controller.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PlanModeController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_timeline_test');
    controller = PlanModeController();
    controller.enter(tmp.path);
  });

  tearDown(() {
    controller.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('timeline shows a numeric button per version', () async {
    await testNocterm('timeline head', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      expect(controller.headVersion, 1);
      // The strip shows the bare version number (`1`), with `HEAD` /
      // `viewing v…` kept in the header/status area — the strip itself
      // no longer renders the literal `HEAD` text (numeric labels only).
      expect(tester.terminalState.containsText('1'), isTrue);
    });
  });

  test('clicking a past version time-travels the pane read-only', () async {
    // Grow to v2 so there's a past version to view.
    final path = controller.planDocPath!;
    const v2 = '# Plan\n\n## Second\n';
    File(path).writeAsStringSync(v2);
    controller.onAgentEdit('# Plan\n\n', v2);
    expect(controller.headVersion, 2);

    await testNocterm('timeline view past', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      // View v1 — pure UI; the file on disk stays at HEAD (v2).
      controller.viewVersion(1);
      await tester.pump();
      expect(controller.isViewingHistory, isTrue);
      expect(controller.viewingVersion, 1);
      expect(File(path).readAsStringSync(), v2); // unchanged on disk
    });
  });

  test('revert restores the target content as a new HEAD', () async {
    final path = controller.planDocPath!;
    const v2 = '# Plan\n\n## Second\n';
    File(path).writeAsStringSync(v2);
    controller.onAgentEdit('# Plan\n\n', v2);
    expect(controller.headVersion, 2);

    await testNocterm('timeline revert', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      controller.revertTo(1);
      await tester.pump();
      expect(controller.headVersion, 3);
      expect(controller.docText, '# Plan\n\n');
      expect(File(path).readAsStringSync(), '# Plan\n\n');
      expect(controller.pendingRevert, isNotNull);
    });
  });
}

/// Minimal host that sizes the pane and provides a theme context.
class _Host extends StatelessComponent {
  final Component child;
  const _Host({required this.child});

  @override
  Component build(BuildContext context) {
    return SizedBox(width: 60, height: 20, child: child);
  }
}

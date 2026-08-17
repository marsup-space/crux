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

  test('many versions render within the pane width (no ~ glyphs)',
      () async {
    // Grow to 30 versions so the strip overflows the 60-col host.
    final path = controller.planDocPath!;
    var last = '# Plan\n\n';
    for (var v = 2; v <= 30; v++) {
      final next = '# Plan\n\n## rev $v\n';
      File(path).writeAsStringSync(next);
      controller.onAgentEdit(last, next);
      last = next;
    }
    expect(controller.headVersion, 30);

    await testNocterm('timeline overflow window', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      // The strip must not truncate with `~` glyphs, and HEAD (30)
      // must be reachable — the trailing window keeps the most
      // recent versions.
      expect(tester.terminalState.containsText('~'), isFalse);
      expect(tester.terminalState.containsText('30'), isTrue);

      // When viewing an old version that falls off the left edge of
      // the trailing window, the window slides so the viewed version
      // stays reachable.
      controller.viewVersion(5);
      await tester.pump();
      expect(controller.isViewingHistory, isTrue);
      expect(tester.terminalState.containsText('5'), isTrue);
    });
  });

  test('clicking a version button calls viewVersion', () async {
    final path = controller.planDocPath!;
    const v2 = '# Plan\n\n## Second\n';
    File(path).writeAsStringSync(v2);
    controller.onAgentEdit('# Plan\n\n', v2);

    await testNocterm('timeline click view', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      // Locate the strip's `1` button by scanning the footer area
      // (bottom rows) and clicking the cell holding the digit.
      const hostW = 60, hostH = 20;
      int? digitX, digitY;
      outer:
      for (var y = hostH - 4; y < hostH; y++) {
        for (var x = 0; x < hostW; x++) {
          final cell = tester.terminalState.getCellAt(x, y);
          if (cell?.char == '1') {
            // Ensure the neighbors aren't `1x`/`x1` from other text —
            // the strip shows bare single digits separated by spaces.
            final left = x > 0 ? tester.terminalState.getCellAt(x - 1, y)?.char : null;
            final right = x + 1 < hostW ? tester.terminalState.getCellAt(x + 1, y)?.char : null;
            final isolated = (left == null || left == ' ') &&
                (right == null || right == ' ');
            if (isolated) {
              digitX = x;
              digitY = y;
              break outer;
            }
          }
        }
      }
      expect(digitX, isNotNull, reason: 'the `1` version button should render');
      await tester.hover(digitX!, digitY!);
      await tester.press(digitX, digitY);
      await tester.release(digitX, digitY);
      await tester.pump();
      expect(controller.viewingVersion, 1,
          reason: 'clicking the `1` button should time-travel to v1');
      expect(controller.isViewingHistory, isTrue);
    }, size: const Size(60, 20));
  });

  test('header buttons approve / unapprove and exit plan mode', () async {
    await testNocterm('pane header buttons', (tester) async {
      await tester.pumpComponent(
        _Host(child: PlanDocPane(controller: controller)),
      );
      expect(controller.active, isTrue);
      expect(controller.approved, isFalse);

      // The header renders localized labels (default host = English
      // fallback, `this.strings = kEnglishStrings`).
      expect(tester.terminalState.containsText('approve'), isTrue);
      expect(tester.terminalState.containsText('exit'), isTrue);

      // Locate and click the `approve` label: scan the top rows for an
      // isolated `approve` run and click its center cell.
      const hostW = 60;
      int? approveX, approveY;
      outer:
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x + 6 < hostW; x++) {
          final cell = tester.terminalState.getCellAt(x, y);
          if (cell?.char == 'a' &&
              tester.terminalState.getCellAt(x + 1, y)?.char == 'p' &&
              tester.terminalState.getCellAt(x + 6, y)?.char == 'e') {
            approveX = x + 3;
            approveY = y;
            break outer;
          }
        }
      }
      expect(approveX, isNotNull, reason: 'the approve button should render');
      await tester.hover(approveX!, approveY!);
      await tester.press(approveX, approveY);
      await tester.release(approveX, approveY);
      await tester.pump();
      expect(controller.approved, isTrue,
          reason: 'clicking approve should approve the plan');

      // After approval the same button flips to `unapprove`.
      expect(tester.terminalState.containsText('unapprove'), isTrue);

      // Click `exit` — the pane collapses (controller goes inactive).
      int? exitX, exitY;
      outer:
      for (var y = 0; y < 4; y++) {
        for (var x = hostW - 1; x - 3 >= 0; x--) {
          final cell = tester.terminalState.getCellAt(x, y);
          if (cell?.char == 't' &&
              tester.terminalState.getCellAt(x - 1, y)?.char == 'i' &&
              tester.terminalState.getCellAt(x - 3, y)?.char == 'e') {
            exitX = x - 1;
            exitY = y;
            break outer;
          }
        }
      }
      expect(exitX, isNotNull, reason: 'the exit button should render');
      await tester.hover(exitX!, exitY!);
      await tester.press(exitX, exitY);
      await tester.release(exitX, exitY);
      await tester.pump();
      expect(controller.active, isFalse,
          reason: 'clicking exit should leave plan mode');
    }, size: const Size(60, 20));
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

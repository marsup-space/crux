import 'dart:io';

import 'package:crux/src/models/plan_selection.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/plan_mode_controller.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PlanModeController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_ctrl_test');
    controller = PlanModeController();
  });

  tearDown(() {
    controller.dispose();
    tmp.deleteSync(recursive: true);
  });

  group('PlanModeController lifecycle', () {
    test('enter creates the plan file with a skeleton and activates', () {
      controller.enter(tmp.path);
      expect(controller.active, isTrue);
      expect(controller.planDocPath, endsWith('PLAN.md'));
      expect(File(controller.planDocPath!).readAsStringSync(), '# Plan\n\n');
    });

    test('enter with a custom name appends .md', () {
      controller.enter(tmp.path, planName: 'roadmap');
      expect(controller.planDocPath, endsWith('roadmap.md'));
    });

    test('exit deactivates and clears state', () {
      controller.enter(tmp.path);
      controller.exit();
      expect(controller.active, isFalse);
      expect(controller.planDocPath, isNull);
      expect(controller.selection, isNull);
    });

    test('mirrors planDocPath into SessionRuntimeState on enter/exit (P6)', () {
      final runtime = SessionRuntimeState(sessionId: 7);
      final c = PlanModeController(runtimeFor: () => runtime);
      addTearDown(c.dispose);

      expect(runtime.planDocPath, isNull);
      c.enter(tmp.path);
      expect(runtime.planDocPath, c.planDocPath,
          reason: 'the tool guards + system-prompt block read this field');
      c.exit();
      expect(runtime.planDocPath, isNull);
    });

    test('enter initializes the version log at v1', () {
      controller.enter(tmp.path);
      expect(controller.headVersion, 1);
      expect(controller.viewingVersion, 1);
      expect(controller.isViewingHistory, isFalse);
    });
  });

  group('follow / free scroll state machine', () {
    test('starts in follow mode', () {
      controller.enter(tmp.path);
      expect(controller.viewMode, PlanViewMode.follow);
    });

    test('user scroll transitions follow → free and saves offset', () {
      controller.enter(tmp.path);
      controller.onUserScroll();
      expect(controller.viewMode, PlanViewMode.free);
    });

    test('jump to latest returns to follow', () {
      controller.enter(tmp.path);
      controller.onUserScroll();
      controller.onJumpToLatest();
      expect(controller.viewMode, PlanViewMode.follow);
    });
  });

  group('onAgentEdit', () {
    test('appends a new version and flashes changed rows', () {
      controller.enter(tmp.path);
      final path = controller.planDocPath!;
      const newText = '# Plan\n\n- first milestone\n';
      File(path).writeAsStringSync(newText);
      controller.onAgentEdit('# Plan\n\n', newText);
      expect(controller.headVersion, 2);
      expect(controller.activeFlashes, isNotEmpty);
    });

    test('stores the new doc text', () {
      controller.enter(tmp.path);
      const newText = '# Plan\n\n## Goals\n';
      File(controller.planDocPath!).writeAsStringSync(newText);
      controller.onAgentEdit('# Plan\n\n', newText);
      expect(controller.docText, newText);
    });
  });

  group('revert', () {
    test('revertTo appends a new version equal to the target', () {
      controller.enter(tmp.path);
      final path = controller.planDocPath!;
      // v2
      const v2 = '# Plan\n\n## A\n';
      File(path).writeAsStringSync(v2);
      controller.onAgentEdit('# Plan\n\n', v2);
      expect(controller.headVersion, 2);

      // Revert to v1 → creates v3 whose content == v1.
      controller.revertTo(1);
      expect(controller.headVersion, 3);
      expect(controller.docText, '# Plan\n\n');
      expect(File(path).readAsStringSync(), '# Plan\n\n');
    });

    test('revert sets a pendingRevert event consumed once', () {
      controller.enter(tmp.path);
      controller.revertTo(1);
      expect(controller.pendingRevert, isNotNull);
      expect(controller.pendingRevert!.toVersion, 1);
      controller.clearPendingRevert();
      expect(controller.pendingRevert, isNull);
    });
  });

  group('selection', () {
    test('onSelectionRange stores a PlanSelection with verbatim text', () {
      controller.enter(tmp.path);
      const text = '# Plan\n\nSome **bold** text\n';
      File(controller.planDocPath!).writeAsStringSync(text);
      controller.onAgentEdit('# Plan\n\n', text);
      // Select "bold" in the rendered text.
      final rendered = controller.parsed.renderedText;
      final start = rendered.indexOf('bold');
      controller.onSelectionRange(start, start + 4);
      final sel = controller.selection;
      expect(sel, isNotNull);
      expect(sel!.text, 'bold');
      expect(sel.fromVersion, controller.viewingVersion);
    });

    test('clearSelection empties the selection', () {
      controller.enter(tmp.path);
      const text = '# Plan\n\nhello world\n';
      File(controller.planDocPath!).writeAsStringSync(text);
      controller.onAgentEdit('# Plan\n\n', text);
      controller.onSelectionRange(0, 3);
      expect(controller.selection, isNotNull);
      controller.clearSelection();
      expect(controller.selection, isNull);
    });
  });
}

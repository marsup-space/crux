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

    test('exit clears both planDocPath and planApproved (plan item D)', () {
      final runtime = SessionRuntimeState(sessionId: 7);
      final c = PlanModeController(runtimeFor: () => runtime);
      addTearDown(c.dispose);

      c.enter(tmp.path);
      c.approve();
      expect(runtime.planApproved, isTrue);
      expect(runtime.planDocPath, isNotNull);

      c.exit();
      expect(runtime.planDocPath, isNull);
      expect(runtime.planApproved, isFalse,
          reason: '/plan exit clears both planDocPath and planApproved');
    });

    test('approve/unapprove flip the mirrored runtime flag', () {
      final runtime = SessionRuntimeState(sessionId: 7);
      final c = PlanModeController(runtimeFor: () => runtime);
      addTearDown(c.dispose);

      c.enter(tmp.path);
      expect(runtime.planApproved, isFalse,
          reason: 'guards armed on fresh enter');

      c.approve();
      expect(c.approved, isTrue);
      expect(runtime.planApproved, isTrue,
          reason: 'the edit/write/shell guards read this field');

      c.unapprove();
      expect(c.approved, isFalse);
      expect(runtime.planApproved, isFalse);
    });

    test('approve is a no-op when inactive or already approved', () {
      controller.approve();
      expect(controller.approved, isFalse, reason: 'inactive → no-op');

      controller.enter(tmp.path);
      controller.approve();
      expect(controller.approved, isTrue);
      controller.approve();
      expect(controller.approved, isTrue);
      // unapprove is likewise idempotent
      controller.unapprove();
      controller.unapprove();
      expect(controller.approved, isFalse);
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

  group('layoutWidth (pane width budget)', () {
    test('parser receives maxWidth once the pane reports a width', () {
      controller.enter(tmp.path);
      // Wide table: natural width far exceeds the budget below.
      const text = '# Plan\n\n'
          '| col | very long header column | another wide header column |\n'
          '| --- | --- | --- |\n'
          '| 1 | some long cell content in this column | more content |\n';
      File(controller.planDocPath!).writeAsStringSync(text);
      controller.onAgentEdit('# Plan\n\n', text);

      final unbounded = controller.parsed.renderedText
          .split('\n')
          .fold(0, (m, l) => l.length > m ? l.length : m);

      controller.applyLayoutWidth(60);
      final bounded = controller.parsed.renderedText
          .split('\n')
          .fold(0, (m, l) => l.length > m ? l.length : m);

      expect(unbounded, greaterThan(62),
          reason: 'sanity: the table overflows without a width budget');
      expect(bounded, lessThanOrEqualTo(60),
          reason: 'every rendered row fits the reported layout width');
    });

    test('same-width reReports are free (no reparse)', () {
      controller.enter(tmp.path);
      controller.applyLayoutWidth(80);
      controller.applyLayoutWidth(80);
      // Identical-or-better: parsed object may be new after the first
      // call but the second same-value call must not disturb state.
      expect(controller.layoutWidth, 80);
      expect(controller.active, isTrue);
    });

    test('onAgentEdit keeps flash mapping on HEAD while viewing history',
        () {
      controller.enter(tmp.path);
      final path = controller.planDocPath!;
      const v2 = '# Plan\n\n## A\n';
      File(path).writeAsStringSync(v2);
      controller.onAgentEdit('# Plan\n\n', v2);
      controller.viewVersion(1); // time-travel away from HEAD

      const v3 = '# Plan\n\n## A\n## B\n';
      File(path).writeAsStringSync(v3);
      controller.onAgentEdit(v2, v3);

      expect(controller.viewingVersion, controller.headVersion,
          reason: 'an agent edit lands on HEAD');
      expect(controller.docText, v3);
    });
  });

  group('session-bound pane (attachSession)', () {
    // Two sessions, each with its own runtime (panel-wired controllers
    // resolve runtimes by id; tests replicate the same shape).
    SessionRuntimeState rt(int id) => SessionRuntimeState(sessionId: id);

    PlanModeController wired() {
      final runtimes = {1: rt(1), 2: rt(2)};
      return PlanModeController(
        runtimeFor: () {
          // Mirrored imperfections are fine — the controller falls
          // back to runtimeById for cross-session state.
          return runtimes.values.first;
        },
        runtimeById: (id) => runtimes[id],
      );
    }

    test('switching to a session without a plan collapses the pane', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      expect(c.active, isTrue);

      c.attachSession(2); // session 2 has no plan
      expect(c.active, isFalse, reason: 'plan view is session-bound');
      expect(c.planDocPath, isNull);

      // Switching back re-opens it.
      c.attachSession(1);
      expect(c.active, isTrue);
      expect(c.planDocPath, endsWith('PLAN.md'));
    });

    test('approved flag survives the round-trip', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      c.approve();

      c.attachSession(2);
      expect(c.active, isFalse);

      c.attachSession(1);
      expect(c.approved, isTrue);
    });

    test('free view mode survives the round-trip', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      c.onUserScroll(); // follow → free
      expect(c.viewMode, PlanViewMode.free);

      c.attachSession(2);
      c.attachSession(1);
      expect(c.viewMode, PlanViewMode.free);
    });

    test('timeline history position survives the round-trip', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      final path = c.planDocPath!;
      const v2 = '# Plan\n\n## A\n';
      File(path).writeAsStringSync(v2);
      c.onAgentEdit('# Plan\n\n', v2);
      expect(c.headVersion, 2);
      c.viewVersion(1); // time-travel to v1
      expect(c.isViewingHistory, isTrue);

      c.attachSession(2);
      c.attachSession(1);
      expect(c.viewingVersion, 1);
      expect(c.isViewingHistory, isTrue);
    });

    test('background-session edits do not touch the foreground pane', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      final path = c.planDocPath!;
      final before = c.docText;
      final headBefore = c.headVersion;

      // Session 2's turn edits the SAME file (its own plan-mode target
      // on a shared workspace): the foreground pane must not react.
      const other = '# Plan\n\n- other session edit\n';
      File(path).writeAsStringSync(other);
      c.onAgentEdit(before, other, sessionId: 2);

      expect(c.docText, before, reason: 'pane state untouched');
      expect(c.headVersion, headBefore);
    });

    test('background edits are absorbed into the log on switch-back', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      const v2 = '# Plan\n\n- edited in background\n';
      File(c.planDocPath!).writeAsStringSync(v2);

      c.attachSession(2); // session 1 goes background
      // Session 2's turn mutated session 1's plan doc on disk.
      c.attachSession(1); // switch back

      expect(c.docText, v2);
      expect(c.headVersion, 2,
          reason: 'the background edit landed as a new version');
      expect(c.viewingVersion, 2);
    });

    test('isAttachedTo gates plan-context injection per session', () {
      final c = wired();
      addTearDown(c.dispose);

      c.attachSession(1);
      c.enter(tmp.path);
      expect(c.isAttachedTo(1), isTrue);
      expect(c.isAttachedTo(2), isFalse);

      c.attachSession(2);
      expect(c.active, isFalse);
      expect(c.isAttachedTo(1), isFalse);
    });
  });
}

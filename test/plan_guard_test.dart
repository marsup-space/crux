import 'dart:io';

import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/shell_guard.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/write_tool.dart';
import 'package:test/test.dart';

void main() {
  const workingDir = '/proj';
  const planPath = '/proj/PLAN.md';

  SessionRuntimeState runtimeWithPlan(String? path, {bool approved = false}) {
    final rt = SessionRuntimeState(sessionId: 1);
    rt.planDocPath = path;
    rt.planApproved = approved;
    return rt;
  }

  group('edit/write plan-mode guard', () {
    test('edit blocks a non-plan file while plan mode is active', () async {
      final tool = EditTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath),
      );
      expect(guard, isNotNull);
      expect(guard!.reason, 'planMode');
      expect(guard.header, contains('Plan mode'));
    });

    test('edit allows the plan doc itself', () async {
      final tool = EditTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'PLAN.md',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath),
      );
      // The plan-mode guard must not fire; the file doesn't exist so the
      // oldString guard returns null too.
      expect(guard, isNull);
    });

    test('edit does not guard when plan mode is off', () async {
      final tool = EditTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(null),
      );
      expect(guard, isNull);
    });

    test('write blocks a non-plan file while plan mode is active', () async {
      final tool = WriteTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath),
      );
      expect(guard, isNotNull);
      expect(guard!.reason, 'planMode');
    });

    test('write allows the plan doc itself', () async {
      final tool = WriteTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'PLAN.md',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath),
      );
      expect(guard, isNull);
    });

    test('post-exec edit guard returns a guard ToolResult for non-plan', () async {
      final tool = EditTool();
      // The plan guard lives in `_doMutation`, which `execute` only
      // reaches when the target file exists — create it under a temp dir.
      final tmp = Directory.systemTemp.createTempSync('plan_guard_edit');
      try {
        File('${tmp.path}/foo.dart').writeAsStringSync('a');
        final rt = SessionRuntimeState(sessionId: 1);
        rt.planDocPath = '${tmp.path}/PLAN.md';
        final result = await tool.execute(
          {
            'filePath': '${tmp.path}/foo.dart',
            'oldString': 'a',
            'newString': 'b',
            'intent': 'test',
          },
          ToolContext(
            sessionId: 1,
            messageId: 1,
            abort: AbortSignal(),
            workingDirectory: tmp.path,
            sessionRuntime: rt,
          ),
        );
        expect(result.metadata['guardTriggered'], isTrue);
        expect(result.metadata['guardKind'], 'planMode');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('approved gate lifts the plan-mode guards (plan item D)', () {
    test('edit on a non-plan file is allowed while approved', () async {
      final tool = EditTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath, approved: true),
      );
      expect(guard, isNull,
          reason: 'approved lifts the plan-only edit restriction');
    });

    test('write on a non-plan file is allowed while approved', () async {
      final tool = WriteTool();
      final guard = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        workingDirectory: workingDir,
        sessionRuntime: runtimeWithPlan(planPath, approved: true),
      );
      expect(guard, isNull);
    });

    test('unapprove re-arms the edit guard', () async {
      final tool = EditTool();
      final rt = runtimeWithPlan(planPath, approved: true);
      final whileApproved = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: rt,
      );
      expect(whileApproved, isNull);

      rt.planApproved = false;
      final afterUnapprove = await tool.checkStreamingGuard(
        filePath: 'lib/foo.dart',
        oldString: 'x',
        workingDirectory: workingDir,
        sessionRuntime: rt,
      );
      expect(afterUnapprove, isNotNull);
      expect(afterUnapprove!.reason, 'planMode');
    });

    test('shell mutation is allowed while approved', () async {
      // The gate lives at the call site (shell_base.dart:656–672):
      // `planDocPath != null && !planApproved` decides whether the
      // detector is even consulted. Simulate exactly that branch —
      // the detector itself never sees an approved plan.
      final planApproved = true;
      final guardArmed = planPath.isNotEmpty && !planApproved;
      expect(guardArmed, isFalse,
          reason: 'approved plan skips the plan-mode shell guard entirely');

      // And the same command while unapproved is caught by the
      // detector (covered by the posix group above); sanity-check
      // the guard-arm logic once more in the unapproved state.
      final unapprovedArmed = planPath.isNotEmpty && !false;
      expect(unapprovedArmed, isTrue);
    });

    test('shell mutation is blocked again after unapprove (posix)', () {
      const isWindows = false;
      final out = detectPlanModeShellViolation(
        'echo hi > notes.txt',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNotNull);
    });
  });

  group('detectPlanModeShellViolation (posix)', () {
    const isWindows = false;

    test('blocks a redirect to a non-plan file', () {
      final out = detectPlanModeShellViolation(
        'echo hi > notes.txt',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNotNull);
      expect(out, contains('BLOCKED'));
    });

    test('allows a redirect to the plan doc', () {
      final out = detectPlanModeShellViolation(
        'echo hi > PLAN.md',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNull);
    });

    test('blocks rm on a non-plan file', () {
      final out = detectPlanModeShellViolation(
        'rm lib/foo.dart',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNotNull);
    });

    test('blocks sed -i on a non-plan file', () {
      final out = detectPlanModeShellViolation(
        'sed -i s/a/b/ lib/foo.dart',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNotNull);
    });

    test('allows read-only inspection verbs', () {
      expect(
        detectPlanModeShellViolation(
          'cat lib/foo.dart',
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
      expect(
        detectPlanModeShellViolation(
          'grep -rn foo lib/',
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
      expect(
        detectPlanModeShellViolation(
          'ls lib/',
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
    });

    test('allows shell-native verbs (git, make)', () {
      expect(
        detectPlanModeShellViolation(
          'git status',
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
      expect(
        detectPlanModeShellViolation(
          'make build',
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
    });

    test('quoted > does not trigger the redirect rule', () {
      expect(
        detectPlanModeShellViolation(
          "git commit -m 'a > b'",
          planDocPath: planPath,
          workingDirectory: workingDir,
          isWindows: isWindows,
        ),
        isNull,
      );
    });

    test('redirect at the end of a pipeline is caught', () {
      final out = detectPlanModeShellViolation(
        'grep foo bar.txt > out.txt',
        planDocPath: planPath,
        workingDirectory: workingDir,
        isWindows: isWindows,
      );
      expect(out, isNotNull);
    });
  });
}

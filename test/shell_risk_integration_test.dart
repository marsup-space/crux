// Integration tests for the shell high-risk guardrail wiring in
// lib/src/tools/shell_base.dart — layer 1 heuristic pre-screen plus
// the layer 2 auxiliary-model evaluator injected via
// ToolContext.shellRiskEvaluator.
//
// These tests run a REAL BashTool against a real shell (POSIX only;
// the whole file is skipped on Windows). The ToolContext is
// hand-built (same pattern as webfetch_tool_test.dart) with a fake
// evaluator closure, so no auxiliary model or network access is
// involved.
//
// The suspicious test command is `killall <nonexistent-name>`: the
// heuristic flags `killall` unconditionally ("kills processes by
// name — easy to over-match"), while executing it against a process
// name that cannot exist is a guaranteed no-op that merely exits
// non-zero. Repeatable, no side effects, no network, no privilege
// prompts (sudo would be interactive and is avoided on purpose).

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/tools/bash_tool.dart';
import 'package:crux/src/tools/shell_risk.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  const suspiciousCommand = 'killall crux-no-such-process-ever';
  const heuristicReason = 'kills processes by name';

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_shellrisk_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ToolContext ctx({
    Future<ShellRiskVerdict> Function(
      String command, {
      required String intent,
      required bool isWindows,
      required AbortSignal abort,
    })?
    evaluator,
  }) => ToolContext(
    sessionId: 1,
    messageId: 1,
    abort: AbortSignal(),
    workingDirectory: tempDir.path,
    shellRiskEvaluator: evaluator,
  );

  Map<String, dynamic> callArgs(String command, {bool confirmed = false}) => {
    'command': command,
    'intent': 'integration test',
    if (confirmed) 'confirmed': true,
  };

  group('shell risk guardrail — safe tier', () {
    test('safe command runs with zero guardrail overhead', () async {
      final tool = BashTool();
      var evaluatorCalls = 0;
      final result = await tool.execute(
        callArgs('echo hello'),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                evaluatorCalls++;
                return const ShellRiskVerdict(ShellRiskVerdictKind.safe);
              },
        ),
      );

      expect(result.title, isNot('Error'));
      expect(result.output, contains('hello'));
      expect(result.metadata['exitCode'], 0);
      // No guardrail metadata, no output noise, evaluator untouched.
      expect(result.metadata.containsKey('shellRisk'), isFalse);
      expect(result.output, isNot(contains('shell-risk')));
      expect(evaluatorCalls, 0);
    }, skip: Platform.isWindows);
  });

  group('shell risk guardrail — catastrophic tier', () {
    test('rm -rf / is hard-blocked and never executes', () async {
      final tool = BashTool();
      var evaluatorCalls = 0;
      final result = await tool.execute(
        callArgs('rm -rf /'),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                evaluatorCalls++;
                return const ShellRiskVerdict(ShellRiskVerdictKind.safe);
              },
        ),
      );

      expect(result.title, 'Error');
      expect(result.metadata['shellRisk'], 'blocked-catastrophic');
      expect(result.metadata['shellRiskReason'], isNotNull);
      expect(result.output, contains('BLOCKED'));
      expect(result.output, contains('not negotiable'));
      expect(result.output, contains('manually in their own terminal'));
      // The command never reached the shell: no exit code, no rm
      // output, and the aux model is never consulted for this tier.
      expect(result.metadata.containsKey('exitCode'), isFalse);
      expect(evaluatorCalls, 0);
    }, skip: Platform.isWindows);

    test(
      'confirmed: true does NOT bypass a catastrophic block',
      () async {
        final tool = BashTool();
        final result = await tool.execute(
          callArgs('rm -rf /', confirmed: true),
          ctx(),
        );

        expect(result.title, 'Error');
        expect(result.metadata['shellRisk'], 'blocked-catastrophic');
        expect(result.metadata.containsKey('exitCode'), isFalse);
      },
      skip: Platform.isWindows,
    );
  });

  group('shell risk guardrail — suspicious tier', () {
    test('evaluator UNSAFE blocks the command', () async {
      final tool = BashTool();
      final result = await tool.execute(
        callArgs(suspiciousCommand),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                return const ShellRiskVerdict(
                  ShellRiskVerdictKind.unsafe,
                  'kills processes the user may still need',
                );
              },
        ),
      );

      expect(result.title, 'Error');
      expect(result.metadata['shellRisk'], 'blocked-unsafe');
      expect(
        result.metadata['shellRiskReason'],
        'kills processes the user may still need',
      );
      // The rejection teaches the model both verdicts and the appeal
      // path (user approval → confirmed: true resend).
      expect(result.output, contains(heuristicReason));
      expect(result.output, contains('UNSAFE'));
      expect(result.output, contains('confirmed: true'));
      expect(result.metadata.containsKey('exitCode'), isFalse);
    }, skip: Platform.isWindows);

    test('evaluator UNCERTAIN also blocks (fail-closed)', () async {
      final tool = BashTool();
      final result = await tool.execute(
        callArgs(suspiciousCommand),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                return const ShellRiskVerdict(ShellRiskVerdictKind.uncertain);
              },
        ),
      );

      expect(result.title, 'Error');
      expect(result.metadata['shellRisk'], 'blocked-uncertain');
      expect(result.output, contains('UNCERTAIN'));
      expect(result.metadata.containsKey('exitCode'), isFalse);
    }, skip: Platform.isWindows);

    test('evaluator SAFE lets the command run quietly', () async {
      final tool = BashTool();
      final result = await tool.execute(
        callArgs(suspiciousCommand),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                return const ShellRiskVerdict(ShellRiskVerdictKind.safe);
              },
        ),
      );

      expect(result.title, isNot('Error'));
      expect(result.metadata['shellRisk'], 'evaluated-safe');
      // killall actually ran (no such process → non-zero exit).
      expect(result.metadata['exitCode'], isNot(0));
      // Clean bill of health: no warning noise in the output.
      expect(result.output, isNot(contains('shell-risk')));
    }, skip: Platform.isWindows);

    test('no evaluator (null) fails open with a warning', () async {
      final tool = BashTool();
      final result = await tool.execute(
        callArgs(suspiciousCommand),
        ctx(), // no shellRiskEvaluator injected
      );

      expect(result.title, isNot('Error'));
      expect(result.metadata['shellRisk'], 'fail-open');
      expect(result.metadata['exitCode'], isNot(0));
      expect(result.output, contains('[shell-risk: fail-open]'));
      expect(result.output, contains(heuristicReason));
    }, skip: Platform.isWindows);

    test('evaluator UNAVAILABLE fails open with a warning', () async {
      final tool = BashTool();
      final result = await tool.execute(
        callArgs(suspiciousCommand),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                return const ShellRiskVerdict(ShellRiskVerdictKind.unavailable);
              },
        ),
      );

      expect(result.title, isNot('Error'));
      expect(result.metadata['shellRisk'], 'fail-open');
      expect(result.output, contains('[shell-risk: fail-open]'));
      expect(result.output, contains('unavailable'));
    }, skip: Platform.isWindows);

    test('confirmed: true bypasses the evaluator entirely', () async {
      final tool = BashTool();
      var evaluatorCalls = 0;
      final result = await tool.execute(
        callArgs(suspiciousCommand, confirmed: true),
        ctx(
          evaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                evaluatorCalls++;
                return const ShellRiskVerdict(ShellRiskVerdictKind.unsafe);
              },
        ),
      );

      expect(result.title, isNot('Error'));
      expect(result.metadata['shellRisk'], 'confirmed-bypass');
      expect(result.metadata['exitCode'], isNot(0));
      expect(result.output, contains('[shell-risk: confirmed bypass]'));
      // The evaluator must NOT be consulted on a confirmed bypass —
      // even though it would have said UNSAFE here.
      expect(evaluatorCalls, 0);
    }, skip: Platform.isWindows);

    test(
      'a throwing evaluator is treated as unavailable (fail-open)',
      () async {
        final tool = BashTool();
        final result = await tool.execute(
          callArgs(suspiciousCommand),
          ctx(
            evaluator:
                (
                  command, {
                  required intent,
                  required isWindows,
                  required abort,
                }) async {
                  throw StateError('aux transport exploded');
                },
          ),
        );

        expect(result.title, isNot('Error'));
        expect(result.metadata['shellRisk'], 'fail-open');
        expect(result.output, contains('[shell-risk: fail-open]'));
      },
      skip: Platform.isWindows,
    );
  });

  group('shell risk guardrail — abort during evaluation', () {
    test(
      'abort while the evaluator is stuck prevents execution',
      () async {
        final tool = BashTool();
        final abort = AbortSignal();
        final evaluatorStarted = Completer<void>();
        final context = ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: abort,
          workingDirectory: tempDir.path,
          shellRiskEvaluator:
              (
                command, {
                required intent,
                required isWindows,
                required abort,
              }) async {
                evaluatorStarted.complete();
                // Mirror the production _assessShellRiskWithAbort race: a
                // stuck aux model must not hang the tool — it returns
                // (unavailable → fail-open) once the abort signal fires.
                // Without shell_base's post-evaluation abort gate, that
                // fail-open verdict would let the command execute AFTER
                // the user interrupted.
                while (!abort.isAborted) {
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                }
                return const ShellRiskVerdict(ShellRiskVerdictKind.unavailable);
              },
        );

        final resultFuture = tool.execute(callArgs(suspiciousCommand), context);
        // Wait until the evaluator is actually running, then interrupt.
        await evaluatorStarted.future;
        abort.abort();

        final result = await resultFuture.timeout(const Duration(seconds: 10));
        expect(result.title, 'Error');
        expect(result.output, contains('Aborted before execution'));
        // The command never ran: no exit code, none of killall's output.
        expect(result.metadata.containsKey('exitCode'), isFalse);
        expect(result.output, isNot(contains('No matching processes')));
      },
      skip: Platform.isWindows,
    );
  });
}

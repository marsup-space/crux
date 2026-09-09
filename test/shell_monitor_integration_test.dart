// Integration tests for the shell progress monitor wiring in
// lib/src/tools/shell_base.dart — the aux-model supervision regime
// that replaces the static timeout when an auxiliary model is
// configured.
//
// These tests run a REAL BashTool against a real shell (POSIX only;
// the whole file is skipped on Windows). The ToolContext is
// hand-built with a fake ShellMonitorEvaluator closure, so no
// auxiliary model or network access is involved. The fake evaluator
// inspects the continuing conversation it is handed and returns
// scripted verdicts, letting us assert:
//
//   * a STUCK verdict kills a long-running process well before any
//     classic timeout would have fired;
//   * with no monitor evaluator, the classic static timeout still
//     fires (the no-aux regime is unchanged);
//   * the monitor conversation has the right shape: a leading system
//     prompt, a first user turn carrying the static metadata block
//     (command / intent / platform), and per-turn dynamic blocks.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/tools/bash_tool.dart';
import 'package:crux/src/tools/shell_monitor.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_shellmon_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ToolContext ctx({ShellMonitorEvaluator? monitor}) => ToolContext(
    sessionId: 1,
    messageId: 1,
    abort: AbortSignal(),
    workingDirectory: tempDir.path,
    shellMonitorEvaluator: monitor,
  );

  Map<String, dynamic> callArgs(String command, {int? timeout}) => {
    'command': command,
    'intent': 'integration test',
    'timeout': ?timeout,
  };

  group('shell progress monitor — STUCK kills the process', () {
    test('a STUCK verdict kills a long-running command early', () async {
      final tool = BashTool();
      var evaluatorCalls = 0;
      final sw = Stopwatch()..start();

      final result = await tool.execute(
        // `sleep 60` would blow far past any test budget if the
        // monitor failed to kill it. The fake evaluator returns STUCK
        // on its first call, so the process dies at the first check.
        callArgs('sleep 60'),
        ctx(
          monitor: (messages, {required abort}) async {
            evaluatorCalls++;
            return const ShellMonitorVerdict(
              ShellMonitorVerdictKind.stuck,
              reason: 'test-forced stuck verdict',
            );
          },
        ),
      );

      sw.stop();
      expect(evaluatorCalls, greaterThan(0));
      // Killed well before 60s — the first check fires at
      // kMonitorFirstCheckSeconds (20s), so allow generous headroom.
      expect(sw.elapsed.inSeconds, lessThan(40));
      expect(result.output, contains('killed by progress monitor'));
      expect(result.output, contains('test-forced stuck verdict'));
    }, skip: Platform.isWindows);

    test('the monitor conversation has the expected shape', () async {
      final tool = BashTool();
      final captured = <List<Map<String, dynamic>>>[];

      await tool.execute(
        callArgs('sleep 60'),
        ctx(
          monitor: (messages, {required abort}) async {
            // Snapshot the conversation as seen at this check.
            captured.add([
              for (final m in messages) Map<String, dynamic>.from(m),
            ]);
            return const ShellMonitorVerdict(
              ShellMonitorVerdictKind.stuck,
              reason: 'shape probe',
            );
          },
        ),
      );

      expect(captured, isNotEmpty);
      final firstTurn = captured.first;
      // Leading system prompt.
      expect(firstTurn.first['role'], 'system');
      expect(
        (firstTurn.first['content'] as String).toLowerCase(),
        contains('progress'),
      );
      // First user turn carries the static metadata block.
      final firstUser = firstTurn.firstWhere((m) => m['role'] == 'user');
      final firstContent = firstUser['content'] as String;
      expect(firstContent, contains('Command: sleep 60'));
      expect(firstContent, contains('Platform:'));
      expect(firstContent, contains('shell:'));
      expect(firstContent, contains('[check #1]'));
      expect(firstContent, contains('elapsed:'));
    }, skip: Platform.isWindows);
  });

  group('shell progress monitor — no-aux regime unchanged', () {
    test('classic timeout still fires without a monitor evaluator', () async {
      final tool = BashTool();
      final sw = Stopwatch()..start();

      final result = await tool.execute(
        callArgs('sleep 60', timeout: 1500),
        ctx(), // no shellMonitorEvaluator → classic timeout regime
      );

      sw.stop();
      expect(sw.elapsed.inSeconds, lessThan(20));
      expect(result.output, contains('timed out'));
    }, skip: Platform.isWindows);

    test('a PROGRESS verdict lets the command run to completion', () async {
      final tool = BashTool();
      var evaluatorCalls = 0;

      final result = await tool.execute(
        // A short command that finishes before the first check: the
        // monitor never fires and the exit is clean.
        callArgs('echo monitor-should-not-fire'),
        ctx(
          monitor: (messages, {required abort}) async {
            evaluatorCalls++;
            return const ShellMonitorVerdict(
              ShellMonitorVerdictKind.progress,
              intervalSeconds: 5,
            );
          },
        ),
      );

      expect(result.metadata['exitCode'], 0);
      expect(result.output, contains('monitor-should-not-fire'));
      // The command finished before kMonitorFirstCheckSeconds, so the
      // monitor never evaluated.
      expect(evaluatorCalls, 0);
    }, skip: Platform.isWindows);
  });
}

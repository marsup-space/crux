// Tests for the zero-progress escalation ("option B"): a process
// that keeps answering PROGRESS/UNCERTAIN while the process is fully
// silent (0B new output, byte-identical tail) gets a WARNING in its
// user turns, forced short re-checks, and — after
// kMonitorStallKillChecks stalled checks — an override-to-STUCK kill
// logged as STUCK with the escalation reason.
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/tools/bash_tool.dart';
import 'package:crux/src/tools/shell_monitor.dart';
import 'package:crux/src/tools/tool_def.dart';

/// Tighten the escalation thresholds so the end-to-end tests finish
/// in seconds (first check 20s + warn@2, kill@3, forced 2s re-checks
/// ≈ T+28s). Restored in [tearDown] so later tests / suites see the
/// production defaults.
void _tightenThresholds() {
  kMonitorStallWarnChecks = 2;
  kMonitorStallKillChecks = 3;
  kMonitorStallCheckIntervalSeconds = 2;
}

void _restoreThresholds() {
  kMonitorStallWarnChecks = 3;
  kMonitorStallKillChecks = 8;
  kMonitorStallCheckIntervalSeconds = 20;
}

void main() {
  group('stallEscalationFor (pure thresholds)', () {
    test('no escalation before the warn threshold', () {
      expect(stallEscalationFor(0), StallEscalation.none);
      expect(stallEscalationFor(1), StallEscalation.none);
      expect(
        stallEscalationFor(kMonitorStallWarnChecks - 1),
        StallEscalation.none,
      );
    });

    test('warn from the warn threshold', () {
      expect(stallEscalationFor(kMonitorStallWarnChecks), StallEscalation.warn);
      expect(
        stallEscalationFor(kMonitorStallKillChecks - 1),
        StallEscalation.warn,
      );
    });

    test('escalate at the kill threshold and beyond', () {
      expect(
        stallEscalationFor(kMonitorStallKillChecks),
        StallEscalation.escalate,
      );
      expect(
        stallEscalationFor(kMonitorStallKillChecks + 50),
        StallEscalation.escalate,
      );
    });
  });

  group('stallNoticeFor', () {
    test('names the consecutive-stall count', () {
      final notice = stallNoticeFor(3);
      expect(notice, startsWith('WARNING:'));
      expect(notice, contains('3 consecutive checks'));
      expect(notice, contains('0B new output'));
      expect(notice, contains('STUCK'));
    });
  });

  group('buildShellMonitorUserMessage with stallNotice', () {
    test('warning sits inside the check block, before the metadata', () {
      final msg = buildShellMonitorUserMessage(
        snapshot: ShellMonitorSnapshot(
          checkNumber: 4,
          elapsed: const Duration(seconds: 120),
          sincePreviousCheck: const Duration(seconds: 20),
          newOutputBytes: 0,
          totalOutputBytes: 500,
          outputTail: 'same',
        ),
        stallNotice: stallNoticeFor(3),
      );
      final lines = msg.split('\n');
      final checkIdx = lines.indexOf('[check #4]');
      final warnIdx = lines.indexWhere((l) => l.startsWith('WARNING:'));
      final elapsedIdx = lines.indexWhere((l) => l.startsWith('elapsed:'));
      expect(checkIdx, isNot(-1));
      expect(warnIdx, greaterThan(checkIdx));
      expect(elapsedIdx, greaterThan(warnIdx));
    });

    test('no warning line when stallNotice is null', () {
      final msg = buildShellMonitorUserMessage(
        snapshot: ShellMonitorSnapshot(
          checkNumber: 2,
          elapsed: const Duration(seconds: 40),
          sincePreviousCheck: const Duration(seconds: 20),
          newOutputBytes: 0,
          totalOutputBytes: 10,
          outputTail: '',
        ),
      );
      expect(msg.contains('WARNING:'), isFalse);
    });
  });

  group('end-to-end zero-progress kill', () {
    late Directory tempDir;

    setUp(() async {
      _tightenThresholds();
      tempDir = await Directory.systemTemp.createTemp('crux_stall_');
    });

    tearDown(() async {
      _restoreThresholds();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ToolContext ctx({
      ShellMonitorEvaluator? monitor,
      void Function(ShellMonitorNotice notice)? onNotice,
    }) => ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempDir.path,
      shellMonitorEvaluator: monitor,
      shellMonitorNoticeSink: onNotice,
    );

    test(
      'a forever-silent process with a PROGRESS-only model is killed '
      'by the escalation override',
      () async {
        // Use the intentionally mutable test knobs rather than production
        // timings (20 seconds × 8 checks). Otherwise this one assertion can
        // exceed its own four-minute timeout before it reaches escalation.
        final oldWarnChecks = kMonitorStallWarnChecks;
        final oldKillChecks = kMonitorStallKillChecks;
        final oldInterval = kMonitorStallCheckIntervalSeconds;
        kMonitorStallWarnChecks = 2;
        kMonitorStallKillChecks = 3;
        kMonitorStallCheckIntervalSeconds = 1;
        try {
          final tool = BashTool();
          final kinds = <String>[];
          final warnedUserTurns = <String>[];

          final result = await tool.execute(
            // Prints one line, then goes silent forever. Without the
            // escalation this would run for kMonitorFirstCheckSeconds ×
            // ∞ (the model always says PROGRESS) and blow the test
            // budget.
            {'command': 'echo starting; sleep 600', 'intent': 'stall test'},
            ctx(
              monitor: (messages, {required abort}) async {
                // Snapshot every user turn to count WARNINGs.
                for (final m in messages) {
                  if (m['role'] == 'user') {
                    final c = m['content'] as String;
                    if (c.contains('WARNING:') &&
                        !warnedUserTurns.contains(c)) {
                      warnedUserTurns.add(c);
                    }
                  }
                }
                // The model never judges STUCK — the loop must.
                return const ShellMonitorVerdict(
                  ShellMonitorVerdictKind.progress,
                  intervalSeconds: 1,
                );
              },
              onNotice: (n) => kinds.add(n.kind),
            ),
          );

          // Killed by the escalation override — reported as a monitor
          // kill with the escalation reason.
          expect(result.output, contains('killed by progress monitor'));
          expect(result.output, contains('zero-progress escalation'));
          // The model was warned before the override fired.
          expect(
            warnedUserTurns.length,
            inInclusiveRange(1, kMonitorStallKillChecks),
          );
          // The audit trail shows the pre-kill checks as PROGRESS and
          // the override as STUCK (in one continuous run).
          expect(kinds.first, 'CONFIGURED');
          expect(kinds, contains('STUCK'));
        } finally {
          kMonitorStallWarnChecks = oldWarnChecks;
          kMonitorStallKillChecks = oldKillChecks;
          kMonitorStallCheckIntervalSeconds = oldInterval;
        }
      },
      skip: Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'a process with fresh output every check is NEVER escalated',
      () async {
        final tool = BashTool();
        final kinds = <String>[];
        var checks = 0;

        final result = await tool.execute(
          {
            // Ticks every second for 40s — long enough to pass the 20s
            // first check and take several more, each with fresh bytes.
            'command':
                'for i in \$(seq 1 40); do echo "tick \$i"; sleep 1; done',
            'intent': 'healthy quiet-phase test',
          },
          ctx(
            monitor: (messages, {required abort}) async {
              checks++;
              return const ShellMonitorVerdict(
                ShellMonitorVerdictKind.progress,
                intervalSeconds: 4,
              );
            },
            onNotice: (n) => kinds.add(n.kind),
          ),
        );

        expect(result.output, contains('tick 40'));
        // Successful run: no escalation, no kill annotation, exit line
        // absent (exit 0 is not appended by the tool).
        expect(result.metadata['exitCode'], 0);
        // Several checks happened; no STUCK, no escalation.
        expect(checks, greaterThanOrEqualTo(2));
        expect(kinds, isNot(contains('STUCK')));
        expect(result.output, isNot(contains('zero-progress escalation')));
      },
      skip: Platform.isWindows,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

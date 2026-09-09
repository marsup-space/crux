// Nightly-term tests for the shell-monitor toast channel: the
// monitor loop in `shell_base.dart` must fire the notice sink at arm
// time and after every aux evaluation, with the right kind / payload,
// and the process must still be killed on the scripted STUCK verdict
// (the toast channel is a pure side channel — it never changes kill
// semantics).
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/tools/bash_tool.dart';
import 'package:crux/src/tools/shell_monitor.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_monnotice_');
  });

  tearDown(() async {
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

  Map<String, dynamic> callArgs(String command) => {
    'command': command,
    'intent': 'notice test',
  };

  test(
    'monitor loop fires CONFIGURED + STUCK notices and still kills',
    () async {
      final tool = BashTool();
      final kinds = <String>[];
      ShellMonitorNotice? lastNotice;

      final result = await tool.execute(
        callArgs('sleep 60'),
        ctx(
          monitor: (messages, {required abort}) async =>
              const ShellMonitorVerdict(
                ShellMonitorVerdictKind.stuck,
                reason: 'notice-test stuck',
              ),
          onNotice: (n) {
            kinds.add(n.kind);
            lastNotice = n;
          },
        ),
      );

      // Arm-time announcement then the STUCK verdict.
      expect(kinds, ['CONFIGURED', 'STUCK']);
      // The STUCK notice carries what the toast needs: intent as the
      // primary subject, reason as evidence.
      expect(lastNotice!.configured, isTrue);
      expect(lastNotice!.intent, 'notice test');
      expect(lastNotice!.command, contains('sleep 60'));
      expect(lastNotice!.reason, 'notice-test stuck');
      // Toast channel is a side channel: the kill semantics are
      // unchanged.
      expect(result.output, contains('killed by progress monitor'));
    },
    skip: Platform.isWindows,
  );

  test(
    'a quick command only announces (never reaches the first check)',
    () async {
      final tool = BashTool();
      final kinds = <String>[];

      await tool.execute(
        callArgs('echo hi'),
        ctx(
          monitor: (messages, {required abort}) async {
            fail('aux model must not be consulted for quick commands');
          },
          onNotice: (n) => kinds.add(n.kind),
        ),
      );

      expect(kinds, ['CONFIGURED']);
    },
    skip: Platform.isWindows,
  );

  test('no monitor + unconfigured notice = noise-gated away', () async {
    final tool = BashTool();
    final notices = <ShellMonitorNotice>[];

    await tool.execute(callArgs('echo hi'), ctx(onNotice: notices.add));

    // The run-start notice is emitted but flagged unconfigured — the
    // chat panel's isMeaningful gate drops it (no toast for a plain
    // fast command).
    expect(notices, hasLength(1));
    expect(notices.single.configured, isFalse);
    expect(notices.single.isMeaningful, isFalse);
  });
}

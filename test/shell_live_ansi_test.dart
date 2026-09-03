import 'package:crux/src/services/shell_live_registry.dart';
import 'package:test/test.dart';

void main() {
  test('appendOutput strips ANSI escapes from chunks', () {
    final reg = ShellLiveRegistry(finishedTtl: const Duration(seconds: 5));
    reg.register(sessionId: 1, callId: 'c1', command: 'ls', intent: '');
    reg.appendOutput(1, 'c1', '\x1B[32mgreen text\x1B[0m plain ');
    reg.appendOutput(1, 'c1', '\x1B]0;window title\x07tail');
    reg.appendOutput(1, 'c1', '\x1B[1;34mblue\x1B[m');
    final entry = reg.entryFor(1, 'c1')!;
    // Reset sequences strip; the words between them stay.
    expect(entry.outputTail, 'green text plain tailblue');
    expect(entry.outputTail.contains('\x1B'), isFalse);
  });

  test('ansi strip does not eat plain text with brackets', () {
    final reg = ShellLiveRegistry(finishedTtl: const Duration(seconds: 5));
    reg.register(sessionId: 1, callId: 'c2', command: 'ls', intent: '');
    reg.appendOutput(1, 'c2', 'array[0] = 1; done [OK]');
    final entry = reg.entryFor(1, 'c2')!;
    expect(entry.outputTail, 'array[0] = 1; done [OK]');
  });
}

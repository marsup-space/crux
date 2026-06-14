import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';

/// A test component that implements the Ctrl+C double-press-to-quit guard,
/// matching the same logic used in ChatInput.
class _CtrlCGuardDemo extends StatefulComponent {
  final bool isStreaming;
  final void Function(String message) onToast;

  const _CtrlCGuardDemo({
    required this.isStreaming,
    required this.onToast,
  });

  @override
  State<_CtrlCGuardDemo> createState() => _CtrlCGuardDemoState();
}

class _CtrlCGuardDemoState extends State<_CtrlCGuardDemo> {
  DateTime? _lastCtrlCPressTime;
  bool _ctrlCQuitHint = false;
  String _status = 'idle';
  final _controller = TextEditingController();

  bool _handleKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.keyC && event.isControlPressed &&
        !event.isShiftPressed && !event.isAltPressed && !event.isMetaPressed) {
      if (component.isStreaming) {
        final now = DateTime.now();
        if (_lastCtrlCPressTime != null &&
            now.difference(_lastCtrlCPressTime!).inMilliseconds < 3000 &&
            _ctrlCQuitHint) {
          // Second press within 3s — let it through
          _lastCtrlCPressTime = null;
          _ctrlCQuitHint = false;
          _status = 'quit';
          setState(() {});
          return false;
        } else {
          // First press — show warning, don't quit
          _lastCtrlCPressTime = now;
          _ctrlCQuitHint = true;
          _status = 'warned';
          component.onToast('Agent is running. Press Ctrl+C again to quit.');
          setState(() {});
          return true; // consume
        }
      }
      // Not streaming — let Ctrl+C through
      _status = 'quit';
      setState(() {});
      return false;
    }

    // Any other key resets the Ctrl+C quit hint
    if (_ctrlCQuitHint) {
      _ctrlCQuitHint = false;
      _lastCtrlCPressTime = null;
      setState(() {});
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    return Container(
      width: 60,
      height: 10,
      child: Column(
        children: [
          Text('Status: $_status'),
          Text('Streaming: ${component.isStreaming}'),
          Text('QuitHint: $_ctrlCQuitHint'),
          TextField(
            controller: _controller,
            focused: true,
            onKeyEvent: _handleKeyEvent,
          ),
        ],
      ),
    );
  }
}

void main() {
  group('Ctrl+C double-press-to-quit guard', () {
    test('Ctrl+C when not streaming passes through (returns false)', () async {
      String? toastMessage;
      await testNocterm('ctrl_c_not_streaming', (tester) async {
        await tester.pumpComponent(_CtrlCGuardDemo(
          isStreaming: false,
          onToast: (msg) => toastMessage = msg,
        ));

        // Send Ctrl+C
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        // Status should be 'quit' (event was not consumed)
        expect(tester.terminalState, containsText('quit'));
        // No toast should have been shown
        expect(toastMessage, isNull);
      });
    });

    test('First Ctrl+C when streaming shows warning (consumes event)', () async {
      String? toastMessage;
      await testNocterm('ctrl_c_first_press', (tester) async {
        await tester.pumpComponent(_CtrlCGuardDemo(
          isStreaming: true,
          onToast: (msg) => toastMessage = msg,
        ));

        // Send first Ctrl+C
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        // Status should be 'warned' (event was consumed, toast shown)
        expect(tester.terminalState, containsText('warned'));
        expect(tester.terminalState, containsText('QuitHint: true'));
        expect(toastMessage, equals('Agent is running. Press Ctrl+C again to quit.'));
      });
    });

    test('Second Ctrl+C while hint active passes through (returns false)', () async {
      var toastCount = 0;
      await testNocterm('ctrl_c_second_press', (tester) async {
        await tester.pumpComponent(_CtrlCGuardDemo(
          isStreaming: true,
          onToast: (msg) => toastCount++,
        ));

        // Send first Ctrl+C
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        expect(tester.terminalState, containsText('warned'));

        // Send second Ctrl+C quickly (within 3s)
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        // Status should be 'quit' (second press lets it through)
        expect(tester.terminalState, containsText('quit'));
        expect(tester.terminalState, containsText('QuitHint: false'));
        // Only one toast should have been shown (on the first press)
        expect(toastCount, equals(1));
      });
    });

    test('Other key press after first Ctrl+C resets the hint', () async {
      String? toastMessage;
      await testNocterm('ctrl_c_reset_by_other_key', (tester) async {
        await tester.pumpComponent(_CtrlCGuardDemo(
          isStreaming: true,
          onToast: (msg) => toastMessage = msg,
        ));

        // Send first Ctrl+C
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        expect(tester.terminalState, containsText('QuitHint: true'));

        // Press another key (e.g. 'a')
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyA,
          character: 'a',
        ));

        // QuitHint should be reset
        expect(tester.terminalState, containsText('QuitHint: false'));

        // Now Ctrl+C should be treated as a fresh first press
        toastMessage = null;
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ));

        // Should show warning again, not quit
        expect(tester.terminalState, containsText('warned'));
        expect(toastMessage, equals('Agent is running. Press Ctrl+C again to quit.'));
      });
    });

    test('Ctrl+Shift+C is not caught by the guard', () async {
      String? toastMessage;
      await testNocterm('ctrl_shift_c_not_caught', (tester) async {
        await tester.pumpComponent(_CtrlCGuardDemo(
          isStreaming: true,
          onToast: (msg) => toastMessage = msg,
        ));

        // Send Ctrl+Shift+C (should NOT be caught by the guard)
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true, shift: true),
        ));

        // Status should still be 'idle' (the guard didn't activate)
        expect(tester.terminalState, containsText('idle'));
        expect(toastMessage, isNull);
      });
    });
  });
}

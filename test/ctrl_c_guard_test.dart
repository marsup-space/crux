import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';

/// A test component that implements the Ctrl+C semantics, matching the
/// same logic used in ChatInput:
///
/// 1. Ctrl+C never cancels a streaming response — interrupting is
///    ESC×2's job. While any session is running (including the
///    currently streaming one), the first Ctrl+C arms the quit guard
///    with a warning toast, and a quick second Ctrl+C quits.
/// 2. When nothing is running, Ctrl+C quits immediately.
///
/// `runningSessionIds` mirrors `SessionController.hasAnyRunningSession`
/// in production: the guard fires whenever ANY session — current or
/// background — is running.
class _CtrlCGuardDemo extends StatefulComponent {
  final Set<int> runningSessionIds;
  final int? currentSessionId;
  final void Function(String message) onToast;

  const _CtrlCGuardDemo({
    required this.runningSessionIds,
    required this.currentSessionId,
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
    if (event.logicalKey == LogicalKey.keyC &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed &&
        !event.isMetaPressed) {
      final now = DateTime.now();

      // Quick double-press (within 3s, hint armed) quits.
      if (_lastCtrlCPressTime != null &&
          now.difference(_lastCtrlCPressTime!).inMilliseconds < 3000 &&
          _ctrlCQuitHint) {
        _lastCtrlCPressTime = null;
        _ctrlCQuitHint = false;
        _status = 'quit';
        setState(() {});
        return false;
      }

      // Any session running — arm the double-press quit guard. A
      // streaming response keeps streaming; Ctrl+C never cancels it.
      if (component.runningSessionIds.isNotEmpty) {
        _lastCtrlCPressTime = now;
        _ctrlCQuitHint = true;
        _status = 'warned';
        component.onToast('A session is running. Press Ctrl+C again to quit.');
        setState(() {});
        return true; // consume
      }

      // Nothing running — let Ctrl+C through
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
    final currentId = component.currentSessionId;
    final isCurrentRunning =
        currentId != null && component.runningSessionIds.contains(currentId);
    final anyRunning = component.runningSessionIds.isNotEmpty;
    return Container(
      width: 60,
      height: 12,
      child: Column(
        children: [
          Text('Status: $_status'),
          Text('Streaming: $isCurrentRunning'),
          Text('AnyRunning: $anyRunning'),
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
  group('Ctrl+C quit-only / double-press-to-quit semantics', () {
    test(
      'Ctrl+C when no session is running passes through (returns false)',
      () async {
        String? toastMessage;
        await testNocterm('ctrl_c_not_running', (tester) async {
          await tester.pumpComponent(
            _CtrlCGuardDemo(
              runningSessionIds: const {},
              currentSessionId: 1,
              onToast: (msg) => toastMessage = msg,
            ),
          );

          // Send Ctrl+C
          await tester.sendKeyEvent(
            KeyboardEvent(
              logicalKey: LogicalKey.keyC,
              modifiers: const ModifierKeys(ctrl: true),
            ),
          );

          // Status should be 'quit' (event was not consumed)
          expect(tester.terminalState, containsText('quit'));
          // No toast should have been shown
          expect(toastMessage, isNull);
        });
      },
    );

    test('First Ctrl+C while current session is streaming arms the quit '
        'guard without interrupting (consumes event)', () async {
      String? toastMessage;
      await testNocterm('ctrl_c_first_press_current', (tester) async {
        await tester.pumpComponent(
          _CtrlCGuardDemo(
            runningSessionIds: const {1},
            currentSessionId: 1,
            onToast: (msg) => toastMessage = msg,
          ),
        );

        // Send first Ctrl+C
        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: const ModifierKeys(ctrl: true),
          ),
        );

        // Status should be 'warned' — the stream is NOT cancelled
        // ('Streaming: true' still), the quit guard is armed, and the
        // toast points at the second press to quit.
        expect(tester.terminalState, containsText('warned'));
        expect(tester.terminalState, containsText('Streaming: true'));
        expect(tester.terminalState, containsText('QuitHint: true'));
        expect(
          toastMessage,
          equals('A session is running. Press Ctrl+C again to quit.'),
        );
      });
    });

    test('First Ctrl+C when a *non-current* session is running shows warning '
        '(regression test for the bug where Ctrl+C exited silently)', () async {
      // This is the regression test for the bug the user reported: a
      // background session is the one running, the user is currently
      // sitting on a different (idle) session, and Ctrl+C used to exit
      // the app immediately. The guard must catch this and require
      // a second press.
      String? toastMessage;
      await testNocterm('ctrl_c_background_session', (tester) async {
        await tester.pumpComponent(
          _CtrlCGuardDemo(
            // Session 2 is running, but the user is currently viewing 1.
            runningSessionIds: const {2},
            currentSessionId: 1,
            onToast: (msg) => toastMessage = msg,
          ),
        );

        // Send first Ctrl+C
        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: const ModifierKeys(ctrl: true),
          ),
        );

        // Status should be 'warned' — the guard fires on any running
        // session, not just the current one.
        expect(tester.terminalState, containsText('warned'));
        expect(tester.terminalState, containsText('AnyRunning: true'));
        expect(tester.terminalState, containsText('Streaming: false'));
        expect(tester.terminalState, containsText('QuitHint: true'));
        expect(
          toastMessage,
          equals('A session is running. Press Ctrl+C again to quit.'),
        );
      });
    });

    test(
      'Quick double Ctrl+C while streaming quits (double-press exit)',
      () async {
        var toastCount = 0;
        await testNocterm('ctrl_c_second_press', (tester) async {
          await tester.pumpComponent(
            _CtrlCGuardDemo(
              runningSessionIds: const {1},
              currentSessionId: 1,
              onToast: (msg) => toastCount++,
            ),
          );

          // Send first Ctrl+C — arms the guard, stream keeps running
          await tester.sendKeyEvent(
            KeyboardEvent(
              logicalKey: LogicalKey.keyC,
              modifiers: const ModifierKeys(ctrl: true),
            ),
          );

          expect(tester.terminalState, containsText('warned'));

          // Send second Ctrl+C quickly (within 3s)
          await tester.sendKeyEvent(
            KeyboardEvent(
              logicalKey: LogicalKey.keyC,
              modifiers: const ModifierKeys(ctrl: true),
            ),
          );

          // Status should be 'quit' (second press lets it through)
          expect(tester.terminalState, containsText('quit'));
          expect(tester.terminalState, containsText('QuitHint: false'));
          // Only one toast should have been shown (on the first press)
          expect(toastCount, equals(1));
        });
      },
    );

    test('Other key press after first Ctrl+C resets the hint', () async {
      String? toastMessage;
      await testNocterm('ctrl_c_reset_by_other_key', (tester) async {
        await tester.pumpComponent(
          _CtrlCGuardDemo(
            runningSessionIds: const {1},
            currentSessionId: 1,
            onToast: (msg) => toastMessage = msg,
          ),
        );

        // Send first Ctrl+C
        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: const ModifierKeys(ctrl: true),
          ),
        );

        expect(tester.terminalState, containsText('QuitHint: true'));

        // Press another key (e.g. 'a')
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.keyA, character: 'a'),
        );

        // QuitHint should be reset
        expect(tester.terminalState, containsText('QuitHint: false'));

        // Now Ctrl+C should be treated as a fresh first press
        toastMessage = null;
        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: const ModifierKeys(ctrl: true),
          ),
        );

        // Should warn again (fresh first press), not quit
        expect(tester.terminalState, containsText('warned'));
        expect(
          toastMessage,
          equals('A session is running. Press Ctrl+C again to quit.'),
        );
      });
    });

    test('Ctrl+Shift+C is not caught by the guard', () async {
      String? toastMessage;
      await testNocterm('ctrl_shift_c_not_caught', (tester) async {
        await tester.pumpComponent(
          _CtrlCGuardDemo(
            runningSessionIds: const {1},
            currentSessionId: 1,
            onToast: (msg) => toastMessage = msg,
          ),
        );

        // Send Ctrl+Shift+C (should NOT be caught by the guard)
        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: const ModifierKeys(ctrl: true, shift: true),
          ),
        );

        // Status should still be 'idle' (the guard didn't activate)
        expect(tester.terminalState, containsText('idle'));
        expect(toastMessage, isNull);
      });
    });
  });
}

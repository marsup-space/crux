import 'dart:io';

import '../theme/theme_controller.dart';
import '../utils/run_metrics.dart';

/// Handles the quit-and-print-summary flow for the chat panel.
///
/// Extracted from `_ChatPanelState` so the terminal-teardown escape
/// sequence and run-summary rendering live in their own class.
class QuitHandler {
  final ThemeController themeController;

  QuitHandler({required this.themeController});

  /// Single exit path used by both `/quit` and the Ctrl+C handler.
  ///
  /// This is the load-bearing reason the chat panel owns the exit
  /// rather than letting nocterm's default `CtrlCBehavior.immediateExit`
  /// do the work: that default calls `StdioBackend.requestExit(0)`,
  /// which schedules an `exit(0)` on a microtask — and that microtask
  /// runs before `runApp()`'s `runEventLoop` can notice `_shouldExit`.
  void quitAndPrintSummary() {
    RunMetrics.instance.setLastKnownTheme(themeController.activeTheme);

    // Step 2: alt-screen copy. Best-effort.
    try {
      stdout.writeln();
      stdout.writeln(RunMetrics.instance.formatStyledSummary());
    } catch (_) {}

    // Step 3: terminal teardown escape codes.
    stdout.write('\x1B[?1003l'); // disable all motion tracking
    stdout.write('\x1B[?1006l'); // disable SGR mouse mode
    stdout.write('\x1B[?1002l'); // disable button event tracking
    stdout.write('\x1B[?1000l'); // disable basic mouse tracking
    stdout.write('\x1B[>4;0m'); // reset modifyOtherKeys
    stdout.write('\x1B[<u'); // pop kitty keyboard mode
    stdout.write('\x1B[?2004l'); // disable bracketed paste mode
    stdout.write('\x1B[?25h'); // show cursor
    stdout.write('\x1B[?1049l'); // leave alt-screen (main buffer)
    stdout.write('\x1B[0m'); // reset attributes

    // Step 4: re-print the styled summary into the main buffer.
    stdout.writeln();
    stdout.writeln(RunMetrics.instance.formatStyledSummary());
    stdout.writeln();

    // Step 5: flush, then exit.
    stdout.flush().then((_) => exit(0));
  }
}

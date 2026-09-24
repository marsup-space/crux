import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../theme/theme_controller.dart';
import '../utils/run_metrics.dart';

/// Handles the quit-and-print-summary flow for the chat panel.
///
/// Extracted from `_ChatPanelState` so the terminal-teardown escape
/// sequence and run-summary rendering live in their own class.
class QuitHandler {
  final ThemeController themeController;

  /// Resolves the locale-aware strings at quit time rather than
  /// construction time — the panel constructs this handler in
  /// `initState`, before the `LocaleController` may be wired, and
  /// the user can switch languages in either direction afterwards.
  /// The resolved strings are stashed on [RunMetrics] so the
  /// `bin/crux.dart` post-`runApp` fallback path renders the
  /// summary in the same language the user was reading, even
  /// though the `LocaleController` is already gone by then.
  final Strings Function() stringsProvider;

  /// Best-effort async cleanup awaited just before `exit(0)` — wired
  /// by the chat panel to `LspManager.shutdown` so `/quit` and the
  /// Ctrl+C path stop all language-server child processes instead of
  /// orphaning them. Awaited with a bounded timeout in
  /// [quitAndPrintSummary]: a hung server must never keep the
  /// terminal from exiting.
  final Future<void> Function()? onBeforeExit;

  QuitHandler({
    required this.themeController,
    this.onBeforeExit,
    this.stringsProvider = kEnglishStringsFn,
  });

  Strings get strings => stringsProvider();

  /// Single exit path used by both `/quit` and the Ctrl+C handler.
  ///
  /// Async so [onBeforeExit] (LSP shutdown) can run to completion —
  /// within its timeout — before the process leaves.
  ///
  /// This is the load-bearing reason the chat panel owns the exit
  /// rather than letting nocterm's default `CtrlCBehavior.immediateExit`
  /// do the work: that default calls `StdioBackend.requestExit(0)`,
  /// which schedules an `exit(0)` on a microtask — and that microtask
  /// runs before `runApp()`'s `runEventLoop` can notice `_shouldExit`.
  Future<void> quitAndPrintSummary() async {
    RunMetrics.instance.setLastKnownTheme(themeController.activeTheme);
    RunMetrics.instance.setLastKnownStrings(strings);

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
    // Windows Terminal's win32-input mode is terminal-global and survives the
    // Crux process. If it is left enabled, the next shell receives keypresses
    // as literal `CSI Vk;Sc;Uc;Kd;Cs;Rc_` packets. This quit path calls
    // dart:io's exit() directly, so it must mirror nocterm's normal teardown.
    stdout.write('\x1B[?9001l'); // disable Windows win32 input mode
    stdout.write('\x1B[?2004l'); // disable bracketed paste mode
    stdout.write('\x1B[?25h'); // show cursor
    stdout.write('\x1B[?1049l'); // leave alt-screen (main buffer)
    // Repeat after switching buffers in case the terminal restored modes that
    // were active on the main screen.
    stdout.write('\x1B[?9001l'); // keep the caller's shell in normal input mode
    stdout.write('\x1B[0m'); // reset attributes

    // Step 4: re-print the styled summary into the main buffer.
    stdout.writeln();
    stdout.writeln(RunMetrics.instance.formatStyledSummary());
    stdout.writeln();

    // This path deliberately exits without returning through runApp, so make
    // nocterm restore the complete native console-mode snapshot as well as the
    // terminal escape protocols above. Otherwise VT input remains enabled in
    // the PowerShell/cmd session that launched Crux.
    try {
      TerminalBinding.instance.terminal.backend.disableRawMode();
    } catch (_) {}

    // Step 4.5: give async cleanup (LSP shutdown) a bounded window so
    // language-server children are not orphaned by the exit below.
    // Bounded at 3s: a wedged server must not hold the terminal
    // hostage, and `LspServerActor._killAfter`'s SIGKILL escalation
    // backstops the graceful stop while this process is still alive.
    // The try/catch guarantees the exit even if the callback throws.
    try {
      await onBeforeExit?.call().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    } catch (_) {}

    // Step 5: flush, then exit.
    stdout.flush().then((_) => exit(0));
  }
}

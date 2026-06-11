import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Windows console handle ID for STDOUT, matching the C `STD_OUTPUT_HANDLE`
/// macro (defined as `(DWORD)-11` in the Windows SDK).
const int _kStdOutputHandle = -11;

/// `ENABLE_PROCESSED_OUTPUT` (0x0001) is required for control characters
/// and virtual terminal sequences to be handled by the console.
const int _kEnableProcessedOutput = 0x0001;

/// `ENABLE_VIRTUAL_TERMINAL_PROCESSING` (0x0004) — makes the Windows
/// console interpret ANSI escape sequences (cursor moves, colors, clears,
/// etc.) instead of dropping them. New apps on Windows 10 1607+ get
/// this by default, but for compatibility the mode may be turned off
/// when the app is launched from CMD, PowerShell, or a redirected
/// stdin/stdout. We turn it on explicitly so the splash and TUI work
/// consistently across hosts (conhost, PowerShell ISE, etc.).
const int _kEnableVirtualTerminalProcessing = 0x0004;

/// `DISABLE_NEWLINE_AUTO_RETURN` (0x0008) delays wrapping after a character
/// is written in the final column. Nocterm writes full-width rows followed by
/// `\n`; without delayed wrapping, conhost advances once for the last cell and
/// again for the newline, scrolling the first frame off-screen.
const int _kDisableNewlineAutoReturn = 0x0008;

int windowsVtOutputMode(int currentMode) {
  return currentMode |
      _kEnableProcessedOutput |
      _kEnableVirtualTerminalProcessing |
      _kDisableNewlineAutoReturn;
}

/// Enable `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on the Windows stdout
/// console.
///
/// Without this, ANSI escape sequences (e.g. `\x1B[2J` to clear the
/// screen, `\x1B[H` to move the cursor) are silently dropped by the
/// legacy Windows console, so the splash and the TUI's cursor moves
/// don't render — the screen appears blank after the logo.
///
/// Delayed newline auto-return is also required because Nocterm renders
/// terminal-width rows. Classic conhost otherwise wraps at the final column
/// before processing the following newline, which advances two rows per
/// rendered row and scrolls the visible content away.
///
/// This must be called **before any ANSI output**, so put it at the
/// very start of `main()`. It's a no-op on non-Windows platforms and
/// when stdout isn't a console (e.g. redirected to a file or pipe).
void enableWindowsVt() {
  if (!Platform.isWindows) return;

  // FFI lookups are lazy so this stays a no-op on non-Windows even at
  // the linker level. (Top-level `DynamicLibrary.open('kernel32.dll')`
  // would fail on macOS/Linux, so we must defer.)
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle = kernel32
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetStdHandle',
      );
  final getConsoleMode = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');
  final setConsoleMode = kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'SetConsoleMode',
      );

  final hOut = getStdHandle(_kStdOutputHandle);
  // INVALID_HANDLE_VALUE (-1) and NULL (0) both mean "no real console".
  if (hOut == 0 || hOut == -1) return;

  final modePtr = calloc<Uint32>();
  try {
    if (getConsoleMode(hOut, modePtr) == 0) return; // call failed
    final newMode = windowsVtOutputMode(modePtr.value);
    setConsoleMode(hOut, newMode);
  } finally {
    calloc.free(modePtr);
  }
}

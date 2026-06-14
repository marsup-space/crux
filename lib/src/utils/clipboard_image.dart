import 'dart:io';

/// Utility for reading image data from the system clipboard.
///
/// Clipboard image support is platform-dependent and requires external
/// tools. This class attempts to read image data using platform-specific
/// commands:
///
/// - **macOS**: `pbpaste` (only text) or `osascript` to read clipboard
///   as PNG. Falls back to reading from `/tmp/crux_clipboard.png` if
///   the user has previously saved a screenshot there.
/// - **Linux (X11)**: `xclip -selection clipboard -t image/png -o`
/// - **Linux (Wayland)**: `wl-paste --type image/png`
/// - **Windows**: PowerShell `Get-Clipboard -Format Image`
///
/// If no suitable tool is available, returns null.
class ClipboardImageReader {
  /// Attempts to read an image from the system clipboard.
  ///
  /// Returns the raw image bytes if successful, or null if:
  /// - No image is on the clipboard
  /// - The required clipboard tool is not installed
  /// - Reading fails for any reason
  static Future<ClipboardImageResult?> readImage() async {
    if (Platform.isMacOS) {
      return _readMacOS();
    } else if (Platform.isLinux) {
      return _readLinux();
    } else if (Platform.isWindows) {
      return _readWindows();
    }
    return null;
  }

  static Future<ClipboardImageResult?> _readMacOS() async {
    // Try osascript to save clipboard image to a temp file
    final tmpDir = Directory.systemTemp;
    final tmpPath =
        '${tmpDir.path}/crux_clipboard_${DateTime.now().millisecondsSinceEpoch}.png';

    try {
      final result = await Process.run('osascript', [
        '-e',
        'set theType to (clipboard info) as text\n'
            'if theType contains «class PNGf» then\n'
            '  set pngData to the clipboard as «class PNGf»\n'
            '  set theFile to open for access POSIX file "$tmpPath" with write permission\n'
            '  write pngData to theFile\n'
            '  close access theFile\n'
            '  return "ok"\n'
            'else\n'
            '  return "no_image"\n'
            'end if',
      ]);

      if (result.exitCode == 0 &&
          result.stdout.toString().trim() == 'ok' &&
          await File(tmpPath).exists()) {
        final bytes = await File(tmpPath).readAsBytes();
        await File(tmpPath).delete();
        if (bytes.isNotEmpty) {
          return ClipboardImageResult(
            bytes: bytes,
            mediaType: 'image/png',
            label: 'clipboard (PNG)',
          );
        }
      }
    } catch (_) {
      // osascript not available or failed
    }

    // Clean up temp file if it exists
    try {
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) await tmpFile.delete();
    } catch (_) {}

    return null;
  }

  static Future<ClipboardImageResult?> _readLinux() async {
    // Try Wayland first (wl-paste), then X11 (xclip)

    // Wayland: wl-paste
    try {
      final result = await Process.run(
        'wl-paste',
        ['--type', 'image/png'],
        stdoutEncoding: null, // binary output
      );
      if (result.exitCode == 0 && result.stdout is List<int>) {
        final bytes = result.stdout as List<int>;
        if (bytes.isNotEmpty) {
          return ClipboardImageResult(
            bytes: bytes,
            mediaType: 'image/png',
            label: 'clipboard (Wayland PNG)',
          );
        }
      }
    } catch (_) {
      // wl-paste not available
    }

    // X11: xclip
    try {
      final result = await Process.run(
        'xclip',
        ['-selection', 'clipboard', '-t', 'image/png', '-o'],
        stdoutEncoding: null, // binary output
      );
      if (result.exitCode == 0 && result.stdout is List<int>) {
        final bytes = result.stdout as List<int>;
        if (bytes.isNotEmpty) {
          return ClipboardImageResult(
            bytes: bytes,
            mediaType: 'image/png',
            label: 'clipboard (X11 PNG)',
          );
        }
      }
    } catch (_) {
      // xclip not available
    }

    return null;
  }

  static Future<ClipboardImageResult?> _readWindows() async {
    // Use PowerShell to save clipboard image to a temp file
    final tmpDir = Directory.systemTemp;
    final tmpPath =
        '${tmpDir.path}\\crux_clipboard_${DateTime.now().millisecondsSinceEpoch}.png';

    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; '
            'if ([System.Windows.Forms.Clipboard]::ContainsImage()) { '
            '\$img = [System.Windows.Forms.Clipboard]::GetImage(); '
            '\$img.Save("$tmpPath", [System.Drawing.Imaging.ImageFormat]::Png); '
            'Write-Output "ok" '
            '} else { Write-Output "no_image" }',
      ]);

      if (result.exitCode == 0 &&
          result.stdout.toString().trim() == 'ok' &&
          await File(tmpPath).exists()) {
        final bytes = await File(tmpPath).readAsBytes();
        await File(tmpPath).delete();
        if (bytes.isNotEmpty) {
          return ClipboardImageResult(
            bytes: bytes,
            mediaType: 'image/png',
            label: 'clipboard (PNG)',
          );
        }
      }
    } catch (_) {
      // PowerShell not available or failed
    }

    // Clean up temp file if it exists
    try {
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) await tmpFile.delete();
    } catch (_) {}

    return null;
  }

  /// Check if clipboard image reading is likely supported on this platform.
  static bool isSupported() {
    if (Platform.isMacOS) return true; // osascript is always available
    if (Platform.isWindows) return true; // PowerShell is always available
    if (Platform.isLinux) {
      // Check for wl-paste or xclip
      try {
        final result = Process.runSync('which', ['wl-paste']);
        if (result.exitCode == 0) return true;
      } catch (_) {}
      try {
        final result = Process.runSync('which', ['xclip']);
        if (result.exitCode == 0) return true;
      } catch (_) {}
    }
    return false;
  }
}

/// The result of reading an image from the clipboard.
class ClipboardImageResult {
  final List<int> bytes;
  final String mediaType;
  final String label;

  const ClipboardImageResult({
    required this.bytes,
    required this.mediaType,
    required this.label,
  });
}

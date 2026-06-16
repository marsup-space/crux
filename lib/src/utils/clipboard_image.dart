import 'dart:io';

/// Utility for reading image data from the system clipboard.
///
/// Clipboard image support is platform-dependent and requires external
/// tools. This class attempts to read image data using platform-specific
/// commands:
///
/// - **macOS**: `osascript` for PNG/JPEG/TIFF, with `sips` to convert
///   TIFF clipboard data to PNG.
/// - **Linux (X11)**: `xclip -selection clipboard -t <image type> -o`
/// - **Linux (Wayland)**: `wl-paste --type <image type>`
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
    return await _readMacOSClass(
          osType: 'PNGf',
          extension: 'png',
          mediaType: 'image/png',
          label: 'clipboard (PNG)',
        ) ??
        await _readMacOSClass(
          osType: 'JPEG',
          extension: 'jpg',
          mediaType: 'image/jpeg',
          label: 'clipboard (JPEG)',
        ) ??
        await _readMacOSTiffAsPng();
  }

  static Future<ClipboardImageResult?> _readMacOSClass({
    required String osType,
    required String extension,
    required String mediaType,
    required String label,
  }) async {
    final tmpPath = _tempPath(extension);
    try {
      final result = await Process.run('osascript', [
        '-e',
        'set theType to (clipboard info) as text\n'
            'if theType contains «class $osType» then\n'
            '  set imageData to the clipboard as «class $osType»\n'
            '  set theFile to open for access POSIX file "$tmpPath" with write permission\n'
            '  write imageData to theFile\n'
            '  close access theFile\n'
            '  return "ok"\n'
            'else\n'
            '  return "no_image"\n'
            'end if',
      ]);
      if (result.exitCode == 0 && result.stdout.toString().trim() == 'ok') {
        return await _resultFromFile(
          tmpPath,
          mediaType: mediaType,
          label: label,
        );
      }
    } catch (_) {
      // osascript not available or failed
    } finally {
      await _deleteIfExists(tmpPath);
    }
    return null;
  }

  static Future<ClipboardImageResult?> _readMacOSTiffAsPng() async {
    final tiffPath = _tempPath('tiff');
    final pngPath = _tempPath('png');
    try {
      final result = await Process.run('osascript', [
        '-e',
        'set theType to (clipboard info) as text\n'
            'if theType contains «class TIFF» then\n'
            '  set imageData to the clipboard as «class TIFF»\n'
            '  set theFile to open for access POSIX file "$tiffPath" with write permission\n'
            '  write imageData to theFile\n'
            '  close access theFile\n'
            '  return "ok"\n'
            'else\n'
            '  return "no_image"\n'
            'end if',
      ]);
      if (result.exitCode != 0 || result.stdout.toString().trim() != 'ok') {
        return null;
      }

      final convert = await Process.run('sips', [
        '-s',
        'format',
        'png',
        tiffPath,
        '--out',
        pngPath,
      ]);
      if (convert.exitCode != 0) return null;
      return await _resultFromFile(
        pngPath,
        mediaType: 'image/png',
        label: 'clipboard (TIFF)',
      );
    } catch (_) {
      return null;
    } finally {
      await _deleteIfExists(tiffPath);
      await _deleteIfExists(pngPath);
    }
  }

  static Future<ClipboardImageResult?> _readLinux() async {
    const formats = [
      ('image/png', 'clipboard (PNG)'),
      ('image/jpeg', 'clipboard (JPEG)'),
      ('image/webp', 'clipboard (WebP)'),
      ('image/bmp', 'clipboard (BMP)'),
      ('image/tiff', 'clipboard (TIFF)'),
    ];

    for (final (mediaType, label) in formats) {
      final wayland = await _readBinaryCommand(
        'wl-paste',
        ['--type', mediaType],
        mediaType: mediaType,
        label: label,
      );
      if (wayland != null) return wayland;

      final x11 = await _readBinaryCommand(
        'xclip',
        ['-selection', 'clipboard', '-t', mediaType, '-o'],
        mediaType: mediaType,
        label: label,
      );
      if (x11 != null) return x11;
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

    await _deleteIfExists(tmpPath);
    return null;
  }

  static String _tempPath(String extension) {
    return '${Directory.systemTemp.path}/crux_clipboard_'
        '${DateTime.now().microsecondsSinceEpoch}.$extension';
  }

  static Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<ClipboardImageResult?> _resultFromFile(
    String path, {
    required String mediaType,
    required String label,
  }) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return ClipboardImageResult(
      bytes: bytes,
      mediaType: mediaType,
      label: label,
    );
  }

  static Future<ClipboardImageResult?> _readBinaryCommand(
    String executable,
    List<String> arguments, {
    required String mediaType,
    required String label,
  }) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: null,
      );
      if (result.exitCode == 0 && result.stdout is List<int>) {
        final bytes = result.stdout as List<int>;
        if (bytes.isNotEmpty) {
          return ClipboardImageResult(
            bytes: bytes,
            mediaType: mediaType,
            label: label,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Check if clipboard image reading is likely supported on this platform.
  static bool isSupported() {
    if (Platform.isMacOS) return true; // osascript and sips are available
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

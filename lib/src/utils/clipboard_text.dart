import 'dart:convert';
import 'dart:io';

/// Best-effort system clipboard text reader.
///
/// Terminal applications cannot ask the terminal to "perform paste", and
/// OSC 52 clipboard reads are not consistently available. For an explicit
/// paste button, reading via the host OS tools is the most predictable path.
class ClipboardTextReader {
  static Future<String?> readText() async {
    if (Platform.isMacOS) {
      return _runTextCommand('pbpaste', const []);
    }
    if (Platform.isLinux) {
      return await _runTextCommand('wl-paste', const [
            '--type',
            'text/plain',
          ]) ??
          await _runTextCommand('xclip', const [
            '-selection',
            'clipboard',
            '-o',
          ]) ??
          await _runTextCommand('xsel', const ['--clipboard', '--output']);
    }
    if (Platform.isWindows) {
      return await _runTextCommand('powershell', const [
            '-NoProfile',
            '-Command',
            'Get-Clipboard -Raw',
          ]) ??
          await _runTextCommand('pwsh', const [
            '-NoProfile',
            '-Command',
            'Get-Clipboard -Raw',
          ]);
    }
    return null;
  }

  static Future<String?> _runTextCommand(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return null;
      final text = result.stdout as String;
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }
}

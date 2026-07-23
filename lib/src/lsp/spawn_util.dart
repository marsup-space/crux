// Binary lookup helpers for LSP server actors.
//
// Mirrors OpenCode's `which` utility (`packages/opencode/src/lsp/server.ts`
// uses it for nearly every server): search PATH for an executable,
// checking common Windows extensions on win32.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Locate [binary] on PATH. Returns the absolute path or null.
///
/// On Windows, also tries `binary.exe` and `binary.cmd` (npm-installed
/// language servers typically ship a `.cmd` shim).
String? whichBinary(String binary) {
  final env = Platform.environment;
  final pathVar = env['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final suffixes = Platform.isWindows
      ? const ['.exe', '.cmd', '.bat', '']
      : const [''];
  for (final dir in pathVar.split(separator)) {
    if (dir.isEmpty) continue;
    for (final suffix in suffixes) {
      final candidate = p.join(dir, '$binary$suffix');
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

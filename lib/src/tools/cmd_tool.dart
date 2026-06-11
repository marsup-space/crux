import 'dart:io';

import 'shell_base.dart';

class CmdTool extends ShellBase {
  @override
  String get name => 'cmd';

  @override
  String get description =>
      'Executes a Windows cmd.exe command with optional timeout. '
      'Commands are written to a temporary .bat file to sidestep '
      'cmd.exe\'s broken argv parser; the file is deleted after execution. '
      'Use this for running CLI apps, chaining operations, or anything '
      'that needs the shell. Only avoid for single file operations that '
      'dedicated tools handle better: use read/write/edit for file '
      'content, grep for search, glob for file matching, etc. '
      'Prefer powershell for complex pipelines or .NET interop.';

  @override
  ShellInvocation resolveInvocation(String command, {String encoding = 'utf8'}) {
    final codepage = _toChcp(encoding);
    final collapsed = command.replaceAll('\r\n', '\n').replaceAll('\n', ' ');
    final preamble = codepage != null ? '@chcp $codepage > nul\r\n' : '';
    final tempBat = File(
      '${Directory.systemTemp.path}/crux_cmd_${DateTime.now().microsecondsSinceEpoch}.bat',
    );
    tempBat.writeAsStringSync('$preamble$collapsed');
    return ShellInvocation(
      executable: 'cmd.exe',
      args: ['/c', tempBat.path],
      cleanupPaths: [tempBat.path],
    );
  }

  int? _toChcp(String encoding) {
    switch (encoding.toLowerCase()) {
      case 'utf8':
      case 'utf-8':
        return 65001;
      case 'ascii':
        return 20127;
      case 'latin1':
      case 'windows-1252':
        return 1252;
      default:
        return 65001;
    }
  }
}

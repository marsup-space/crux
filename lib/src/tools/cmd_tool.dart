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
      'Use for classic Windows operations: dir, type, copy, del, etc. '
      'Prefer powershell for complex pipelines or .NET interop.';

  @override
  ShellInvocation resolveInvocation(String command) {
    final tempBat = File(
      '${Directory.systemTemp.path}/crux_cmd_${DateTime.now().microsecondsSinceEpoch}.bat',
    );
    tempBat.writeAsStringSync(
      command.replaceAll('\r\n', '\n').replaceAll('\n', ' '),
    );
    return ShellInvocation(
      executable: 'cmd.exe',
      args: ['/c', tempBat.path],
      cleanupPaths: [tempBat.path],
    );
  }
}

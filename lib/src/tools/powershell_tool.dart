import 'shell_base.dart';

class PowerShellTool extends ShellBase {
  @override
  String get name => 'powershell';

  @override
  String get description =>
      'Executes a Windows PowerShell command with optional timeout. '
      'Use for complex pipelines, .NET calls, and structured output '
      '(Get-ChildItem, Select-String, ConvertTo-Json, etc.). '
      'Prefer cmd for simple file operations.';

  @override
  ShellInvocation resolveInvocation(String command) => ShellInvocation(
    executable: 'powershell.exe',
    args: [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command.replaceAll('\r\n', '\n').replaceAll('\n', ' '),
    ],
  );
}

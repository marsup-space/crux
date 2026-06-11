import 'shell_base.dart';

class PowerShellTool extends ShellBase {
  @override
  String get name => 'powershell';

  @override
  String get description =>
      'Executes a Windows PowerShell command with optional timeout. '
      'Use this for running CLI apps, chaining operations in a pipeline, '
      'or anything that needs the shell. Only avoid for single file '
      'operations that dedicated tools handle better: use read/write/edit '
      'for file content, grep for search, glob for file matching, etc. '
      'Supports complex pipelines, .NET calls, and structured output '
      '(Get-ChildItem, Select-String, ConvertTo-Json, etc.).';

  @override
  ShellInvocation resolveInvocation(String command, {String encoding = 'utf8'}) {
    final psEncoding = _toPowerShellEncoding(encoding);
    final preamble = '[Console]::OutputEncoding = $psEncoding; '
        '\$OutputEncoding = $psEncoding;';
    final fullCommand = '$preamble $command';
    return ShellInvocation(
      executable: 'powershell.exe',
      args: [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        fullCommand.replaceAll('\r\n', '\n').replaceAll('\n', ' '),
      ],
    );
  }

  String _toPowerShellEncoding(String enc) {
    switch (enc.toLowerCase()) {
      case 'utf8':
      case 'utf-8':
        return '[System.Text.Encoding]::UTF8';
      case 'utf16':
      case 'utf-16':
        return '[System.Text.Encoding]::Unicode';
      case 'ascii':
        return '[System.Text.Encoding]::ASCII';
      case 'utf7':
      case 'utf-7':
        return '[System.Text.Encoding]::UTF7';
      case 'utf32':
      case 'utf-32':
        return '[System.Text.Encoding]::UTF32';
      case 'default':
      case 'system':
        return '[System.Text.Encoding]::Default';
      default:
        return '[System.Text.Encoding]::UTF8';
    }
  }
}

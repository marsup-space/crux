import 'shell_base.dart';

class PowerShellTool extends ShellBase {
  @override
  String get name => 'powershell';

  @override
  String get description =>
      'Executes a Windows PowerShell command with optional timeout. '
      'Use ONLY for shell-native tasks: running project scripts, '
      'builds, tests, complex pipelines, .NET interop, and chaining '
      'CLI commands together. '
      'CHAINING IS ENCOURAGED — PowerShell pipelines (|) are the '
      'idiomatic way to combine commands, and you can chain multiple '
      'in one call alongside && and ||. This saves roundtrips and is '
      'a primary reason to use this tool. Prefer one rich powershell '
      'call over several short ones. Example patterns: '
      '`dotnet build && dotnet test`, '
      '`Get-Process | Where-Object {\$_.CPU -gt 10} | Select-Object -First 5`, '
      '`git status && git diff --stat`. '
      'Do NOT use this tool to inspect files (search/find/read/edit) '
      '— use grep, glob, read, edit, or write. Tailing or filtering '
      'the OUTPUT of other CLI commands is fine — that is chaining, '
      'not file inspection. Running Select-String, Get-ChildItem as a '
      'file lister, Get-Content, or Select-Object on file contents '
      'as the primary operation is wrong — use the dedicated tool. '
      'They are faster, return structured output, and avoid '
      'shell-quoting bugs.';

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

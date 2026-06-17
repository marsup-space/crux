import 'shell_base.dart';

class BashTool extends ShellBase {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes a bash command (Unix/macOS) with optional timeout. '
      'Use ONLY for shell-native tasks: running project scripts, '
      'builds, tests, git operations, and package managers. '
      'CHAINING IS ENCOURAGED — combine multiple CLI commands in one '
      'call using pipes (|), &&, ||, xargs, subshells \$(...), command '
      'lists, etc. This saves roundtrips and is a primary reason to '
      'use this tool. Prefer one rich bash call over several short '
      'ones. Example patterns: `flutter analyze && flutter test`, '
      '`git status && git diff --stat`, `dart run bin/main.dart '
      '2>&1 | tail -50`. '
      'Do NOT use this tool to inspect files (search/find/read/edit) '
      '— use grep, glob, read, edit, or write. Tailing or filtering '
      'the OUTPUT of other CLI commands (e.g. `build 2>&1 | tail -50`) '
      'is fine — that is chaining, not file inspection. Running grep, '
      'rg, find, cat, head, tail, ls -R, or tree as the primary '
      'operation on a file is wrong — use the dedicated tool. They '
      'are faster, return structured output, and avoid shell-quoting '
      'bugs.';

  @override
  ShellInvocation resolveInvocation(String command, {String encoding = 'utf8'}) {
    final locale = _toLocale(encoding);
    final args = <String>[];
    if (locale != null) {
      args.addAll(['-c', 'export LANG=$locale LC_ALL=$locale; $command']);
    } else {
      args.addAll(['-c', command]);
    }
    return ShellInvocation(
      executable: '/bin/bash',
      args: args,
    );
  }

  String? _toLocale(String encoding) {
    switch (encoding.toLowerCase()) {
      case 'utf8':
      case 'utf-8':
        return 'en_US.UTF-8';
      case 'ascii':
        return 'C';
      default:
        return 'en_US.UTF-8';
    }
  }
}

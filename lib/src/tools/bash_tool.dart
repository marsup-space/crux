import 'shell_base.dart';

class BashTool extends ShellBase {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes a bash command (Unix/macOS) with optional timeout. '
      'Use this for running CLI apps, chaining operations, or anything '
      'that needs the shell. Only avoid for single file operations that '
      'dedicated tools handle better: use read/write/edit for file '
      'content, grep for search, glob for file matching, etc. '
      'Prefer chaining related work in one call over multiple tool invocations.';

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

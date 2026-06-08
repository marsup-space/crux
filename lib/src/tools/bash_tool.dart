import 'shell_base.dart';

class BashTool extends ShellBase {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes a bash command (Unix/macOS) with optional timeout. '
      'Prefer chaining related work in one call over multiple tool invocations.';

  @override
  ShellInvocation resolveInvocation(String command) => ShellInvocation(
    executable: '/bin/bash',
    args: ['-c', command],
  );
}

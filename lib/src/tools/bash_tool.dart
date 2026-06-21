import 'shell_base.dart';

class BashTool extends ShellBase {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Executes a bash command (Unix/macOS) with optional timeout. '
      'CHAINING IS ENCOURAGED — combine multiple CLI commands in one '
      'call using pipes (|), &&, ||, xargs, subshells \$(...), command '
      'lists, etc. Prefer one rich bash call over several short ones. '
      ''
      '✅ USE FOR (shell-native tasks only): '
      '• Project scripts: `dart run`, `npm test`, `flutter analyze`, '
      '  `make build`, `cargo build`. '
      '• Version control: `git status`, `git diff`, `git log`, '
      '  `git stash`, `git checkout`. '
      '• Package managers: `npm install`, `pip install`, '
      '  `dart pub add`, `brew install`. '
      '• Process / system: `ps`, `lsof`, `pgrep`, `kill`, `uname`, '
      '  `df`, `env`, `which`. '
      '• Piping OUTPUT of another command to filter it '
      '  (`build 2>&1 | tail -50` is fine — that\'s chaining, not '
      '  file inspection). '
      ''
      '❌ DO NOT USE FOR (use the dedicated tool instead): '
      '• `cat`, `head`, `tail`, `less`, `more`            → `read` '
      '• `ls`, `find`, `tree`, `du -sh` on a directory     → `glob` '
      '• `grep`, `rg`, `ack`, `ag` on file contents       → `grep` '
      '• "How does X work / find code that does X"        → `code_search` '
      '• `sed -n "100,120p"`, `awk`, `cut`, `sort`, `uniq` → `read` with '
      '  line range + `grep` '
      '• `wc -l`, `md5sum`, `file`, `stat` on one file    → `read` '
      '• `diff file1 file2`                              → `read` on both '
      ''
      'WHY: dedicated tools are faster (no shell fork), return '
      'structured output, support parallel calls, and avoid shell-'
      'quoting bugs. The bash+cat/sed/rg fallback is the #1 source '
      'of wasted tool calls in this codebase. '
      ''
      'EXAMPLES: '
      '✅ `flutter analyze && flutter test` '
      '✅ `git status && git diff --stat` '
      '✅ `dart run bin/main.dart 2>&1 | tail -50` '
      '❌ `cat lib/main.dart`                          → `read` instead '
      '❌ `ls -la lib/`                                 → `glob "lib/**"` '
      '❌ `grep -rn "TODO" lib/`                        → `grep` instead '
      '❌ `rg "auth" lib/ | head`                       → `code_search` '
      '❌ `sed -n \'100,120p\' foo.dart`                → `read` with range';

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

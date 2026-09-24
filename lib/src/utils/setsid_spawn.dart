// Shared "setsid trampoline" process spawning.
//
// Dart's normal `Process.start` keeps Unix children in Crux's own
// process group, so killing a child's group to clean up its
// grandchildren would also deliver SIGTERM to the Crux TUI. The
// trampoline wraps the real command in a tiny Perl one-liner that
// calls `setsid()` (new session => own process group, pid == pgid)
// and then `exec`s the real command — the Perl process is fully
// replaced, so:
//
//   * `process.kill()` on the spawned pid signals the real server
//     directly (the trampoline no longer exists), and
//   * `kill -TERM -- -<pid>` reaches the server's whole process
//     group, so forked grandchildren die with it.
//
// Used by the shell tool (`ShellBase._prepareInvocation`) and the
// LSP actor (`LspServerActor.spawnProcess`). Unix only; on Windows
// callers fall back to a plain `Process.start`.

import 'dart:io';

/// Resolve the perl executable used by the trampoline. Prefers
/// `/usr/bin/perl` (always present on macOS / most Linux distros)
/// so the spawn never depends on PATH.
String resolvePerl() =>
    File('/usr/bin/perl').existsSync() ? '/usr/bin/perl' : 'perl';

/// The trampoline script: setsid into a new session, then exec the
/// real command from `@ARGV`.
const setsidTrampolineScript =
    r'setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n";';

/// Spawn [command] through the setsid trampoline with the given
/// [workingDirectory] / [environment]. On Unix the returned
/// [Process]'s pid is the real server's pid (post-exec) AND its
/// process group id, so both plain `process.kill()` and
/// `kill -TERM -- -<pid>` work.
Future<Process> startWithSetsid(
  List<String> command, {
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.start(
    resolvePerl(),
    ['-MPOSIX=setsid', '-e', setsidTrampolineScript, ...command],
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

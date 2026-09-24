// Shared group-kill helper, currently used by the LSP actor's kill
// sites (`lsp/actor.dart`: `_killAfter` / `_cleanupDeadServer`) — the
// setsid trampoline (`setsid_spawn.dart`) makes every LSP server a
// session leader (pid == pgid), so a group kill reaps grandchildren
// the server forked. This file is also the designated home for
// deduplicating the remaining kill sites (`ShellProcessRegistry`
// group-kill logic, daemon `producer.dart`).
import 'dart:io' as io;

/// Crux's own pid, resolved once. Used to distinguish the monitored
/// process group from Crux's own (a child spawned into the same group
/// must never group-kill the TUI).
final int _ownPid = io.pid;

/// Crux's own pgid, resolved lazily once. The stronger guard: a child
/// that has not run `setsid()` yet (the tiny window between
/// `Process.start` returning and the trampoline's setsid call) still
/// sits in Crux's group — its pgid is [_ownPgid], not its own pid.
final int _ownPgid = _readPgid(io.pid);

/// Read [osPid]'s process group via `ps`, or -1 when unreadable.
int _readPgid(int osPid) {
  final r = io.Process.runSync('ps', ['-o', 'pgid=', '-p', '$osPid']);
  if (r.exitCode != 0) return -1;
  return int.tryParse(r.stdout.toString().trim()) ?? -1;
}

/// Send SIGTERM to [process]'s whole process group so child processes
/// die with it (shell pipelines, background jobs), falling back to
/// killing the process itself. Shared by every kill site in the app:
/// the interrupt / timeout / monitor paths in `shell_base.dart` (via
/// `ShellProcessRegistry`), the monitor toast's kill button (via
/// `ShellMonitorRegistry` in `shell_monitor_notifier.dart`), and the
/// LSP actor's teardown paths in `lsp/actor.dart`.
///
/// We shell out to `kill -TERM -- -PGID` because Dart's
/// `Process.killPid` may not support negative PIDs. Crux's own
/// process group is never signalled: normally-started Unix children
/// inherit it (the setsid-wrapped ones leave it within milliseconds),
/// and killing that group would deliver SIGTERM back to the TUI. The
/// guard therefore skips when the target group is Crux's own pid OR
/// pgid.
void killProcessGroup(io.Process process) {
  try {
    if (io.Platform.isWindows) {
      process.kill();
      return;
    }
    final pgid = _readPgid(process.pid);
    if (pgid > 0 && pgid != _ownPid && pgid != _ownPgid) {
      io.Process.runSync('kill', ['-TERM', '--', '-$pgid']);
    }
    // Also kill the process itself as a fallback.
    process.kill();
  } catch (_) {}
}

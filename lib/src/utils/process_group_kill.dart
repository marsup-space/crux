// Reserved shared kill helper: originally extracted so the monitor
// toast's kill path could reuse `ShellProcessRegistry`'s group-kill
// logic. The final wiring hands kills back to
// `ShellProcessRegistry.killAll` instead, so this file currently has
// no importers — kept because it documents the negative-PGID kill
// recipe and is the designated home for the next kill-site
// deduplication (replacing `ShellProcessRegistry._killProcessGroup`).
import 'dart:io' as io;

/// Crux's own pid, resolved once. Used to distinguish the monitored
/// process group from Crux's own (a child spawned into the same group
/// must never group-kill the TUI).
final int _ownPid = io.pid;

/// Send SIGTERM to [process]'s whole process group so child processes
/// die with it (shell pipelines, background jobs), falling back to
/// killing the process itself. Shared by every kill site in the app:
/// the interrupt / timeout / monitor paths in `shell_base.dart` (via
/// `ShellProcessRegistry`) and the monitor toast's kill button (via
/// `ShellMonitorRegistry` in `shell_monitor_notifier.dart`).
///
/// We shell out to `kill -TERM -- -PGID` because Dart's
/// `Process.killPid` may not support negative PIDs. Crux's own
/// process group is never signalled: normally-started Unix children
/// inherit it, and killing that group would deliver SIGTERM back to
/// the TUI.
void killProcessGroup(io.Process process) {
  try {
    if (io.Platform.isWindows) {
      process.kill();
      return;
    }
    int pgidOf(int osPid) {
      final r = io.Process.runSync('ps', ['-o', 'pgid=', '-p', '$osPid']);
      if (r.exitCode != 0) return -1;
      final v = int.tryParse(r.stdout.toString().trim());
      return v ?? -1;
    }

    final pgid = pgidOf(process.pid);
    if (pgid > 0 && pgid != _ownPid) {
      io.Process.runSync('kill', ['-TERM', '--', '-$pgid']);
    }
    // Also kill the process itself as a fallback.
    process.kill();
  } catch (_) {}
}

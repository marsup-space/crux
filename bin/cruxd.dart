// cruxd — the Crux sidecar daemon.
//
// Usage:
//   cruxd serve          run the daemon (spawned by Crux instances on
//                        demand; exits when the last instance leaves)
//   cruxd status         print the daemon snapshot (human-readable)
//   cruxd stop           ask a running daemon to shut down now
//
// The daemon is a plain resident process — no launchd/systemd. Any
// Crux instance bootstraps it when first needed (race-safe via the
// state file), and it lights off by itself once no instance is
// registered (grace, then group-kill producers, then exit).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/daemon/daemon.dart';
import 'package:crux/src/daemon/control_server.dart';

String _home() => Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.systemTemp.path;

File _stateFile() => File('${_home()}/.crux/daemon/state.json');

Future<void> main(List<String> args) async {
  final cmd = args.isNotEmpty ? args.first : 'serve';
  switch (cmd) {
    case 'serve':
      await _serve();
    case 'status':
      await _status();
    case 'stop':
      await _stop();
    default:
      stderr.writeln('Usage: cruxd [serve|status|stop]');
      exit(64);
  }
}

// ── serve ───────────────────────────────────────────────────────────

Future<void> _serve() async {
  // Stale recovery (plan §5): if a previous daemon died without
  // cleanup, its state file still lists producer pids — group-kill
  // those best-effort before taking over.
  final stateFile = _stateFile();
  await _reapOrphans(stateFile);

  final core = DaemonCore(stateFile: stateFile);
  final server = ControlServer(core);
  await server.start();
  core.port = server.port;
  core.startPeriodic();

  // Clean shutdown on SIGTERM/SIGINT (cruxd stop, logout): kill all
  // producer groups, mark the state file as exited, leave.
  ProcessSignal.sigterm.watch().listen((_) => _shutdown(core, server));
  ProcessSignal.sigint.watch().listen((_) => _shutdown(core, server));

  // Lights-off: poll the core's decision — when the last instance
  // leaves (and producers are drained), light off on our own.
  final done = Completer<void>();
  Timer.periodic(const Duration(milliseconds: 500), (t) {
    if (core.shouldExit) {
      t.cancel();
      if (!done.isCompleted) done.complete();
    }
  });
  await done.future;
  await _shutdown(core, server);
}

Future<void> _shutdown(DaemonCore core, ControlServer server) async {
  core.stopPeriodic();
  await core.killAll();
  await server.close();
  await core.markExited();
  exit(0);
}

// ── status / stop ──────────────────────────────────────────────────

Future<void> _status() async {
  final status = await _discover();
  if (status == null) {
    stdout.writeln('cruxd: not running');
    exit(1);
  }
  final http = await _get('http://127.0.0.1:${status.$2}/status');
  if (http == null) {
    stdout.writeln('cruxd: state file present but unreachable');
    exit(1);
  }
  const encoder = JsonEncoder.withIndent('  ');
  stdout.writeln(encoder.convert(http));
}

Future<void> _stop() async {
  final status = await _discover();
  if (status == null) {
    stdout.writeln('cruxd: not running');
    return;
  }
  final ok = Process.killPid(status.$1, ProcessSignal.sigterm);
  stdout.writeln(ok ? 'cruxd: SIGTERM sent' : 'cruxd: failed to signal');
}

// ── helpers ────────────────────────────────────────────────────────

Future<void> _reapOrphans(File stateFile) async {
  try {
    final raw = stateFile.readAsStringSync();
    if (raw.trim().isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;
    final producers = decoded['producers'];
    if (producers is! List) return;
    for (final p in producers) {
      if (p is! Map<String, dynamic>) continue;
      final pid = p['pid'] as int?;
      if (pid == null) continue;
      // Group-kill the old producer's session.
      Process.runSync(
        '/bin/sh',
        ['-c', 'kill -TERM -- -$pid 2>/dev/null || true'],
      );
    }
  } catch (_) {}
}

Future<(int, int)?> _discover() async {
  try {
    final raw = _stateFile().readAsStringSync();
    if (raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final pidN = decoded['pid'];
    final portN = decoded['port'];
    if (pidN is! int || portN is! int) return null;
    final alive = Process.runSync(
      '/bin/sh',
      ['-c', 'kill -0 $pidN 2>/dev/null'],
    );
    if (alive.exitCode != 0) return null;
    return (pidN, portN);
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _get(String url) async {
  try {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return null;
  }
}

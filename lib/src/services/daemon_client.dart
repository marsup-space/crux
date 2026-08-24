// Crux-side client for cruxd (plan §4.3, §8) — bootstrap (spawn the
// daemon when needed, race-safe singleton), register / heartbeat /
// deregister, and re-declaration when the plugin scan changes.
//
// Failure philosophy: the daemon is an OPTIMIZATION for plugin
// producers. Every call degrades silently — if cruxd is unreachable
// the TUI keeps rendering plugins from their status files exactly as
// it does today (touch_on_poll remains the daemon-free fallback).

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/plugin.dart';
import '../daemon/protocol.dart';

/// One Crux process's handle to cruxd.
class DaemonClient {
  /// Directory holding state.json (default `~/.crux/daemon/`).
  final Directory dataDir;

  /// Path of the `cruxd` executable to bootstrap when absent.
  final String cruxdPath;

  /// This instance's unique id (`pid-epochMillis`, stable per run).
  late final String instanceId;

  /// This process's OS pid.
  final int myPid;

  /// Project root reported at registration.
  final String projectPath;

  DaemonClient({
    required this.projectPath,
    Directory? dataDir,
    String? cruxdPath,
  })  : dataDir = dataDir ?? _defaultDataDir(),
        cruxdPath = cruxdPath ?? _defaultCruxdPath(),
        myPid = pid {
    instanceId = '$myPid-${DateTime.now().millisecondsSinceEpoch}';
  }

  static Directory _defaultDataDir() =>
      Directory(p.join(_home(), '.crux', 'daemon'));

  static String _home() => Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;

  static String _defaultCruxdPath() =>
      p.join(_home(), '.crux', 'bin', 'cruxd');

  File get stateFile => File(p.join(dataDir.path, 'state.json'));

  int? _port;
  Timer? _heartbeatTimer;
  final _declarations = <String, ProducerDecl>{};
  bool _registered = false;

  /// Daemon port once connected (null = not connected).
  int? get port => _port;

  // ── Bootstrap ───────────────────────────────────────────────────

  /// Discover or spawn cruxd, then register this instance with the
  /// current producer declarations (derived from `plugins`).
  ///
  /// Race safety (plan §4.3): after spawning we re-read state.json;
  /// if another instance's daemon won, we adopt that one. The daemon
  /// itself is started with its own session (setsid trampoline), so
  /// its lifetime is decoupled from ours.
  Future<void> connect(List<Plugin> plugins) async {
    _syncDeclarations(plugins);
    var status = await _discover();
    if (status == null) {
      await _spawnDaemon();
      status = await _discover(retries: 12, delay: const Duration(milliseconds: 400));
    }
    if (status == null) return; // unreachable — run daemonless
    _port = status.port;
    await _post('/register', {
      'instanceId': instanceId,
      'pid': myPid,
      'project': projectPath,
      'producers': [for (final d in _declarations.values) d.toJson()],
    });
    _registered = true;
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_tick()),
    );
  }

  /// Heartbeat + re-declare on scan changes. On failure (daemon
  /// died, machine slept through a port change) falls into a
  /// reconnect loop: re-discover/re-spawn and re-register. A
  /// heartbeat that succeeds again heals silently — this is what
  /// makes sleep/wake transparent.
  Future<void> _tick() async {
    if (!_registered) return;
    final body = {
      'instanceId': instanceId,
      'pid': myPid,
      'project': projectPath,
      'producers': [for (final d in _declarations.values) d.toJson()],
    };
    final res = await _post('/heartbeat', body);
    if (res == null) {
      _reconnect();
    }
  }

  /// Loss-of-daemon recovery: re-run discovery (＋ respawn if the
  /// daemon is truly gone), re-register, resume heartbeating.
  /// Debounced: a burst of failed ticks collapses into one attempt.
  bool _reconnecting = false;
  Future<void> _reconnect() async {
    if (_reconnecting || !_registered) return;
    _reconnecting = true;
    try {
      _port = null;
      var status = await _discover(
        retries: 3,
        delay: const Duration(seconds: 1),
      );
      if (status == null) {
        await _spawnDaemon();
        status = await _discover(
          retries: 12,
          delay: const Duration(milliseconds: 400),
        );
      }
      if (status == null) return; // still unreachable — next tick retries
      _port = status.port;
      // Heartbeat-with-identity doubles as register (self-heal on
      // the daemon side re-registers unknown instance ids).
      await _post('/register', {
        'instanceId': instanceId,
        'pid': myPid,
        'project': projectPath,
        'producers': [for (final d in _declarations.values) d.toJson()],
      });
    } finally {
      _reconnecting = false;
    }
  }

  /// Call when the plugin registry re-scanned and the producer set
  /// may have changed (spec added/removed/edited).
  /// Registry rescan hook: re-derive declarations and re-declare on
  /// any change (added/removed/edited producer specs).
  void pluginsChanged(List<Plugin> plugins) {
    if (!_registered) return;
    final before = <String>{..._declarations.keys};
    _syncDeclarations(plugins);
    final after = <String>{..._declarations.keys};
    if (after.difference(before).isNotEmpty ||
        before.difference(after).isNotEmpty) {
      unawaited(_tick());
    }
  }

  /// Explicit deregister on clean shutdown. Also stops heartbeating.
  Future<void> shutdown() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_registered) return;
    _registered = false;
    try {
      await _post('/deregister', {'instanceId': instanceId});
    } catch (_) {}
    _port = null;
  }

  // ── Declarations ────────────────────────────────────────────────

  void _syncDeclarations(List<Plugin> plugins) {
    _declarations.clear();
    for (final plugin in plugins) {
      final producer = plugin.producer;
      if (producer == null) continue;
      final key = plugin.isGlobal
          ? globalProducerKey(pluginId: plugin.id)
          : producerKey(projectPath: projectPath, pluginId: plugin.id);
      _declarations[key] = ProducerDecl(
        key: key,
        pluginId: plugin.id,
        command: producer.command,
        cwd: producer.cwd,
      );
    }
  }

  // ── HTTP plumbing ───────────────────────────────────────────────

  Future<DaemonStatus?> _discover({
    int retries = 1,
    Duration delay = Duration.zero,
  }) async {
    for (var i = 0; i < retries; i++) {
      final status = await _discoverOnce();
      if (status != null) return status;
      if (i < retries - 1) await Future<void>.delayed(delay);
    }
    return null;
  }

  Future<DaemonStatus?> _discoverOnce() async {
    try {
      final raw = stateFile.readAsStringSync();
      if (raw.trim().isEmpty) return null; // clean-exit marker
      final status = DaemonStatus.tryParse(raw);
      if (status == null) return null;
      // pid alive?
      final alive = Process.runSync(
        '/bin/sh',
        ['-c', 'kill -0 ${status.pid} 2>/dev/null'],
      );
      if (alive.exitCode != 0) return null;
      // port answers?
      final health = await _get('http://127.0.0.1:${status.port}/status');
      if (health == null) return null;
      return status;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _get(String url) async {
    try {
      final client = HttpClient();
      try {
        final req = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 2));
        final res = await req.close().timeout(const Duration(seconds: 2));
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

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final port = _port;
    if (port == null) return null;
    try {
      final client = HttpClient();
      try {
        final req = await client
            .postUrl(
              Uri.parse('http://127.0.0.1:$port$path'),
            )
            .timeout(const Duration(seconds: 2));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final res = await req.close().timeout(const Duration(seconds: 2));
        final text = await res.transform(utf8.decoder).join();
        final decoded = jsonDecode(text);
        return decoded is Map<String, dynamic> ? decoded : null;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  /// Spawn cruxd as a detached session leader (its lifetime must be
  /// independent of this Crux instance). Race-loser per plan §4.3:
  /// whatever daemon writes state.json first wins; we re-discover.
  Future<void> _spawnDaemon() async {
    if (!File(cruxdPath).existsSync()) return;
    try {
      final proc = await Process.start(
        '/usr/bin/perl',
        [
          '-MPOSIX=setsid',
          '-e',
          r'setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n";',
          cruxdPath,
          'serve',
        ],
        mode: ProcessStartMode.detached,
      );
      unawaited(proc.exitCode);
    } catch (_) {}
  }
}

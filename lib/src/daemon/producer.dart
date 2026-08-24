// Producer supervision for cruxd — spawn (own session/process group
// via setsid), crash restart with exponential backoff, group kill.
//
// Process-group isolation rationale (plan §5): every producer is
// started through a tiny Perl setsid trampoline (same trick as
// lib/src/tools/shell_base.dart) so:
//   - killing the producer's group never signals cruxd or Crux;
//   - a producer spawning children (curl | jq pipelines) dies with
//     its whole subtree on group kill — no orphans.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// Exponential backoff policy for crashed producers.
class BackoffPolicy {
  const BackoffPolicy({
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(seconds: 60),
    this.maxRestarts = 5,
    this.stableAfter = const Duration(seconds: 30),
  });

  final Duration base;
  final Duration cap;

  /// Consecutive crashes beyond this → mark the producer `dead`
  /// (stop restarting; visible in /status so the author notices).
  final int maxRestarts;

  /// A run lasting at least this resets the consecutive-crash count.
  final Duration stableAfter;

  Duration delayFor(int restarts) {
    var d = base * (1 << restarts.clamp(0, 6)); // 1,2,4,…,64 cap@60s
    if (d > cap) d = cap;
    return d;
  }
}

/// One supervised producer. Owned by [DaemonCore]; never used
/// directly by clients.
class SupervisedProducer {
  final ProducerDecl decl;
  final BackoffPolicy backoff;

  Process? _process;
  DateTime _startedAt = DateTime.now();
  int _consecutiveCrashes = 0;
  String _status = 'idle'; // idle|running|backoff|dead
  String? _lastExit;
  Timer? _restartTimer;

  /// Log sink for stdout+stderr (truncated ring) — surfaced in
  /// /status for author debugging. Size-capped so a chatty script
  /// can't balloon the daemon.
  final List<String> _log = [];
  static const _maxLogLines = 50;

  SupervisedProducer(this.decl, {this.backoff = const BackoffPolicy()});

  // ── Introspection ───────────────────────────────────────────────

  int? get pid => _process?.pid;
  String get status => _status;
  String? get lastExit => _lastExit;
  int get restarts => _consecutiveCrashes;
  DateTime get startedAt => _startedAt;
  List<String> get logTail => List.unmodifiable(_log);

  bool get isRunning => _process != null && _status == 'running';

  /// Set while an INTENTIONAL teardown (kill/restart) owns the
  /// process: the exitCode callback must not run crash accounting
  /// for a kill WE initiated.
  bool _teardown = false;

  ProducerState snapshot() => ProducerState(
        decl: decl,
        pid: pid,
        startedAt: _startedAt,
        restarts: _consecutiveCrashes,
        status: _status,
        lastExit: _lastExit,
      );

  // ── Lifecycle ───────────────────────────────────────────────────

  /// Resolve the spec's command template against the plugin's
  /// last-known status JSON (`{field}` placeholders, plan §6).
  /// Unknown placeholders stay literal (visible = debuggable, same
  /// convention as plugin labels).
  static String renderCommand(String template, Map<String, dynamic> data) =>
      template.replaceAllMapped(
        RegExp(r'\{([a-zA-Z0-9_.]+)\}'),
        (m) {
          final v = _dig(data, m.group(1)!);
          return v?.toString() ?? m.group(0)!;
        },
      );

  static dynamic _dig(Map<String, dynamic> data, String dotted) {
    var cur = data;
    final parts = dotted.split('.');
    for (var i = 0; i < parts.length; i++) {
      if (!cur.containsKey(parts[i])) return null;
      final v = cur[parts[i]];
      if (i == parts.length - 1) return v;
      if (v is Map<String, dynamic>) {
        cur = v;
      } else {
        return null;
      }
    }
    return null;
  }

  /// Spawn (or re-spawn) the producer. [dataByPlugin] supplies
  /// status snapshots for command-template rendering.
  Future<void> start({
    Map<String, Map<String, dynamic>>? statusData,
    void Function(SupervisedProducer)? onChanged,
  }) async {
    if (isRunning) return;
    _restartTimer?.cancel();
    _restartTimer = null;

    final data = statusData?[decl.pluginId] ?? const {};
    final command = renderCommand(decl.command, data);

    try {
      // setsid trampoline: own session => process group leader =>
      // group-killable without collateral damage (see header).
      final proc = await Process.start(
        '/usr/bin/perl',
        [
          '-MPOSIX=setsid',
          '-e',
          r'setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n";',
          '/bin/sh',
          '-c',
          command,
        ],
        workingDirectory: decl.cwd,
      );
      _process = proc;
      _startedAt = DateTime.now();
      _status = 'running';
      _lastExit = null;
      _log.clear();
      onChanged?.call(this);

      // Drain output into the ring buffer (bounded memory).
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => _appendLog(l), onError: (Object e) {});
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => _appendLog(l), onError: (Object e) {});

      unawaited(
        proc.exitCode.then((code) => _onExit(code, onChanged)),
      );
    } catch (e) {
      // Spawn itself failed (bad path, exec format…) — treat as a
      // crash for backoff purposes.
      _appendLog('spawn failed: $e');
      _onExit(-1, onChanged);
    }
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > _maxLogLines) _log.removeRange(0, _log.length - _maxLogLines);
  }

  void _onExit(int code, void Function(SupervisedProducer)? onChanged) {
    _process = null;
    if (_teardown) {
      // Intentional kill — not a crash. No backoff, no ladder.
      return;
    }
    _lastExit = code == -1 ? 'spawn failure' : 'exit $code';

    // Stable run? reset the crash ladder.
    if (DateTime.now().difference(_startedAt) >= backoff.stableAfter) {
      _consecutiveCrashes = 0;
    } else {
      _consecutiveCrashes++;
    }

    if (_consecutiveCrashes > backoff.maxRestarts) {
      _status = 'dead';
      onChanged?.call(this);
      return;
    }

    // Backoff, then respawn. The restart timer keeps the daemon's
    // promise: "producers stay up while referenced" — a crash loop
    // yields to backoff, not abandonment.
    _status = 'backoff';
    onChanged?.call(this);
    final delay = backoff.delayFor(_consecutiveCrashes);
    _appendLog('restarting in ${delay.inSeconds}s '
        '(crash #$_consecutiveCrashes)');
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      unawaited(start(onChanged: onChanged));
    });
  }

  /// Manual restart (POST /producer/restart): kills the group,
  /// resets the crash ladder, spawns fresh.
  Future<void> restart({
    Map<String, Map<String, dynamic>>? statusData,
    void Function(SupervisedProducer)? onChanged,
  }) async {
    await kill();
    _consecutiveCrashes = 0;
    _status = 'idle';
    await start(statusData: statusData, onChanged: onChanged);
  }

  /// Kill the whole process group (SIGTERM → grace → SIGKILL).
  /// Idempotent.
  Future<void> kill() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _teardown = true;
    final proc = _process;
    _process = null;
    if (proc == null) {
      _teardown = false;
      return;
    }
    // The setsid trampoline made the child a session leader; its
    // pid IS the pgid.
    final pgid = proc.pid;
    _killGroup(pgid, ProcessSignal.sigterm);
    // Grace window, then hard kill.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!_pidAlive(pgid)) break;
    }
    _killGroup(pgid, ProcessSignal.sigkill);
    // Give the exitCode callback a beat to observe the teardown flag.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _teardown = false;
  }

  void _killGroup(int pgid, ProcessSignal sig) {
    // Dart lacks killpg; emulate with `kill -<SIG> -<pgid>` via sh.
    // (killPid targets a single pid — wrong tool for a group.)
    final name = sig == ProcessSignal.sigkill ? 'KILL' : 'TERM';
    try {
      Process.runSync(
        '/bin/sh',
        ['-c', 'kill -$name -- -$pgid 2>/dev/null || true'],
      );
    } catch (_) {}
  }

  bool _pidAlive(int pid) {
    // kill -0 probes existence without signalling.
    final r = Process.runSync('/bin/sh', ['-c', 'kill -0 $pid 2>/dev/null']);
    return r.exitCode == 0;
  }
}

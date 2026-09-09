// cruxd core — instance table with GC, producer reference counting,
// grace-period lights-off, atomic state-file writes (plan §5).
//
// The single source of truth for "who consumes what":
//
//   instances: instanceId → InstanceInfo   (GC: heartbeat + pid)
//   producers: key        → SupervisedProducer
//
// Reconciliation runs on every mutation AND on a period:
//   refcount(key) = # alive instances declaring it
//   >0  → ensure running
//   =0  → grace (default 5 s) → kill, drop
//   instances empty → kill all producers → exit the daemon.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'producer.dart';

/// Tunables (plan §5; overridable for tests).
class DaemonTuning {
  const DaemonTuning({
    this.instanceTimeout = const Duration(seconds: 15),
    this.emptyGrace = const Duration(seconds: 5),
    this.gcInterval = const Duration(seconds: 2),
    this.stateWriteInterval = const Duration(seconds: 5),
  });

  /// Heartbeat staleness before an instance is GC'd.
  final Duration instanceTimeout;

  /// Reference-zero grace before a producer is killed (absorbs
  /// instance restarts and the A-exits/B-starts seam).
  final Duration emptyGrace;

  final Duration gcInterval;
  final Duration stateWriteInterval;
}

class DaemonCore {
  final DaemonTuning tuning;
  final File stateFile;
  final BackoffPolicy backoff;

  final _instances = <String, InstanceInfo>{};
  final _producers = <String, SupervisedProducer>{};

  /// key → earliest instant a zero-ref kill may run (grace ledger).
  final _zeroSince = <String, DateTime>{};

  int port = 0;
  final DateTime _startedAt = DateTime.now();
  Timer? _timer;
  bool _shuttingDown = false;

  /// Set true when the daemon decides to exit (instances empty);
  /// bin/cruxd.dart polls this to leave its `serve` loop.
  bool get shouldExit => _shuttingDown;

  DaemonCore({
    required this.stateFile,
    this.tuning = const DaemonTuning(),
    this.backoff = const BackoffPolicy(),
  });

  // ── Registration ────────────────────────────────────────────────

  /// Register/refresh an instance and reconcile producers.
  void register(InstanceInfo info, List<ProducerDecl> decls) {
    _instances[info.id] = info;
    _mountDecls(decls);
    _reconcile();
  }

  /// Explicit deregister (clean instance shutdown).
  bool deregister(String instanceId) {
    final gone = _instances.remove(instanceId) != null;
    if (gone) _reconcile();
    return gone;
  }

  /// Heartbeat: refresh liveness; producer list may have changed
  /// (plugin spec rescan) — re-declare, dropping stale keys. An
  /// UNKNOWN instance id (daemon restarted meanwhile) is treated as
  /// a fresh register — self-healing per plan §5.
  void heartbeat(String instanceId, List<ProducerDecl> decls) {
    final known = _instances[instanceId];
    if (known == null) {
      // Unknown instance (daemon restarted meanwhile) — re-register
      // from the heartbeat body. Self-healing per plan §5.
      final pid = _bodyPid;
      if (pid == null) return; // caller didn't supply identity
      register(
        InstanceInfo(
          id: instanceId,
          pid: pid,
          project: _bodyProject ?? '',
          producerKeys: decls.map((d) => d.key).toSet(),
          lastSeen: DateTime.now(),
        ),
        decls,
      );
      return;
    }
    _instances[instanceId] = InstanceInfo(
      id: known.id,
      pid: known.pid,
      project: known.project,
      producerKeys: decls.map((d) => d.key).toSet(),
      lastSeen: DateTime.now(),
    );
    _mountDecls(decls);
    _reconcile();
  }

  /// Set by [ControlServer] from the heartbeat body (self-heal path
  /// needs pid/project the daemon never saw).
  set bodyPid(int? pid) => _bodyPid = pid;
  int? _bodyPid;

  set bodyProject(String? project) => _bodyProject = project;
  String? _bodyProject;

  void _mountDecls(List<ProducerDecl> decls) {
    for (final d in decls) {
      final existing = _producers[d.key];
      if (existing == null) {
        _producers[d.key] = SupervisedProducer(d, backoff: backoff);
      } else if (existing.decl != d) {
        // Same key, changed spec (command edited) — swap the decl,
        // reconcile will restart it via the kill+spawn path.
        _producers[d.key] = SupervisedProducer(d, backoff: backoff);
      }
    }
  }

  // ��─ Reconciliation ──────────────────────────────────────────────

  void _reconcile() {
    if (_shuttingDown) return;
    // refs per key across ALIVE instances.
    final refs = <String, int>{};
    for (final info in _instances.values) {
      for (final k in info.producerKeys) {
        refs[k] = (refs[k] ?? 0) + 1;
      }
    }

    // Spawn any referenced-but-not-running producer.
    for (final e in _producers.entries) {
      final p = e.value;
      if ((refs[e.key] ?? 0) > 0) {
        _zeroSince.remove(e.key);
        if (!p.isRunning && p.status != 'dead' && p.status != 'backoff') {
          unawaited(p.start(onChanged: (_) => _writeState()));
        }
      } else {
        // Zero refs: start/keep the grace clock…
        final since = _zeroSince[e.key] ??= DateTime.now();
        // …and kill when it expires.
        if (DateTime.now().difference(since) >= tuning.emptyGrace) {
          _zeroSince.remove(e.key);
          final p = _producers.remove(e.key);
          unawaited(p?.kill());
        }
      }
    }

    // Lights-off: no CONSUMERS at all → kill everything & exit.
    // (Producers may still be draining — killAll handles them; the
    // decision is about instances, not producer emptiness.)
    if (_instances.isEmpty) {
      _beginShutdown();
    }
  }

  void _beginShutdown() {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _timer?.cancel();
    _timer = null;
    // Take the producers out of the map FIRST so no racing state
    // write can resurrect them into state.json, then drain kills.
    final draining = List.of(_producers.values);
    _producers.clear();
    unawaited(
      Future.wait([for (final p in draining) p.kill()])
          .timeout(const Duration(seconds: 3), onTimeout: () => <void>[]),
    );
    _writeState();
  }

  // ── Periodic GC ─────────────────────────────────────────────────

  void startPeriodic() {
    _timer ??= Timer.periodic(tuning.gcInterval, (_) => _gcTick());
    _writeState();
  }

  void stopPeriodic() {
    _timer?.cancel();
    _timer = null;
  }

  void _gcTick() {
    if (_shuttingDown) return;
    // Liveness by OS pid ONLY (not wall-clock heartbeats): a machine
    // waking from sleep advances wall time arbitrarily while every
    // process was frozen — a stale-lastSeen check would GC instances
    // that are alive and merely late. `kill -0` is sleep-immune and
    // also covers the kill -9 case. Heartbeat freshness remains a
    // display/debug signal, never a kill signal.
    _instances.removeWhere((id, info) => !_pidAlive(info.pid));
    _reconcile();
    _writeState();
  }

  static bool _pidAlive(int pid) {
    final r = Process.runSync('/bin/sh', ['-c', 'kill -0 $pid 2>/dev/null']);
    return r.exitCode == 0;
  }

  // ── Producer control ────────────────────────────────────────────

  Future<bool> restartProducer(String key) async {
    final p = _producers[key];
    if (p == null) return false;
    await p.restart(onChanged: (_) => _writeState());
    return true;
  }

  /// Kill all producers (daemon exit path). Waits bounded time.
  Future<void> killAll() async {
    final kills = <Future<void>>[for (final p in _producers.values) p.kill()];
    await Future.wait(kills)
        .timeout(const Duration(seconds: 3), onTimeout: () => <void>[]);
    _producers.clear();
  }

  // ── Status / state file ─────────────────────────────────────────

  Map<String, dynamic> statusJson() => DaemonStatus(
    pid: pid,
    port: port,
    startedAt: _startedAt,
    heartbeatAt: DateTime.now(),
    instances: _instances.values.toList(),
    producers: [for (final p in _producers.values) p.snapshot()],
  ).toJson();

  /// Idempotent atomic state write (tmp+rename). Best-effort: a
  /// read-only home must not kill the daemon.
  void _writeState() {
    try {
      stateFile.parent.createSync(recursive: true);
      final tmp = File('${stateFile.path}.tmp');
      tmp.writeAsStringSync(
        _shuttingDown && _producers.isEmpty
            ? '' // shutdown marker: empty file = "exited cleanly"
            : _stateJsonRaw(),
      );
      tmp.renameSync(stateFile.path);
    } catch (_) {}
  }

  String _stateJsonRaw() {
    final json = statusJson();
    json['pid'] = pid;
    json['port'] = port;
    return jsonEncode(json);
  }

  /// Called by bin/cruxd.dart just before exit: empty-file marker,
  /// so a racing bootstrap sees "no daemon" immediately.
  Future<void> markExited() async {
    try {
      stateFile.parent.createSync(recursive: true);
      final tmp = File('${stateFile.path}.tmp');
      tmp.writeAsStringSync('');
      tmp.renameSync(stateFile.path);
    } catch (_) {}
  }
}

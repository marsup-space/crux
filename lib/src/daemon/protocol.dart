// cruxd wire protocol — DTOs shared by the daemon (bin/cruxd.dart,
// lib/src/daemon/) and its clients (lib/src/services/daemon_client.dart).
//
// Line format (plan §4.0): bare loopback HTTP/1.1 + UTF-8 JSON bodies,
// matching the DevControlServer / plugin-http-action conventions:
//
//   GET  /status             → read-only snapshot (same shape as state.json)
//   POST /register           → instance up (mount producers)
//   POST /deregister         → instance down (explicit)
//   POST /heartbeat          → keep-alive; re-declare producers on change
//   POST /producer/restart   → restart one producer by key
//
// Every response is `{ok: true, ...data}` or `{ok: false, error: "…"}`
// with a matching HTTP status (200 / 400 / 404 / 409). No auth
// (loopback bind only), no versioning (single consumer family in
// Phase 1).
//
// This file is pure DTOs + hand-rolled toJson/fromJson — no codegen,
// no dependencies outside dart:convert. Both the daemon binary and
// the TUI import it; keep it that way (the daemon must stay slim).

library;

import 'dart:convert';

/// One producer declaration, carried inside register/heartbeat.
/// Producers are IDENTIFIED BY [key] (see [producerKey]); a register
/// with the same key as a live producer REUSES it (reference
/// counting), never spawns a duplicate.
class ProducerDecl {
  /// Stability key: `<projectPath>:<pluginId>` for project plugins,
  /// `~:<pluginId>` for global ones. Two instances declaring the
  /// same key share one OS process.
  final String key;

  /// The plugin id (for status display / restart UX).
  final String pluginId;

  /// Command line to run when the reference count goes 0 → positive.
  /// A template over the plugin's status JSON (same placeholders as
  /// the label), evaluated by the DAEMON at spawn time against the
  /// last-known status snapshot for `{field}` substitution.
  final String command;

  /// Working directory for the command. Null → the declaring
  /// instance's project root.
  final String? cwd;

  const ProducerDecl({
    required this.key,
    required this.pluginId,
    required this.command,
    this.cwd,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'pluginId': pluginId,
    'command': command,
    if (cwd != null) 'cwd': cwd,
  };

  static ProducerDecl? fromJson(Map<String, dynamic> json) {
    final key = json['key'] as String?;
    final pluginId = json['pluginId'] as String?;
    final command = json['command'] as String?;
    if (key == null || pluginId == null || command == null) return null;
    return ProducerDecl(
      key: key,
      pluginId: pluginId,
      command: command,
      cwd: json['cwd'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProducerDecl &&
      other.key == key &&
      other.pluginId == pluginId &&
      other.command == command &&
      other.cwd == cwd;

  @override
  int get hashCode => Object.hash(key, pluginId, command, cwd);
}

/// A registered Crux instance (the consumer side of reference
/// counting). Liveness = [lastSeen] freshness (heartbeat GC) AND the
/// OS pid still alive (kill -9 fallback detection).
class InstanceInfo {
  final String id;
  final int pid;
  final String project;

  /// Producer keys this instance currently declares. Changes on
  /// re-scan (spec hot-reload) or plugin discovery.
  final Set<String> producerKeys;

  final DateTime lastSeen;

  const InstanceInfo({
    required this.id,
    required this.pid,
    required this.project,
    required this.producerKeys,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'pid': pid,
    'project': project,
    'producers': producerKeys.toList()..sort(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
  };

  static InstanceInfo? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final pid = json['pid'] as int?;
    final project = json['project'] as String?;
    if (id == null || pid == null || project == null) return null;
    final rawKeys = json['producers'];
    return InstanceInfo(
      id: id,
      pid: pid,
      project: project,
      producerKeys: rawKeys is List
          ? rawKeys.map((e) => e.toString()).toSet()
          : const <String>{},
      lastSeen:
          DateTime.tryParse(json['lastSeen'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Runtime state of one managed producer process.
class ProducerState {
  final ProducerDecl decl;

  /// OS pid of the running process, null when not running.
  final int? pid;

  final DateTime startedAt;

  /// Consecutive crash-restarts since the last stable run
  /// (a run lasting ≥ [ProducerSupervisor.stableAfter] resets it).
  final int restarts;

  /// 'running' | 'backoff' | 'dead'. `dead` = gave up after
  /// [ProducerSupervisor.maxRestarts] consecutive crashes; visible
  /// in /status so a plugin author can see their script is broken.
  final String status;

  /// Last exit code / signal note, for diagnostics.
  final String? lastExit;

  const ProducerState({
    required this.decl,
    required this.pid,
    required this.startedAt,
    required this.restarts,
    required this.status,
    this.lastExit,
  });

  Map<String, dynamic> toJson() => {
    ...decl.toJson(),
    if (pid != null) 'pid': pid,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'restarts': restarts,
    'status': status,
    if (lastExit != null) 'lastExit': lastExit,
  };

  static ProducerState fromDecl(ProducerDecl decl) => ProducerState(
    decl: decl,
    pid: null,
    startedAt: DateTime.now(),
    restarts: 0,
    status: 'idle',
  );
}

/// Full daemon snapshot — the shape of `GET /status` data AND
/// `~/.crux/daemon/state.json` (the state file is the same object,
/// atomically rewritten; plan §4.2).
class DaemonStatus {
  final int pid;
  final int port;
  final DateTime startedAt;
  final DateTime heartbeatAt;
  final List<InstanceInfo> instances;
  final List<ProducerState> producers;

  const DaemonStatus({
    required this.pid,
    required this.port,
    required this.startedAt,
    required this.heartbeatAt,
    required this.instances,
    required this.producers,
  });

  Map<String, dynamic> toJson() => {
    'pid': pid,
    'port': port,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'heartbeatAt': heartbeatAt.toUtc().toIso8601String(),
    'instances': [for (final i in instances) i.toJson()],
    'producers': [for (final p in producers) p.toJson()],
  };

  /// Parse the discovery file. Null when unreadable/stale-shaped —
  /// callers treat that as "no daemon" and bootstrap.
  static DaemonStatus? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final pid = decoded['pid'] as int?;
      final port = decoded['port'] as int?;
      if (pid == null || port == null) return null;
      final rawInstances = decoded['instances'];
      final rawProducers = decoded['producers'];
      return DaemonStatus(
        pid: pid,
        port: port,
        startedAt:
            DateTime.tryParse(decoded['startedAt'] as String? ?? '') ??
            DateTime.now(),
        heartbeatAt:
            DateTime.tryParse(decoded['heartbeatAt'] as String? ?? '') ??
            DateTime.now(),
        instances: [
          if (rawInstances is List)
            for (final raw in rawInstances)
              if (raw is Map<String, dynamic>) ?InstanceInfo.fromJson(raw),
        ],
        producers: [
          if (rawProducers is List)
            for (final raw in rawProducers)
              if (raw is Map<String, dynamic>)
                if (ProducerDecl.fromJson(raw) case final decl?)
                  ProducerState(
                    decl: decl,
                    pid: raw['pid'] as int?,
                    startedAt:
                        DateTime.tryParse(raw['startedAt'] as String? ?? '') ??
                        DateTime.now(),
                    restarts: (raw['restarts'] as num?)?.toInt() ?? 0,
                    status: raw['status'] as String? ?? 'unknown',
                    lastExit: raw['lastExit'] as String?,
                  ),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Build a producer's stability key (plan §6).
String producerKey({required String projectPath, required String pluginId}) =>
    '$projectPath:$pluginId';

/// Global-plugin variant: tilde namespace, one process across all
/// projects.
String globalProducerKey({required String pluginId}) => '~:$pluginId';

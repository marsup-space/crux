/// Live bash-progress registry: the delivery channel between the
/// shell tools (which parse output for progress signals) and the vibe
/// progress box (which renders them live).
///
/// Mirrors the `beginExecutingTools` pattern from
/// `streaming_controller.dart` — per-session, per-callId state the UI
/// polls on its render tick — but lives in the service layer so both
/// the tool layer and the UI can reach it without crossing component
/// boundaries. `ShellProcessRegistry.instance` is the precedent for
/// an app-level singleton here.
///
/// Lifecycle: the chat executor mints one [ShellProgressSinkImpl] per
/// bash tool call and hands it to the tool via `ToolContext`. The
/// shell base feeds normalized [ShellProgress] snapshots into it
/// during the run and calls [ShellProgressSink.finish] at the end.
/// Finished entries linger for [finishedTtl] so the live box can
/// flash a "done" state, then prune (on the next read) so memory
/// stays bounded even for sessions nobody re-renders.
library;

import '../tools/shell_progress_parser.dart';

/// One live bash-progress entry, keyed by tool-call id.
class ShellProgressEntry {
  final String callId;

  /// The bash command as passed to the tool (first update's payload).
  final String command;

  final DateTime startedAt;

  /// Latest normalized snapshot; replaced on every update.
  ShellProgress progress;

  /// True once the process exited and [ShellProgressSink.finish]
  /// ran. Finished entries stay readable for the registry's TTL so
  /// the UI can show a brief "✓ done" before pruning.
  bool finished;

  /// Process exit code (null when killed before an exit code could
  /// be read).
  int? exitCode;

  DateTime updatedAt;

  ShellProgressEntry({
    required this.callId,
    required this.command,
    required this.progress,
    required this.startedAt,
    required this.updatedAt,
    this.finished = false,
    this.exitCode,
  });
}

/// App-level registry of live bash progress, keyed by session id then
/// tool-call id. Safe to call from any isolate-adjacent layer — the
/// TUI runs on a single isolate, so no locking is needed.
class ShellProgressRegistry {
  /// App singleton; tests construct their own instances with a tiny
  /// [finishedTtl].
  static final ShellProgressRegistry instance = ShellProgressRegistry();

  /// How long a finished entry stays visible after [finish]. Tuned to
  /// outlive the tail of a tool round so the live box can flash the
  /// result while the model streams its reply.
  final Duration finishedTtl;

  final Map<int, Map<String, ShellProgressEntry>> _bySession = {};

  ShellProgressRegistry({
    this.finishedTtl = const Duration(seconds: 15),
  });

  /// Record a new snapshot for [callId] under [sessionId]. Creates
  /// the entry on first sight (stamping [command]).
  void update(
    int sessionId,
    String callId,
    String command,
    ShellProgress progress,
  ) {
    final perCall = _bySession.putIfAbsent(sessionId, () => {});
    final existing = perCall[callId];
    if (existing == null) {
      perCall[callId] = ShellProgressEntry(
        callId: callId,
        command: command,
        progress: progress,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    } else {
      existing.progress = progress;
      existing.updatedAt = DateTime.now();
    }
  }

  /// Mark [callId]'s run as finished with [exitCode].
  void finish(int sessionId, String callId, {int? exitCode}) {
    final entry = _bySession[sessionId]?[callId];
    if (entry == null) return;
    entry.finished = true;
    entry.exitCode = exitCode;
    entry.updatedAt = DateTime.now();
  }

  /// Live plus recently-finished entries for [sessionId], oldest
  /// first. Prunes finished entries past [finishedTtl] across ALL
  /// sessions on every read, so a session nobody renders never leaks.
  List<ShellProgressEntry> entriesFor(int sessionId) {
    final now = DateTime.now();
    _bySession.removeWhere((sid, perCall) {
      perCall.removeWhere(
        (_, e) => e.finished && now.difference(e.updatedAt) > finishedTtl,
      );
      return perCall.isEmpty;
    });
    final perCall = _bySession[sessionId];
    if (perCall == null || perCall.isEmpty) return const [];
    final list = perCall.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return list;
  }

  /// Drop every entry for [sessionId] (session switch / teardown).
  void clearSession(int sessionId) {
    _bySession.remove(sessionId);
  }
}

/// Default sink: forwards snapshots to a [ShellProgressRegistry]
/// (the app singleton by default) keyed by the caller's session +
/// call id. Implements the [ShellProgressSink] contract from
/// `shell_progress_parser.dart`.
class ShellProgressSinkImpl implements ShellProgressSink {
  final int sessionId;
  final String callId;
  final ShellProgressRegistry _registry;

  @override
  Map<String, dynamic>? summary;

  ShellProgressSinkImpl({
    required this.sessionId,
    required this.callId,
    ShellProgressRegistry? registry,
  }) : _registry = registry ?? ShellProgressRegistry.instance;

  @override
  void update(ShellProgress progress, {String? command}) {
    _registry.update(sessionId, callId, command ?? '', progress);
  }

  @override
  void finish({int? exitCode, Map<String, dynamic>? summary}) {
    this.summary = summary;
    _registry.finish(sessionId, callId, exitCode: exitCode);
  }
}

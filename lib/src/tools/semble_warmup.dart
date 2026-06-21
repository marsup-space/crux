import 'dart:async';
import 'dart:io';

import '../utils/bundled_executable.dart';

/// Background warmup for the `semble` binary.
///
/// `semble` is slow on cold start (model download once, then per-repo
/// index build on first search). The agent loop shouldn't make the
/// user wait at the splash screen for this, but the *first tool call*
/// must see a ready index — otherwise it stalls inside the agent's
/// think phase and looks like a hang.
///
/// Pattern: kick off [start] at boot (fire-and-forget) alongside the
/// splash; the tool's `execute()` calls [awaitReady] which blocks
/// until the warmup is done (or the warmup failed, in which case the
/// tool surfaces its own clean error).
///
/// Idempotent: repeated [start]/[awaitReady] calls are no-ops once
/// warmup is in flight or complete.
class SembleWarmup {
  SembleWarmup._();
  static final SembleWarmup instance = SembleWarmup._();

  Completer<void>? _ready;
  String? _path;

  /// True if a warmup is in flight.
  bool get isWarming {
    final c = _ready;
    return c != null && !c.isCompleted;
  }

  /// True if a warmup has finished (success or failure).
  bool get isReady {
    final c = _ready;
    return c != null && c.isCompleted;
  }

  /// Fire-and-forget. Starts warmup if not already started. Safe to
  /// call multiple times; later calls return the existing future.
  ///
  /// Warmup = run a no-op `semble search` against [path], which
  /// triggers model load + index build. The query content doesn't
  /// matter — even a junk string forces semble to materialize the
  /// cache for [path].
  ///
  /// Returns the warmup future so callers can choose: `unawaited(...)`
  /// to fire-and-forget at boot, or `await ...` to block on it.
  Future<void> start(String path) {
    if (_ready != null) return _ready!.future;
    _path = path;
    final completer = Completer<void>();
    _ready = completer;
    // Intentionally unawaited internally — callers decide.
    unawaited(_doWarmup(completer));
    return completer.future;
  }

  /// Await warmup completion. Starts it if not already started.
  /// Always completes, even on warmup failure (failures are silent
  /// so they don't poison the agent loop — the tool surfaces its
  /// own clean error when it actually tries to run).
  Future<void> awaitReady(String path) => start(path);

  /// Test seam: reset state. Not for production use.
  void debugReset() {
    _ready = null;
    _path = null;
    _refreshing = false;
  }

  // ── Cache refresh (post-edit) ────────────────────────────────────────

  bool _refreshing = false;

  /// Fire-and-forget cache refresh. Triggers a `semble search` against
  /// [path] which forces cache validation: files newer than the cache
  /// get re-indexed, unchanged files are skipped. Unchanged-file path
  /// is fast (just an mtime walk); changed-file path scales with how
  /// many files actually moved.
  ///
  /// Mirrors the existing git-status refresh pattern in the chat turn
  /// orchestrator: hook this after every tool round that mutated files,
  /// don't block, let concurrent calls collapse to one in-flight refresh.
  void refresh(String path) {
    if (_refreshing) return;
    _refreshing = true;
    unawaited(_doRefresh(path));
  }

  bool get isRefreshing => _refreshing;

  Future<void> _doRefresh(String path) async {
    try {
      final executable = await resolveBundledExecutable('semble');
      // Same junk-query trick as warmup: the query content is irrelevant;
      // the side effect (cache validation + selective re-index) is what we want.
      await Process.run(executable, [
        'search',
        '__semble_refresh__',
        path,
        '--top-k',
        '1',
      ]);
    } on Object {
      // Silent: same policy as warmup. Refresh failure must never
      // break the agent loop — the next real search will surface
      // its own clean error if the index is genuinely broken.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _doWarmup(Completer<void> completer) async {
    try {
      final executable = await resolveBundledExecutable('semble');
      final result = await Process.run(executable, [
        'search',
        '__semble_warmup__',
        _path!,
        '--top-k',
        '1',
      ]);
      // Both exit-0 (cache built) and non-zero (e.g. path vanished
      // mid-warmup) are treated as "warmup done, tool will sort it
      // out". We don't want a failed warmup to leave the tool
      // blocked forever.
      if (result.exitCode != 0) {
        // best-effort: nothing to do
      }
    } on Object {
      // Semble missing, ProcessException, etc. — same policy: don't
      // block the agent loop.
    } finally {
      if (!completer.isCompleted) completer.complete();
    }
  }
}
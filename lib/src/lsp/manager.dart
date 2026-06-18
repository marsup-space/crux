// LspManager — orchestrates one or more LspServerActors.
//
// The manager owns the public API the tools call. Internally it:
//   - Looks up the right actor(s) for a given file's extension
//   - Lazily spawns actor+process for each (serverId, root) pair
//   - Coalesces concurrent requests for the same pair
//   - Records failed starts in a broken-set with TTL
//   - Aggregates diagnostics across all matching servers and waits
//     for them (with timeout) before returning
//
// Phase 2.0: actors run in the manager's isolate (InProcessChannel).
// Phase 2.x: actors can run in their own isolates via IsolateChannel.
// The manager's API doesn't change either way.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'actor.dart';
import 'protocol.dart';

/// Map of `serverId` → factory that creates a fresh actor instance.
typedef LspActorFactory = LspServerActor Function();

/// Callback to check if a long-running operation has been cancelled.
/// Returns true if the caller should abort. Used in place of an
/// AbortSignal object to avoid name collision with
/// `package:crux/src/tools/tool_def.dart`'s `AbortSignal`.
typedef LspAbortCheck = bool Function();

/// Exception thrown when no LSP server is available for a file.
class LspNoServerAvailable implements Exception {
  final String path;
  final String reason;
  LspNoServerAvailable(this.path, this.reason);

  @override
  String toString() => 'LspNoServerAvailable($path): $reason';
}

/// Manages LSP server actors for one Crux session.
class LspManager {
  /// The Crux session's working directory. Used as the default root
  /// when resolving which project a file belongs to.
  final String workingDirectory;

  /// Available actor types, keyed by their `id`.
  final Map<String, LspActorFactory> _factories;

  /// Active slots, one per server type. Each slot wraps an actor and
  /// multiplexes its events into per-(serverId, root) streams.
  final Map<String, _Slot> _slots = {};

  /// Tracks (serverId, root) pairs that failed to start, so we don't
  /// retry every edit. Entries clear after [_brokenTtl].
  final Map<String, DateTime> _broken = {};
  static const _brokenTtl = Duration(seconds: 60);

  /// Coalesces concurrent _ensureSlot calls.
  final Map<String, Future<_Slot>> _starting = {};

  /// All incoming events, deduped across slots. Tools subscribe to
  /// filtered slices of this stream.
  final StreamController<LspEvent> _events =
      StreamController<LspEvent>.broadcast();

  /// Set when shutdown() has been called.
  bool _shutdown = false;

  LspManager({
    required this.workingDirectory,
    required Map<String, LspActorFactory> actorFactories,
  }) : _factories = actorFactories;

  /// Construct an [LspManager] and return it once all actor slots
  /// have been spawned and handshake-completed with the host.
  ///
  /// Phase 2.0: actors run in-process. `IsolateChannel` will be
  /// wired through here in Phase 2.x.
  static Future<LspManager> create({
    required String workingDirectory,
    required Map<String, LspActorFactory> actorFactories,
  }) async {
    final manager = LspManager(
      workingDirectory: workingDirectory,
      actorFactories: actorFactories,
    );
    // In-process: nothing to spawn. Slots are created on demand.
    return manager;
  }

  /// Subscribe to events filtered to [serverId]. The returned stream
  /// stays open until [shutdown] is called.
  Stream<LspEvent> eventsFor(String serverId) {
    return _events.stream.where((e) => e.serverId == serverId);
  }

  /// Find the actor type that handles [filePath]'s extension or
  /// basename. Returns the [LspServerActor.id] or null.
  String? _matchServerId(String filePath) {
    final ext = p.extension(filePath);
    final basename = p.basename(filePath);
    for (final factory in _factories.values) {
      // Cheap probe: construct an instance just to read its
      // extensions/bareFilenames. Could be optimized to a static
      // registry if factory calls become expensive.
      final probe = factory();
      if (probe.extensions.contains(ext)) return probe.id;
      if (probe.bareFilenames.contains(basename)) return probe.id;
    }
    return null;
  }

  /// Ensure the actor for [serverId] is alive. Returns the slot.
  Future<_Slot> _ensureSlot(String serverId) async {
    if (_shutdown) {
      throw StateError('LspManager is shut down');
    }
    final existing = _slots[serverId];
    if (existing != null) return existing;

    final inflight = _starting[serverId];
    if (inflight != null) return inflight;

    final factory = _factories[serverId];
    if (factory == null) {
      throw StateError('unknown LSP server id: $serverId');
    }

    final future = _spawnSlot(factory);
    _starting[serverId] = future;
    try {
      return await future;
    } finally {
      _starting.remove(serverId);
    }
  }

  Future<_Slot> _spawnSlot(LspActorFactory factory) async {
    final slot = _Slot._(factory: factory);
    _slots[slot.actor.id] = slot;
    slot.start();
    return slot;
  }

  /// Open [path] on every matching LSP server and wait up to [timeout]
  /// for at least one diagnostic batch per matching server.
  ///
  /// Returns the union of diagnostics for [path] across all matching
  /// servers. Empty if no servers matched, all failed to start, or the
  /// wait timed out.
  ///
  /// [isCancelled] is polled periodically to short-circuit the wait
  /// when the caller wants to abort. Pass a function that returns true
  /// if the work should stop, or null to disable.
  Future<List<LspDiagnostic>> touchFileAndWait(
    String filePath, {
    Duration timeout = const Duration(seconds: 5),
    LspAbortCheck? isCancelled,
  }) async {
    if (_shutdown) return const [];

    final serverId = _matchServerId(filePath);
    if (serverId == null) return const [];

    final root = _findRoot(filePath);
    if (root == null) return const [];
    if (_isBroken(serverId, root)) return const [];

    _evictBrokenEntries();

    final _Slot? slot;
    try {
      slot = await _ensureSlot(serverId);
    } catch (e) {
      // Slot spawn failed; record as broken so we don't keep trying.
      _markBroken(serverId, root);
      return const [];
    }

    final content = await File(filePath).readAsString();
    final normalizedPath = p.normalize(p.absolute(filePath));

    slot.send(LspCmdStart(root: root, file: filePath));
    slot.send(LspCmdOpenDocument(
      root: root,
      path: normalizedPath,
      content: content,
      version: 0,
    ));

    final completer = Completer<List<LspDiagnostic>>();
    final accumulator = <LspDiagnostic>[];
    var settled = false;

    StreamSubscription<LspEvent>? sub;
    Timer? timeoutTimer;

    void settle(List<LspDiagnostic> result) {
      if (settled) return;
      settled = true;
      timeoutTimer?.cancel();
      sub?.cancel();
      if (!completer.isCompleted) completer.complete(result);
    }

    sub = slot.events.listen((event) {
      if (event is LspEventStartFailed) {
        _markBroken(serverId, root);
        settle(const []);
        return;
      }
      if (event is LspEventDiagnostics) {
        if (p.normalize(event.batch.path) != normalizedPath) return;
        // Take the latest batch — drop earlier ones from the same push
        // cycle. We accumulate within one batch and replace across batches.
        accumulator
          ..clear()
          ..addAll(event.batch.diagnostics);
        // Settle after the debounce. For Phase 2.0 we settle
        // immediately on any diagnostic push, matching OpenCode's
        // "first push wins" for typescript's heavy initial flood.
        settle(List.unmodifiable(accumulator));
      }
      if (event is LspEventProcessExited) {
        // Server died during the wait — return what we have.
        settle(List.unmodifiable(accumulator));
      }
    });

    timeoutTimer = Timer(timeout, () {
      settle(List.unmodifiable(accumulator));
    });

    // Poll for cancellation at 100ms intervals. Coarse but cheap;
    // 100ms is well below user perception.
    Timer? cancelTimer;
    if (isCancelled != null) {
      cancelTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (isCancelled()) {
          settle(List.unmodifiable(accumulator));
          cancelTimer?.cancel();
        }
      });
      // Stop polling when the completer settles for any reason.
      completer.future.whenComplete(() => cancelTimer?.cancel());
    }

    return completer.future;
  }

  /// Open [filePath] on the matching LSP server without waiting
  /// for diagnostics. Returns immediately.
  ///
  /// Used by the `read` tool to warm the language server in the
  /// background. By the time the user later edits the file, the
  /// server has been initialized, the file opened, and the
  /// analysis is already done — so the edit's diagnostic
  /// collection is sub-second instead of the cold-start ~1s.
  ///
  /// Best-effort: any failure (no matching server, broken
  /// start, file unreadable) is swallowed. The next edit will
  /// retry via the normal [touchFileAndWait] path.
  Future<void> touchFileAndForget(String filePath) async {
    if (_shutdown) return;

    final serverId = _matchServerId(filePath);
    if (serverId == null) return;
    final root = _findRoot(filePath);
    if (root == null) return;
    if (_isBroken(serverId, root)) return;
    _evictBrokenEntries();

    final _Slot? slot;
    try {
      slot = await _ensureSlot(serverId);
    } catch (_) {
      return;
    }

    try {
      final content = await File(filePath).readAsString();
      final normalizedPath = p.normalize(p.absolute(filePath));
      slot.send(LspCmdStart(root: root, file: filePath));
      slot.send(LspCmdOpenDocument(
        root: root,
        path: normalizedPath,
        content: content,
        version: 0,
      ));
    } catch (_) {
      // Reading or sending failed silently; the next edit will retry.
    }
  }

  /// Resolve the project root for [filePath]. For Phase 2.0 we use the
  /// session's working directory as a flat root. Phase 2.1 will use
  /// each actor's own root detection via `resolveSpec`.
  String? _findRoot(String filePath) {
    final cwd = p.normalize(p.absolute(workingDirectory));
    final abs = p.normalize(p.absolute(filePath));
    if (!p.isWithin(cwd, abs) && abs != cwd) return null;
    return cwd;
  }

  bool _isBroken(String serverId, String root) {
    final key = '$serverId:$root';
    final ts = _broken[key];
    if (ts == null) return false;
    return DateTime.now().difference(ts) < _brokenTtl;
  }

  void _markBroken(String serverId, String root) {
    _broken['$serverId:$root'] = DateTime.now();
  }

  void _evictBrokenEntries() {
    final now = DateTime.now();
    _broken.removeWhere((_, ts) => now.difference(ts) >= _brokenTtl);
  }

  /// Shut down all slots and release resources.
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    for (final slot in _slots.values) {
      slot.shutdown();
    }
    await _events.close();
  }
}

/// Per-server-type slot. Wraps a single actor instance and exposes
/// its events as a stream filtered to this slot.
class _Slot {
  late final LspServerActor actor;
  final StreamController<LspEvent> _outbound =
      StreamController<LspEvent>.broadcast();

  _Slot._({required LspActorFactory factory}) {
    actor = factory();
    actor.attach(_onEvent);
  }

  Stream<LspEvent> get events => _outbound.stream;

  void start() {
    // Nothing to do in-process; actor is alive on construction.
  }

  void send(LspCommand cmd) {
    unawaited(actor.handle(cmd));
  }

  void _onEvent(LspEvent event) {
    if (!_outbound.isClosed) _outbound.add(event);
  }

  Future<void> shutdown() async {
    await actor.handle(const LspCmdShutdown());
    await _outbound.close();
  }
}

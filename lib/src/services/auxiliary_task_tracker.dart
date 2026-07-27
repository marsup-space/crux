import 'package:nocterm/nocterm.dart';

/// The kinds of background work routed through the auxiliary model.
/// Each kind carries the short verb the [AuxiliaryModelButton]
/// shows while at least one task of that kind is in flight
/// (`titling…`, `summarizing…`, …).
///
/// Adding a new auxiliary task = adding one enum value here and
/// passing it at the call site of `AuxiliaryService`. No UI or
/// controller wiring is needed — the tracker and button pick it
/// up automatically.
enum AuxiliaryTaskKind {
  /// Session-title generation (`New Session` → real title).
  title('titling'),

  /// `/tldr` summary of a long AI response.
  tldr('summarizing'),

  /// Pre-execution risk review of a suspicious shell command
  /// (layer 2 of the shell guardrail).
  shellRisk('assessing'),

  /// Runtime progress checks for a long-running shell process.
  shellMonitor('monitoring');

  const AuxiliaryTaskKind(this.verb);

  /// Short present-participle shown in the button label while a
  /// task of this kind is running (`$verb…`).
  final String verb;
}

/// App-wide registry of in-flight auxiliary-model tasks. A single
/// [instance] is shared by every [AuxiliaryService] (there are two
/// — one in [ChatService], one in [ChatTurnExecutor]) and read by
/// the UI's [AuxiliaryModelButton], so all aux work animates the
/// same indicator no matter which service issued it.
///
/// Instrumentation lives in the service layer — callers wrap their
/// work with [start] / [AuxTaskLease.end]:
///
/// ```dart
/// final lease = AuxiliaryTaskTracker.instance.start(AuxiliaryTaskKind.tldr);
/// try {
///   return await _streamAuxiliaryCall(...);
/// } finally {
///   lease.end();
/// }
/// ```
///
/// Concurrency model: tasks are counted, not boolean. Two
/// overlapping TLDR generations keep the tracker busy until BOTH
/// finish; the exposed [summary] reports the most recently started
/// kind plus the total count (`summarizing… +2`), so the indicator
/// never lies about how much work is in flight. Task starts are
/// remembered in a small FIFO so the label falls back to the next
/// pending kind when the displayed one completes.
class AuxiliaryTaskTracker extends ChangeNotifier {
  AuxiliaryTaskTracker._();
  static final AuxiliaryTaskTracker instance = AuxiliaryTaskTracker._();

  /// FIFO of task starts (capped — see [_kMaxPending]). The last
  /// element is the most recently started task; earlier entries
  /// are tasks still awaiting completion. Entries are removed on
  /// [AuxTaskLease.end]; a duplicate [end] is a no-op.
  final List<AuxiliaryTaskKind> _pending = [];

  /// Cap on [_pending] so a pathological caller that never ends
  /// its leases can't grow the list without bound. Well above any
  /// realistic concurrency (a handful of titles + tldrs + shell
  /// checks).
  static const int _kMaxPending = 64;

  /// Total number of in-flight tasks.
  int get activeCount => _pending.length;

  /// True while at least one auxiliary task is running. Drives the
  /// button's glossy sweep animation.
  bool get isBusy => _pending.isNotEmpty;

  /// The label summary for the busy state: the most recently
  /// started task's kind plus how many tasks are in flight in
  /// total. Null when idle.
  ({AuxiliaryTaskKind kind, int count})? get summary {
    if (_pending.isEmpty) return null;
    return (kind: _pending.last, count: _pending.length);
  }

  /// Mark a task of [kind] as started. The returned lease MUST be
  /// ended exactly once (use try/finally); a forgotten lease keeps
  /// the button spinning forever, a double-ended one corrupts the
  /// counts of unrelated tasks.
  AuxTaskLease start(AuxiliaryTaskKind kind) {
    // Evict the oldest entry when full — a stuck lease degrades the
    // label ("+N" too high) but must not leak memory.
    if (_pending.length >= _kMaxPending) _pending.removeAt(0);
    _pending.add(kind);
    notifyListeners();
    return AuxTaskLease._(this, kind);
  }

  void _end(AuxiliaryTaskKind kind) {
    // Remove the MOST RECENT matching entry. Tasks of the same kind
    // are indistinguishable, but pairing newest-first keeps the
    // ordering stable for the surviving entries.
    final idx = _pending.lastIndexOf(kind);
    if (idx < 0) return; // double-end / evicted — tolerate quietly
    _pending.removeAt(idx);
    notifyListeners();
  }

  /// Test hook: drop all state. Production tasks always end via
  /// their leases; this exists so tests can reset the singleton
  /// between cases.
  void reset() {
    if (_pending.isEmpty) return;
    _pending.clear();
    notifyListeners();
  }
}

/// Handle for one running auxiliary task. Create via
/// [AuxiliaryTaskTracker.start]; call [end] exactly once.
class AuxTaskLease {
  final AuxiliaryTaskTracker _owner;
  final AuxiliaryTaskKind _kind;
  bool _ended = false;

  AuxTaskLease._(this._owner, this._kind);

  /// Mark the task as finished. Idempotent — extra calls are
  /// ignored so an over-cautious `finally` can't corrupt the
  /// tracker's counts.
  void end() {
    if (_ended) return;
    _ended = true;
    _owner._end(_kind);
  }
}

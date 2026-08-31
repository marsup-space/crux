import '../models/session.dart';

/// Tab-cycle target kinds for the chat screen's Tab shortcut.
enum SessionCycleKind { active, done, interrupted }

/// One stop of the session cycle ring: which session to jump to.
class SessionCycleStop {
  final Session session;
  final SessionCycleKind kind;

  const SessionCycleStop(this.session, this.kind);
}

/// Build the ordered ring of session stops the Tab shortcut walks.
///
/// Sections in order, each newest-first by `updatedAt`:
///
///   1. every **active** session (idle / running / needUserAction) —
///      streaming conversations appear here while they run, so
///      repeated Tabs walk *between* live sessions;
///   2. every **done** session;
///   3. every **interrupted** session.
///
/// Candidates come from [sessions] + [chats] (workspace sessions and
/// global chats). Archived sessions are excluded: they are not in the
/// sidebar list to begin with. Every session appears at most once —
/// duplicate stops would break the wrap-around (it would land on the
/// copy instead of the first stop) or oscillate between two stops.
TabCycleRing buildTabCycleRing({
  required List<Session> sessions,
  List<Session> chats = const [],
}) {
  final candidates =
      [...sessions, ...chats].where((s) => s.archivedAt == null).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  final stops = <SessionCycleStop>[
    ...candidates
        .where(
          (s) =>
              s.status == SessionStatus.idle ||
              s.status == SessionStatus.running ||
              s.status == SessionStatus.needUserAction,
        )
        .map((s) => SessionCycleStop(s, SessionCycleKind.active)),
    ...candidates
        .where((s) => s.status == SessionStatus.done)
        .map((s) => SessionCycleStop(s, SessionCycleKind.done)),
    ...candidates
        .where((s) => s.status == SessionStatus.interrupted)
        .map((s) => SessionCycleStop(s, SessionCycleKind.interrupted)),
  ];
  return TabCycleRing(stops);
}

/// The ordered, de-duplicated stop ring plus the stepping math.
class TabCycleRing {
  final List<SessionCycleStop> stops;

  const TabCycleRing(this.stops);

  /// Step one stop [forward] (Tab) or backward (Shift+Tab = the
  /// previous session), wrapping at both ends of the ring.
  ///
  /// Stepping starts from the current session's own stop, so the ring
  /// must include it (buildTabCycleRing does not filter [currentId]).
  /// Returns null when there is nothing to move to — fewer than two
  /// distinct stops, or the current session has no stop and the ring
  /// devolves to a no-op.
  SessionCycleStop? step({required int currentId, bool forward = true}) {
    if (stops.length < 2) return null;
    final from = stops.indexWhere((s) => s.session.id == currentId);
    final len = stops.length;
    // from == -1 (current not in ring — e.g. archived mid-cycle):
    // forward enters at the first stop, backward at the last.
    final idx = forward ? (from + 1) % len : (from <= 0 ? len - 1 : from - 1);
    final next = stops[idx];
    if (next.session.id == currentId) return null;
    return next;
  }
}

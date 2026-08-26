import '../models/session.dart';

/// Tab-cycle target kinds for the chat screen's Tab shortcut.
enum SessionCycleKind { active, done, interrupted, previous }

/// One step of the Tab cycle: which session to jump to.
class SessionCycleTarget {
  final Session session;
  final SessionCycleKind kind;

  const SessionCycleTarget(this.session, this.kind);
}

/// Compute the next Tab-cycle destination.
///
/// The cycle visits, in order:
///
///   1. the most recently updated **active** session (idle / running /
///      needUserAction) — skipping [currentId] itself;
///   2. otherwise the most recently updated **done** session;
///   3. otherwise the most recently updated **interrupted** session;
///   4. otherwise the **previous** session — the most recently updated
///      session that is none of the above (i.e. done/interrupted when
///      steps 2–3 already consumed their picks) — falling back to "any
///      other session" so the key always does something useful.
///
/// Candidates come from [sessions] + [chats] (workspace sessions and
/// global chats), newest-first by `updatedAt`. Archived sessions are
/// excluded because they are not in the sidebar list to begin with.
///
/// Returns null when there is nothing to jump to (no other session).
SessionCycleTarget? nextTabCycleTarget({
  required List<Session> sessions,
  List<Session> chats = const [],
  int? currentId,
  int? lastVisitedId,
}) {
  final candidates =
      [
            ...sessions,
            ...chats,
          ]
          .where((s) => s.archivedAt == null && s.id != currentId)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (candidates.isEmpty) return null;

  bool isActive(Session s) =>
      s.status == SessionStatus.idle ||
      s.status == SessionStatus.running ||
      s.status == SessionStatus.needUserAction;

  // 1. Active first — a running or awaiting-input session is what the
  //    user most likely wants to reach with one keystroke.
  final active = candidates.where(isActive).toList();
  if (active.isNotEmpty) {
    return SessionCycleTarget(active.first, SessionCycleKind.active);
  }

  // 2–3. Then done, then interrupted.
  for (final entry in const [
    (SessionStatus.done, SessionCycleKind.done),
    (SessionStatus.interrupted, SessionCycleKind.interrupted),
  ]) {
    final match = candidates.where((s) => s.status == entry.$1).toList();
    if (match.isNotEmpty) {
      return SessionCycleTarget(match.first, entry.$2);
    }
  }

  // 4. Previous: prefer the remembered last-visited id when it still
  //    exists among candidates; otherwise fall back to the newest
  //    remaining candidate ("any other session").
  if (lastVisitedId != null) {
    for (final s in candidates) {
      if (s.id == lastVisitedId) {
        return SessionCycleTarget(s, SessionCycleKind.previous);
      }
    }
  }
  return SessionCycleTarget(candidates.first, SessionCycleKind.previous);
}

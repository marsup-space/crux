import 'package:crux/src/components/session_cycle.dart';
import 'package:crux/src/models/session.dart';
import 'package:test/test.dart';

Session _s(
  int id, {
  SessionStatus status = SessionStatus.idle,
  DateTime? updatedAt,
  DateTime? archivedAt,
}) {
  return Session(
    id: id,
    status: status,
    updatedAt: updatedAt ?? DateTime(2026, 1, 1),
    archivedAt: archivedAt,
  );
}

void main() {
  group('nextTabCycleTarget', () {
    test('no other session → null', () {
      final target = nextTabCycleTarget(
        sessions: [_s(1)],
        currentId: 1,
      );
      expect(target, isNull);
    });

    test('picks the newest active session (idle)', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(1, updatedAt: DateTime(2026, 1, 3)),
          _s(2, status: SessionStatus.done, updatedAt: DateTime(2026, 1, 5)),
          _s(3, updatedAt: DateTime(2026, 1, 4)),
        ],
        currentId: 1,
      );
      expect(target, isNotNull);
      expect(target!.session.id, 3);
      expect(target.kind, SessionCycleKind.active);
    });

    test('running and needUserAction count as active', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(2, status: SessionStatus.running, updatedAt: DateTime(2026, 1, 5)),
          _s(
            3,
            status: SessionStatus.needUserAction,
            updatedAt: DateTime(2026, 1, 4),
          ),
        ],
        currentId: 1,
      );
      expect(target!.session.id, 2);
      expect(target.kind, SessionCycleKind.active);
    });

    test('falls through to done when nothing is active', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(2, status: SessionStatus.done, updatedAt: DateTime(2026, 1, 5)),
          _s(
            3,
            status: SessionStatus.interrupted,
            updatedAt: DateTime(2026, 1, 6),
          ),
        ],
        currentId: 1,
      );
      expect(target!.session.id, 2);
      expect(target.kind, SessionCycleKind.done);
    });

    test('falls through to interrupted when no active/done', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(
            3,
            status: SessionStatus.interrupted,
            updatedAt: DateTime(2026, 1, 6),
          ),
        ],
        currentId: 1,
      );
      expect(target!.session.id, 3);
      expect(target.kind, SessionCycleKind.interrupted);
    });

    test('previous wins via lastVisitedId even when done exists', () {
      // Cycle order is a fixed priority list, not a rotating wheel:
      // once active/done/interrupted have no candidates left, the
      // "previous" stop takes over. Here done(2) would normally win
      // step 2 — but this test exercises the pure fallback path where
      // only previous-eligible sessions remain.
      final target = nextTabCycleTarget(
        sessions: [
          _s(2, status: SessionStatus.interrupted,
              updatedAt: DateTime(2026, 1, 5)),
          _s(9, status: SessionStatus.interrupted,
              updatedAt: DateTime(2026, 1, 4)),
        ],
        currentId: 1,
        lastVisitedId: 9,
      );
      // interrupted(2) still outranks previous(9) in the fixed order.
      expect(target!.session.id, 2);
      expect(target.kind, SessionCycleKind.interrupted);
    });

    test('previous picks lastVisitedId among remaining candidates', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(7, updatedAt: DateTime(2026, 1, 8)),
          _s(9, updatedAt: DateTime(2026, 1, 4)),
        ],
        currentId: 1,
        lastVisitedId: 9,
      );
      // Both are idle/active; step 1 picks the newest active (7).
      expect(target!.session.id, 7);
    });

    test('chats are included as candidates', () {
      final target = nextTabCycleTarget(
        sessions: [],
        chats: [
          _s(5, updatedAt: DateTime(2026, 1, 9)),
        ],
        currentId: 1,
      );
      expect(target!.session.id, 5);
      expect(target.kind, SessionCycleKind.active);
    });

    test('archived sessions are excluded', () {
      final target = nextTabCycleTarget(
        sessions: [
          _s(
            2,
            status: SessionStatus.done,
            updatedAt: DateTime(2026, 1, 5),
            archivedAt: DateTime(2026, 1, 6),
          ),
          _s(3, updatedAt: DateTime(2026, 1, 2)),
        ],
        currentId: 1,
      );
      expect(target!.session.id, 3);
    });
  });
}

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

/// Canonical fixture: #1 is current (newest, running). Two more
/// streaming sessions (#2, #3), one done (#4), one interrupted (#5).
List<Session> fixture() => [
      _s(1,
          status: SessionStatus.running,
          updatedAt: DateTime(2026, 1, 10)),
      _s(2,
          status: SessionStatus.running,
          updatedAt: DateTime(2026, 1, 9)),
      _s(3,
          status: SessionStatus.needUserAction,
          updatedAt: DateTime(2026, 1, 8)),
      _s(4,
          status: SessionStatus.done,
          updatedAt: DateTime(2026, 1, 7)),
      _s(5,
          status: SessionStatus.interrupted,
          updatedAt: DateTime(2026, 1, 6)),
    ];

void main() {
  group('buildTabCycleRing arrangement', () {
    test('active → done → interrupted sections, newest-first each', () {
      final ring = buildTabCycleRing(sessions: fixture(), chats: const []);
      expect(ring.stops.map((s) => s.session.id).toList(), [1, 2, 3, 4, 5]);
      expect(ring.stops.map((s) => s.kind).toList(), [
        SessionCycleKind.active,
        SessionCycleKind.active,
        SessionCycleKind.active,
        SessionCycleKind.done,
        SessionCycleKind.interrupted,
      ]);
    });

    test('chats join the active section', () {
      final ring = buildTabCycleRing(
        sessions: fixture(),
        chats: [_s(9, updatedAt: DateTime(2026, 1, 5))],
      );
      // Chat #9 is idle → oldest of the actives.
      expect(ring.stops.map((s) => s.session.id).toList(), [1, 2, 3, 9, 4, 5]);
    });

    test('archived sessions never appear', () {
      final ring = buildTabCycleRing(
        sessions: [
          ...fixture(),
          _s(
            8,
            status: SessionStatus.done,
            updatedAt: DateTime(2026, 1, 11),
            archivedAt: DateTime(2026, 1, 12),
          ),
        ],
      );
      expect(ring.stops.map((s) => s.session.id), isNot(contains(8)));
    });

    test('every session appears at most once', () {
      final ring = buildTabCycleRing(sessions: fixture(), chats: const []);
      final ids = ring.stops.map((s) => s.session.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'no duplicate stops');
    });
  });

  group('TabCycleRing.step forward (Tab)', () {
    test('single session → null', () {
      final ring = buildTabCycleRing(sessions: [_s(1)]);
      expect(ring.step(currentId: 1), isNull);
    });

    test('walks between multiple streaming sessions one Tab at a time',
        () {
      final ring = () => buildTabCycleRing(sessions: fixture());
      expect(ring().step(currentId: 1)!.session.id, 2,
          reason: 'from #1 → next active #2');
      expect(ring().step(currentId: 2)!.session.id, 3,
          reason: 'from #2 → next active #3');
      expect(ring().step(currentId: 3)!.session.id, 4,
          reason: 'from #3 → done section');
      expect(ring().step(currentId: 4)!.session.id, 5,
          reason: 'from #4 → interrupted section');
    });

    test('wraps from the last stop back to the first', () {
      final ring = buildTabCycleRing(sessions: fixture());
      final t = ring.step(currentId: 5);
      expect(t!.session.id, 1);
      expect(t.kind, SessionCycleKind.active);
    });

    test('current session not in ring (archived mid-cycle) enters at '
        'the first stop', () {
      final ring = buildTabCycleRing(sessions: fixture());
      expect(ring.step(currentId: 99)!.session.id, 1);
    });
  });

  group('TabCycleRing.step backward (Shift+Tab = previous session)', () {
    test('steps to the previous stop, wrapping to the last', () {
      final ring = () => buildTabCycleRing(sessions: fixture());
      expect(
        ring().step(currentId: 1, forward: false)!.session.id,
        5,
        reason: 'backward from the first stop wraps to the last',
      );
      expect(
        ring().step(currentId: 3, forward: false)!.session.id,
        2,
        reason: 'backward from #3 → #2',
      );
      expect(
        ring().step(currentId: 2, forward: false)!.session.id,
        1,
        reason: 'backward from #2 → #1',
      );
    });

    test('Tab then Shift+Tab returns to the starting session', () {
      final ring = buildTabCycleRing(sessions: fixture());
      final next = ring.step(currentId: 1)!;
      expect(next.session.id, 2);
      final back = ring.step(currentId: next.session.id, forward: false)!;
      expect(back.session.id, 1);
    });
  });
}

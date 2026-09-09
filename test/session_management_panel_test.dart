import 'package:crux/src/components/session_management_panel.dart';
import 'package:crux/src/models/session.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

Session _session(
  int id, {
  String title = '',
  bool archived = false,
  bool chat = false,
  String model = 'prov/model-a',
}) {
  final now = DateTime.now();
  return Session(
    id: id,
    title: title,
    model: model,
    status: SessionStatus.idle,
    kind: chat ? 'chat' : null,
    archivedAt: archived ? now : null,
    createdAt: now,
    updatedAt: now,
  );
}

/// Shared harness: renders the panel with one active + one archived
/// session and a loader handing back the full snapshot. Returns the
/// opened/switched id recorders for assertions.
Future<(List<int>, List<int>)> _pumpPanel(NoctermTester tester) async {
  final opened = <int>[];
  final switched = <int>[];
  await tester.pumpComponent(
    Container(
      width: 80,
      height: 20,
      child: SessionManagementPanel(
        sessions: [_session(1, title: 'Active one')],
        chats: const [],
        onLoadCandidates: () async => [
          _session(1, title: 'Active one'),
          _session(2, title: 'Old thing', archived: true),
        ],
        currentSessionId: 1,
        onOpenSession: (id) async {
          opened.add(id);
          return null;
        },
        onDeleteSession: (_) async {},
        onRenameSession: (_, _) async {},
        onSwitchSession: switched.add,
        onDismiss: () {},
      ),
    ),
  );
  // Let the async candidates loader in initState complete and the
  // post-load setState paint (microtask flush + frame).
  await tester.pump();
  await tester.pump();
  return (opened, switched);
}

void main() {
  group('SessionManagementPanel search + archived', () {
    test('archived rows render in an Archived section', () async {
      await testNocterm('archived section', (tester) async {
        await _pumpPanel(tester);

        expect(tester.terminalState, containsText('Active one'));
        expect(tester.terminalState, containsText('Old thing'));
        expect(tester.terminalState, containsText('Archived'));
      });
    });

    test('typing enters search mode and filters to the archived row', () async {
      await testNocterm('search matches archived', (tester) async {
        await _pumpPanel(tester);

        await tester.enterText('Old');
        await tester.pump();

        // Case-insensitive title match keeps only the archived row.
        expect(tester.terminalState, containsText('Old thing'));
        expect(tester.terminalState, isNot(containsText('Active one')));
      });
    });

    test(
      'enter on the filtered archived row opens via onOpenSession',
      () async {
        await testNocterm('field owns keys', (tester) async {
          final (opened, switched) = await _pumpPanel(tester);

          await tester.enterText('old');
          await tester.pump();

          // Filtered to the one matching row; Enter resolves through
          // the field's interceptor to onOpenSession (archived-aware).
          await tester.sendKey(LogicalKey.enter);
          await tester.pump();
          expect(opened, [2]);
          expect(switched.length, 0);
        });
      },
    );

    test('#id search finds an archived session by number', () async {
      await testNocterm('hash id search', (tester) async {
        final opened = <int>[];
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 20,
            child: SessionManagementPanel(
              sessions: [_session(11, title: 'Active one')],
              onLoadCandidates: () async => [
                _session(11, title: 'Active one'),
                _session(23, title: 'Old thing', archived: true),
              ],
              currentSessionId: 11,
              onOpenSession: (id) async {
                opened.add(id);
                return null;
              },
              onDeleteSession: (_) async {},
              onRenameSession: (_, _) async {},
              onSwitchSession: (_) {},
              onDismiss: () {},
            ),
          ),
        );

        await tester.enterText('#23');
        await tester.pump();
        expect(tester.terminalState, containsText('Old thing'));
        expect(tester.terminalState, isNot(containsText('Active one')));

        await tester.sendKey(LogicalKey.enter);
        await tester.pump();
        expect(opened, [23]);
      });
    });
  });
}

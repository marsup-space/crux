import 'package:crux/src/components/extra_info_panel.dart';
import 'package:crux/src/components/session_management_panel.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/utils/terminal_symbols.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('session status SSoT', () {
    test('sidebar row ignores stale runtime activity', () async {
      await testNocterm('sidebar status ssot', (tester) async {
        final session = Session(
          id: 1,
          title: 'Stopped Session',
          model: 'test/model',
          status: SessionStatus.idle,
        );
        // A throwaway service so the panel renders. We never start
        // the timer — the service's default snapshot has
        // `isRepo: false`, and the panel collapses the widget to
        // zero height in that case.
        final git = GitStatusService();

        await tester.pumpComponent(
          Container(
            width: 40,
            height: 8,
            child: ExtraInfoPanel(
              sessions: [session],
              currentSessionId: session.id,
              onSwitchSession: (_) {},
              archivedCount: 0,
              gitStatusService: git,
            ),
          ),
        );

        final matches = tester.terminalState.findText('Stopped Session');
        expect(matches.isNotEmpty, isTrue);
        final row = matches.first;
        expect(
          tester.terminalState.getTextAt(row.x - 2, row.y, length: 1),
          terminalSymbol('·', '.'),
        );
      });
    });

    test('manager row uses session status directly', () async {
      await testNocterm('manager status ssot', (tester) async {
        final session = Session(
          id: 1,
          title: 'Stopped Session',
          model: 'test/model',
          status: SessionStatus.idle,
        );

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 16,
            child: SessionManagementPanel(
              sessions: [session],
              currentSessionId: session.id,
              onDeleteSession: (_) async {},
              onRenameSession: (_, _) async {},
              onSwitchSession: (_) {},
              onDismiss: () {},
            ),
          ),
        );

        final matches = tester.terminalState.findText('Stopped Session');
        expect(matches.isNotEmpty, isTrue);
        final row = matches.first;
        expect(
          tester.terminalState.getTextAt(row.x - 4, row.y, length: 1),
          terminalSymbol('·', '.'),
        );
      });
    });
  });
}

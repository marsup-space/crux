import 'package:crux/src/components/extra_info_panel.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/plugin.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/utils/terminal_symbols.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

class _FakeGit extends GitStatusService {
  @override
  GitStatus get current => GitStatus.empty;
}

Session _session(int id) => Session(
  id: id,
  title: 'session-$id',
  model: 'test/model',
  status: SessionStatus.idle,
);

Session _chat(int id) => Session(
  id: id,
  title: 'chat-$id',
  model: 'test/model',
  status: SessionStatus.idle,
  kind: 'chat',
);

ExtraInfoPanel _panel(
  List<Session> sessions, {
  List<Session> chats = const [],
  List<Plugin>? plugins,
  int archivedCount = 0,
  int archivedChatCount = 0,
}) => ExtraInfoPanel(
  sessions: sessions,
  chats: chats,
  currentSessionId: sessions.first.id,
  onSwitchSession: (_) {},
  archivedCount: archivedCount,
  archivedChatCount: archivedChatCount,
  gitStatusService: _FakeGit(),
  plugins: plugins,
);

void main() {
  test(
    'short sidebar uses the first row and renders all content naturally',
    () {
      return testNocterm('short unified sidebar', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 40,
            height: 12,
            child: _panel(
              [_session(1)],
              plugins: const [
                Plugin(
                  id: 'bottom-plugin',
                  title: 'Bottom plugin',
                  labelTemplate: '{state}',
                  refresh: Duration(seconds: 30),
                  statusPath: '.crux/test-missing-status.json',
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('Sessions').single.y, 0);
        expect(tester.terminalState.containsText('project'), isTrue);
        final sessionY = tester.terminalState.findText('session-1').first.y;
        final pluginY = tester.terminalState.findText('Bottom plugin').first.y;
        expect(
          pluginY,
          greaterThan(sessionY + 5),
          reason: 'short content should leave flexible space before plugins',
        );
        expect(
          tester.terminalState.containsText(terminalSymbol('▲', '^')),
          isFalse,
        );
        expect(
          tester.terminalState.containsText(terminalSymbol('▼', 'v')),
          isFalse,
        );
      });
    },
  );

  test('overflow indicators follow the unified sidebar scroll position', () {
    return testNocterm('sidebar edge indicators', (tester) async {
      final sessions = [for (var i = 1; i <= 40; i++) _session(i)];
      await tester.pumpComponent(
        Container(width: 40, height: 10, child: _panel(sessions)),
      );
      await tester.pump();

      expect(
        tester.terminalState.containsText(terminalSymbol('▲', '^')),
        isFalse,
      );
      expect(
        tester.terminalState.containsText(terminalSymbol('▼', 'v')),
        isTrue,
      );

      await tester.sendMouseEvent(
        const MouseEvent(
          button: MouseButton.wheelDown,
          x: 10,
          y: 5,
          pressed: false,
        ),
      );
      expect(
        tester.terminalState.containsText(terminalSymbol('▲', '^')),
        isTrue,
      );

      for (var i = 0; i < 20; i++) {
        await tester.sendMouseEvent(
          const MouseEvent(
            button: MouseButton.wheelDown,
            x: 10,
            y: 5,
            pressed: false,
          ),
        );
      }

      expect(
        tester.terminalState.containsText(terminalSymbol('▲', '^')),
        isTrue,
      );
      expect(
        tester.terminalState.containsText(terminalSymbol('▼', 'v')),
        isFalse,
      );
      expect(tester.terminalState.containsText('project'), isTrue);
    });
  });

  test('session and chat archive counts are centered muted text', () {
    return testNocterm('centered archive counts', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: _panel(
            [_session(1)],
            chats: [_chat(2)],
            archivedCount: 3,
            archivedChatCount: 7,
          ),
        ),
      );

      expect(tester.terminalState.containsText('/unarchive'), isFalse);
      for (final label in ['3 archived', '7 archived']) {
        final match = tester.terminalState.findText(label).single;
        final center = match.x + label.length / 2;
        expect(center, closeTo(tester.terminalState.size.width / 2, 1));
        expect(
          tester.terminalState.getCellAt(match.x, match.y)!.style.color,
          CruxThemeData.draculaFallback.textMuted,
        );
      }
    });
  });
}

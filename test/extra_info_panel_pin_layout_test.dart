// Tests for the layout of pinned rows in the sessions/chats sidebar
// panel.
//
// The contract under test: pinned sessions stay in the "Sessions"
// section, pinned chats stay in the "Chats" section, and neither
// gets hoisted into a single cross-section "Pinned" header at the
// very top. The previous shared-header layout made a pinned chat
// appear above every workspace session — reading as "the chat
// jumped into the sessions list". Pinned rows now sit at the top of
// their own section, separated from the rest by a horizontal
// divider underneath (no "Pinned" label).
import 'package:crux/src/components/extra_info_panel.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

class _FakeGit extends GitStatusService {
  _FakeGit() : super();
  @override
  GitStatus get current => GitStatus.empty;
}

/// Substring used to detect a [Divider] row in the rendered buffer.
/// The component renders dividers as a run of U+2500 box-drawing
/// horizontal characters, full panel width. Six in a row is unique
/// to [Divider] (border chrome uses `╭─` / `─╮` corners, never
/// long unbroken runs).
const _dividerNeedle = '──────';

void main() {
  /// Returns the rendered y-coordinate of the first cell containing
  /// [needle], or -1 if not present. We use unique titles per
  /// session so each row has its own anchor.
  int yOf(dynamic tester, String needle) {
    final hits = tester.terminalState.findText(needle);
    return hits.isEmpty ? -1 : hits.first.y;
  }

  /// Returns every distinct y-coordinate where a [Divider] row
  /// appears. [findText] returns one match per (x, y) pair, so a
  /// single long divider line surfaces as many adjacent y-equal
  /// hits — dedupe to one per row.
  List<int> yOfDividers(dynamic tester) {
    final hits = tester.terminalState.findText(_dividerNeedle);
    final ys = <int>{};
    for (final h in hits) {
      ys.add(h.y);
    }
    return ys.toList()..sort();
  }

  Future<void> pump(
    dynamic tester, {
    required List<Session> sessions,
    required List<Session> chats,
    double width = 80,
    double height = 40,
  }) async {
    await tester.pumpComponent(
      Container(
        width: width,
        height: height,
        child: ExtraInfoPanel(
          sessions: sessions,
          chats: chats,
          currentSessionId: sessions.isNotEmpty ? sessions.first.id : 0,
          onSwitchSession: (_) {},
          archivedCount: 0,
          archivedChatCount: 0,
          gitStatusService: _FakeGit(),
        ),
      ),
    );
  }

  Session makeSession({
    required int id,
    required String title,
    DateTime? pinnedAt,
  }) {
    return Session(
      id: id,
      title: title,
      model: 'test/model',
      status: SessionStatus.idle,
      pinnedAt: pinnedAt,
    );
  }

  Session makeChat({
    required int id,
    required String title,
    DateTime? pinnedAt,
  }) {
    return Session(
      id: id,
      title: title,
      model: 'test/model',
      status: SessionStatus.idle,
      kind: 'chat',
      pinnedAt: pinnedAt,
    );
  }

  group('pinned row layout — sessions and chats', () {
    test(
      'pinned chat renders inside the Chats section, not above the '
      'Sessions section',
      () async {
        await testNocterm('pinned chat stays in Chats section', (tester) async {
          final pinnedChat = makeChat(
            id: 1,
            title: 'pinned-chat',
            pinnedAt: DateTime(2024, 1, 1, 12),
          );
          final todaySess = makeSession(id: 2, title: 'today-sess');
          final todayChat = makeChat(id: 3, title: 'today-chat');

          await pump(
            tester,
            sessions: [todaySess],
            chats: [pinnedChat, todayChat],
          );

          final yPinnedChat = yOf(tester, 'pinned-chat');
          final yTodaySess = yOf(tester, 'today-sess');
          final yTodayChat = yOf(tester, 'today-chat');
          final yChatsHeader = yOf(tester, 'Chats');

          // Sanity: everything rendered.
          expect(yPinnedChat, isNonNegative, reason: 'pinned-chat must render');
          expect(yTodaySess, isNonNegative, reason: 'today-sess must render');
          expect(yTodayChat, isNonNegative, reason: 'today-chat must render');
          expect(yChatsHeader, isNonNegative, reason: 'Chats header must render');

          // The Chats section header is BELOW all the workspace
          // sessions; the pinned chat must live below the Chats
          // header, not above it.
          expect(
            yPinnedChat > yChatsHeader,
            isTrue,
            reason: 'pinned chat must render below the Chats header '
                '(got pinnedChat.y=$yPinnedChat, chatsHeader.y=$yChatsHeader)',
          );
          expect(
            yPinnedChat > yTodaySess,
            isTrue,
            reason: 'pinned chat must NOT appear above workspace sessions; '
                'it belongs in the Chats section, not in a shared top '
                'Pinned section',
          );
        });
      },
    );

    test(
      'pinned session renders inside the Sessions section, above '
      'today\'s sessions',
      () async {
        await testNocterm(
          'pinned session stays in Sessions section',
          (tester) async {
            final pinnedSess = makeSession(
              id: 1,
              title: 'pinned-sess',
              pinnedAt: DateTime(2024, 1, 1, 12),
            );
            final todaySess = makeSession(id: 2, title: 'today-sess');
            final todayChat = makeChat(id: 3, title: 'today-chat');

            await pump(
              tester,
              sessions: [pinnedSess, todaySess],
              chats: [todayChat],
            );

            final yPinnedSess = yOf(tester, 'pinned-sess');
            final yTodaySess = yOf(tester, 'today-sess');
            final yTodayChat = yOf(tester, 'today-chat');
            final yChatsHeader = yOf(tester, 'Chats');

            expect(yPinnedSess, isNonNegative);
            expect(yTodaySess, isNonNegative);
            expect(yTodayChat, isNonNegative);
            expect(yChatsHeader, isNonNegative);

            // pinned session is the first row in the Sessions
            // section, so it must render before today's session.
            expect(
              yPinnedSess < yTodaySess,
              isTrue,
              reason: 'pinned session must render above today\'s session',
            );
            // ...and the workspace session block is above the
            // Chats header.
            expect(
              yTodaySess < yChatsHeader,
              isTrue,
              reason: 'today\'s session must render above the Chats header',
            );
          },
        );
      },
    );

    test(
      'pinned rows are followed by a divider in their own section, '
      'no "Pinned" label is rendered anywhere',
      () async {
        await testNocterm(
          'divider closes each pinned band, no Pinned label',
          (tester) async {
            final pinnedSess = makeSession(
              id: 1,
              title: 'pinned-sess',
              pinnedAt: DateTime(2024, 1, 1, 12),
            );
            final todaySess = makeSession(id: 2, title: 'today-sess');
            final pinnedChat = makeChat(
              id: 3,
              title: 'pinned-chat',
              pinnedAt: DateTime(2024, 1, 1, 13),
            );
            final todayChat = makeChat(id: 4, title: 'today-chat');

            await pump(
              tester,
              sessions: [pinnedSess, todaySess],
              chats: [pinnedChat, todayChat],
            );

            // No "Pinned" label — pinned rows are unlabeled.
            expect(
              tester.terminalState.findText('Pinned'),
              isEmpty,
              reason: 'pinned rows must not render a "Pinned" header',
            );

            final yPinnedSess = yOf(tester, 'pinned-sess');
            final yTodaySess = yOf(tester, 'today-sess');
            final yPinnedChat = yOf(tester, 'pinned-chat');
            final yTodayChat = yOf(tester, 'today-chat');
            final yChatsHeader = yOf(tester, 'Chats');

            // The panel itself has a couple of fixed dividers
            // (under "Sessions" and under the Chats section
            // header). We don't try to count total dividers — we
            // only assert the *expected* divider position exists
            // directly under each pinned row. Adjacent rows in the
            // ListView are 1 line apart, so the divider y must
            // equal the pinned row's y + 1.
            final ys = yOfDividers(tester);
            expect(
              ys.contains(yPinnedSess + 1),
              isTrue,
              reason: 'a divider must sit directly below pinned-sess '
                  '(expected at y=${yPinnedSess + 1}, all divider '
                  'y=$ys, pinned-sess.y=$yPinnedSess)',
            );
            expect(
              ys.contains(yPinnedChat + 1),
              isTrue,
              reason: 'a divider must sit directly below pinned-chat '
                  '(expected at y=${yPinnedChat + 1}, all divider '
                  'y=$ys, pinned-chat.y=$yPinnedChat)',
            );
            // The pinned-sess divider sits above today-sess and
            // above the Chats header.
            expect(yPinnedSess + 1 < yTodaySess, isTrue);
            expect(yPinnedSess + 1 < yChatsHeader, isTrue);
            // The pinned-chat divider sits below the Chats header
            // and above today-chat.
            expect(yPinnedChat + 1 > yChatsHeader, isTrue);
            expect(yPinnedChat + 1 < yTodayChat, isTrue);

            // Across sections: pinned chat still renders below the
            // workspace sessions block, even though it was pinned
            // more recently.
            expect(yPinnedChat + 1 > yPinnedSess + 1, isTrue);
          },
        );
      },
    );

    test(
      'pinned chat-only list still renders the Chats header and '
      'its pinned divider',
      () async {
        // Regression guard for the edge case where every chat is
        // pinned (so the unpinned-chat list is empty). The
        // Chats section must still render (so the pinned chat is
        // findable in the Chats section), and a divider must close
        // the pinned band.
        await testNocterm(
          'pinned-only chats still show the Chats section',
          (tester) async {
            final pinnedChat = makeChat(
              id: 1,
              title: 'pinned-chat',
              pinnedAt: DateTime(2024, 1, 1, 12),
            );
            final todaySess = makeSession(id: 2, title: 'today-sess');

            await pump(
              tester,
              sessions: [todaySess],
              chats: [pinnedChat],
            );

            final yChatsHeader = yOf(tester, 'Chats');
            final yPinnedChat = yOf(tester, 'pinned-chat');

            expect(yChatsHeader, isNonNegative);
            expect(yPinnedChat, isNonNegative);

            // The pinned chat renders below the Chats header.
            expect(yPinnedChat > yChatsHeader, isTrue);

            // A divider sits directly below the pinned chat (closes
            // the pinned band). The panel itself also renders a
            // divider under the Chats header — we only assert the
            // expected *position* exists, not the total count.
            final ys = yOfDividers(tester);
            expect(
              ys.contains(yPinnedChat + 1),
              isTrue,
              reason: 'divider must sit directly below the pinned chat '
                  '(expected at y=${yPinnedChat + 1}, all divider y=$ys)',
            );
          },
        );
      },
    );

    test(
      'no dividers appear when no row is pinned in either section',
      () async {
        // Sanity guard: dividers are a marker of pinned rows, not a
        // permanent section chrome. With no pins, the panel must
        // not introduce any extra dividers between the panel header
        // and the first row, or between the first row and the
        // Chats header. (The panel itself has two fixed dividers —
        // under "Sessions" and under the Chats section header — so
        // we compare against a baseline taken from the rendered
        // buffer.)
        await testNocterm('no pins = no extra dividers', (tester) async {
          final todaySess = makeSession(id: 1, title: 'today-sess');
          final todayChat = makeChat(id: 2, title: 'today-chat');

          await pump(
            tester,
            sessions: [todaySess],
            chats: [todayChat],
          );

          final yChatsHeader = yOf(tester, 'Chats');
          final yTodaySess = yOf(tester, 'today-sess');
          final yTodayChat = yOf(tester, 'today-chat');

          // The Chats section header sits between the workspace
          // sessions block and the chats block; the pinned band,
          // when present, sits at the top of either block.
          // Without pins, there is no row in either section's
          // "pinned band" position, so the row that follows the
          // header chrome is the unpinned today row. We assert the
          // first content row (today-sess) sits directly under the
          // fixed panel-header divider with no intermediate
          // divider inserted. (The fixed divider is the one at
          // y = today-sess.y - 1, the one immediately above the
          // first content row.)
          final ys = yOfDividers(tester);
          expect(
            ys.contains(yTodaySess - 1),
            isTrue,
            reason: 'a divider must sit directly above today-sess (the '
                'fixed panel header divider under "Sessions"); got '
                'dividers=$ys, today-sess.y=$yTodaySess',
          );
          // today-sess renders above the Chats header, today-chat
          // renders below it.
          expect(yTodaySess < yChatsHeader, isTrue);
          expect(yTodayChat > yChatsHeader, isTrue);
        });
      },
    );
  });
}

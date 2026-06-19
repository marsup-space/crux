// Tests for the project widget's idle label — the `path:branch
// ↑N ↓M` text shown by [ExtraInfoPanel]. This is the user's
// "how many commits have I not pushed / not pulled" glance,
// so the format is locked down here.
import 'package:crux/src/components/extra_info_panel.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/utils/terminal_symbols.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// A [GitStatusService] that lets a test pre-load any snapshot
/// via [seedCurrent] without spawning a real `git` subprocess.
class _FakeGit extends GitStatusService {
  _FakeGit() : super();

  GitStatus _snapshot = GitStatus.empty;

  void seedCurrent(GitStatus next) {
    _snapshot = next;
    notifyListeners();
  }

  @override
  GitStatus get current => _snapshot;
}

void main() {
  /// The panel pulls the project path from `Directory.current`,
  /// which we can't redirect from a test. We pass the session
  /// list / id, plus the fake git service, and then look up the
  /// rendered text via [tester.terminalState.findText]. The
  /// assertions are intentionally agnostic to the exact cwd —
  /// we only care about the *suffix* after `:` (the
  /// `:branch ↑N ↓M` part) and about the absence / presence of
  /// the arrow glyphs.
  Future<void> pump(
    dynamic tester, {
    required GitStatus git,
    double width = 80,
  }) async {
    final session = Session(
      id: 1,
      title: 's',
      model: 'test/model',
      status: SessionStatus.idle,
    );
    final svc = _FakeGit()..seedCurrent(git);
    await tester.pumpComponent(
      Container(
        width: width,
        height: 16,
        child: ExtraInfoPanel(
          sessions: [session],
          currentSessionId: session.id,
          onSwitchSession: (_) {},
          archivedCount: 0,
          gitStatusService: svc,
        ),
      ),
    );
  }

  group('project widget — sync arrows', () {
    test('clean sync shows path:branch with no arrows', () async {
      await testNocterm('project widget in-sync', (tester) async {
        await pump(
          tester,
          git: GitStatus(
            isRepo: true,
            branch: 'master',
            ahead: 0,
            behind: 0,
            fetchedAt: DateTime(2024, 1, 1),
          ),
        );
        // Branch visible.
        expect(tester.terminalState.findText('master'), isNotEmpty);
        // No arrows because ahead/behind are both zero.
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isFalse,
        );
        expect(
          tester.terminalState.findText('↓').isNotEmpty ||
              tester.terminalState.findText('v').isNotEmpty,
          isFalse,
        );
      });
    });

    test('ahead commits render as `↑N`', () async {
      await testNocterm('project widget ahead', (tester) async {
        await pump(
          tester,
          git: GitStatus(
            isRepo: true,
            branch: 'feature',
            ahead: 3,
            behind: 0,
            fetchedAt: DateTime(2024, 1, 1),
          ),
        );
        // Branch visible.
        expect(tester.terminalState.findText('feature'), isNotEmpty);
        // Up-arrow present.
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isTrue,
        );
        // Count next to the arrow.
        expect(tester.terminalState.findText('3'), isNotEmpty);
        // No down-arrow (behind = 0).
        expect(
          tester.terminalState.findText('↓').isNotEmpty ||
              tester.terminalState.findText('v').isNotEmpty,
          isFalse,
        );
      });
    });

    test('behind commits render as `↓N`', () async {
      await testNocterm('project widget behind', (tester) async {
        await pump(
          tester,
          git: GitStatus(
            isRepo: true,
            branch: 'feature',
            ahead: 0,
            behind: 2,
            fetchedAt: DateTime(2024, 1, 1),
          ),
        );
        expect(tester.terminalState.findText('feature'), isNotEmpty);
        expect(
          tester.terminalState.findText('↓').isNotEmpty ||
              tester.terminalState.findText('v').isNotEmpty,
          isTrue,
        );
        expect(tester.terminalState.findText('2'), isNotEmpty);
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isFalse,
        );
      });
    });

    test('both ahead and behind render in order ↑N ↓M', () async {
      await testNocterm('project widget both', (tester) async {
        await pump(
          tester,
          git: GitStatus(
            isRepo: true,
            branch: 'main',
            ahead: 3,
            behind: 2,
            fetchedAt: DateTime(2024, 1, 1),
          ),
        );
        // Both arrows present.
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isTrue,
        );
        expect(
          tester.terminalState.findText('↓').isNotEmpty ||
              tester.terminalState.findText('v').isNotEmpty,
          isTrue,
        );
        // Both counts present.
        expect(tester.terminalState.findText('3'), isNotEmpty);
        expect(tester.terminalState.findText('2'), isNotEmpty);

        // And specifically — ↑3 appears BEFORE ↓2 in the rendered
        // text. We assert this by scanning the rendered buffer
        // for the column positions of each glyph and confirming
        // ↑3 is to the left of ↓2 (push indicator always renders
        // first in the project widget).
        final upArrow =
            tester.terminalState
                .findText(terminalSymbol('↑', '^'))
                .firstOrNull ??
            tester.terminalState.findText('↑').firstOrNull;
        final downArrow =
            tester.terminalState
                .findText(terminalSymbol('↓', 'v'))
                .firstOrNull ??
            tester.terminalState.findText('↓').firstOrNull;
        expect(upArrow, isNotNull);
        expect(downArrow, isNotNull);
        expect(
          upArrow!.x < downArrow!.x ||
              (upArrow.x == downArrow.x && upArrow.y <= downArrow.y),
          isTrue,
          reason: 'push indicator (↑) should render before pull (↓)',
        );
      });
    });

    test('non-repo project shows just the path, no branch suffix', () async {
      await testNocterm('project widget not a repo', (tester) async {
        await pump(tester, git: GitStatus.empty);
        // When [GitStatus.isRepo] is false, the project widget
        // must fall back to showing just the path with no
        // `:branch` suffix and no arrows.
        expect(tester.terminalState.findText(':'), isEmpty);
      });
    });

    test('path:branch reflects a fresh snapshot without a rebuild', () async {
      // Simulates a project switch: a fresh `GitStatus` snapshot
      // arrives with a different branch and different counts, and
      // the project widget label updates in lock-step without
      // the caller touching anything else.
      await testNocterm('project widget reactive', (tester) async {
        final svc = _FakeGit()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'old',
              ahead: 0,
              behind: 0,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        final session = Session(
          id: 1,
          title: 's',
          model: 'test/model',
          status: SessionStatus.idle,
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 16,
            child: ExtraInfoPanel(
              sessions: [session],
              currentSessionId: session.id,
              onSwitchSession: (_) {},
              archivedCount: 0,
              gitStatusService: svc,
            ),
          ),
        );
        expect(tester.terminalState.findText('old'), isNotEmpty);
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isFalse,
        );

        // Switch projects — new branch with pending sync.
        svc.seedCurrent(
          GitStatus(
            isRepo: true,
            branch: 'new',
            ahead: 7,
            behind: 4,
            fetchedAt: DateTime(2024, 1, 2),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('new'), isNotEmpty);
        expect(tester.terminalState.findText('old'), isEmpty);
        expect(tester.terminalState.findText('7'), isNotEmpty);
        expect(tester.terminalState.findText('4'), isNotEmpty);
        expect(
          tester.terminalState.findText('↑').isNotEmpty ||
              tester.terminalState.findText('^').isNotEmpty,
          isTrue,
        );
        expect(
          tester.terminalState.findText('↓').isNotEmpty ||
              tester.terminalState.findText('v').isNotEmpty,
          isTrue,
        );
      });
    });
  });
}

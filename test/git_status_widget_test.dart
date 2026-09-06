// Tests for [GitStatusWidget] — the visual surface above the
// project widget in the right-hand side panel.
//
// Drives the widget with a fake [GitStatusService] that never
// spawns `git` and lets the test pre-load any snapshot via
// [seedCurrent]. The widget subscribes to the service via
// [ChangeNotifier] and re-renders on every notification;
// tests verify the rendered terminal contents.
//
// Note: the branch name + sync arrows intentionally live on
// the project widget, NOT on this widget — the widget focuses
// on file-level state (line diff + per-bucket counts).
import 'package:crux/src/components/git_status_widget.dart';
import 'package:crux/src/i18n/app_locale.dart';
import 'package:crux/src/i18n/strings.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// A [GitStatusService] that never spawns `git` and lets the
/// test pre-load any snapshot it wants via [seedCurrent]. The
/// real service stores its current snapshot in a private
/// `_status` field; the fake mirrors that with
/// `_currentOverride` and exposes it via the public [current]
/// getter.
class _FakeService extends GitStatusService {
  _FakeService() : super();

  GitStatus _currentOverride = GitStatus.empty;

  /// Inject a snapshot the widget will see via [current] and
  /// notify any listeners, exactly like the real service does
  /// after a successful `git` subprocess.
  void seedCurrent(GitStatus next) {
    _currentOverride = next;
    notifyListeners();
  }

  @override
  GitStatus get current => _currentOverride;
}

void main() {
  group('GitStatusWidget rendering', () {
    test('renders zero-height when not a git repo', () async {
      await testNocterm('git status widget not a repo', (tester) async {
        final svc = _FakeService();
        await tester.pumpComponent(
          Container(width: 40, height: 8, child: GitStatusWidget(service: svc)),
        );
        // Nothing should be rendered when we're outside a repo.
        expect(tester.terminalState.findText('staged'), isEmpty);
        expect(tester.terminalState.findText('clean'), isEmpty);
        expect(tester.terminalState.findText('main'), isEmpty);
      });
    });

    test('clean repo shows a single muted "clean" indicator', () async {
      // Inside a repo, with nothing pending, the widget should
      // show `✓ clean` — a single muted row so the user can tell
      // "in a repo, nothing to commit" apart from "not a repo".
      await testNocterm('git status widget clean repo', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 40, height: 8, child: GitStatusWidget(service: svc)),
        );
        // Clean indicator present.
        expect(tester.terminalState.findText('clean'), isNotEmpty);
        // And only that — no diff row, no counts row.
        expect(tester.terminalState.findText('staged'), isEmpty);
        expect(tester.terminalState.findText('modified'), isEmpty);
        expect(tester.terminalState.findText('0'), isEmpty);
      });
    });

    test('branch name and sync arrows do NOT leak into the widget', () async {
      // The widget deliberately does not render branch or sync
      // info — both belong to the project widget below it. Make
      // sure the move sticks: even with a fully-loaded status
      // (branch + ahead + behind + counts + diff), the widget
      // shows *only* the file-level rows.
      await testNocterm('git status widget no branch row', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'feature/long-branch-name',
              ahead: 4,
              behind: 2,
              stagedFiles: 1,
              modifiedFiles: 1,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 50, height: 8, child: GitStatusWidget(service: svc)),
        );
        expect(
          tester.terminalState.findText('feature/long-branch-name'),
          isEmpty,
        );
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

    test('counts row labels every non-zero bucket', () async {
      await testNocterm('git status widget counts row labels', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              stagedFiles: 3,
              modifiedFiles: 1,
              untrackedFiles: 2,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 60, height: 8, child: GitStatusWidget(service: svc)),
        );
        // All three labels appear so each glyph is unambiguous.
        expect(tester.terminalState.findText('staged'), isNotEmpty);
        expect(tester.terminalState.findText('modified'), isNotEmpty);
        expect(tester.terminalState.findText('untracked'), isNotEmpty);
        // Counts adjacent to their labels.
        expect(tester.terminalState.findText('3'), isNotEmpty);
        expect(tester.terminalState.findText('1'), isNotEmpty);
        expect(tester.terminalState.findText('2'), isNotEmpty);
        // Zero-bucket labels are absent (no `0 staged` clutter).
        expect(tester.terminalState.findText('deleted'), isEmpty);
        expect(tester.terminalState.findText('conflict'), isEmpty);
      });
    });

    test(
      'wraps translated counts before a narrow panel can overflow',
      () async {
        await testNocterm('git status widget narrow chinese layout', (
          tester,
        ) async {
          final svc = _FakeService()
            ..seedCurrent(
              GitStatus(
                isRepo: true,
                branch: 'main',
                modifiedFiles: 39,
                deletedFiles: 1,
                untrackedFiles: 8,
                fetchedAt: DateTime(2024, 1, 1),
              ),
            );
          await tester.pumpComponent(
            Container(
              width: 28,
              height: 8,
              child: GitStatusWidget(
                service: svc,
                strings: const Strings(AppLocale.zh),
              ),
            ),
          );

          final modified = tester.terminalState.findText('已修改').first;
          final deleted = tester.terminalState.findText('已删除').first;
          final untracked = tester.terminalState.findText('未跟踪').first;
          expect(modified.y, deleted.y);
          expect(untracked.y, greaterThan(deleted.y));
          expect(untracked.x, 3); // one panel column + `8 `
        }, size: const Size(28, 8));
      },
    );

    test('keeps the second column aligned across rows', () async {
      await testNocterm('git status widget two column alignment', (
        tester,
      ) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              conflictedFiles: 2,
              stagedFiles: 3,
              modifiedFiles: 39,
              deletedFiles: 1,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 36, height: 8, child: GitStatusWidget(service: svc)),
        );

        final staged = tester.terminalState.findText('staged').first;
        final deleted = tester.terminalState.findText('deleted').first;
        expect(staged.y, lessThan(deleted.y));
        expect(staged.x, deleted.x);
      }, size: const Size(36, 8));
    });

    test(
      'untracked state uses an explicit label without a question mark',
      () async {
        // Regression: the previous design rendered `? 10`, which looked like
        // missing information rather than a file state.
        await testNocterm('git status widget untracked label', (tester) async {
          final svc = _FakeService()
            ..seedCurrent(
              GitStatus(
                isRepo: true,
                branch: 'main',
                untrackedFiles: 10,
                fetchedAt: DateTime(2024, 1, 1),
              ),
            );
          await tester.pumpComponent(
            Container(
              width: 40,
              height: 8,
              child: GitStatusWidget(service: svc),
            ),
          );
          expect(tester.terminalState.findText('untracked'), isNotEmpty);
          expect(tester.terminalState.findText('10'), isNotEmpty);
          expect(tester.terminalState.findText('?'), isEmpty);
        });
      },
    );

    test('conflict bucket renders bold and first', () async {
      // Conflicts are the most urgent state and should pop
      // visually. We render them bold and ahead of the other
      // buckets so a quick glance catches them first.
      await testNocterm('git status widget conflict first', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              conflictedFiles: 2,
              stagedFiles: 1,
              modifiedFiles: 1,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 60, height: 8, child: GitStatusWidget(service: svc)),
        );
        expect(tester.terminalState.findText('conflict'), isNotEmpty);
        expect(tester.terminalState.findText('2'), isNotEmpty);
        // Find the conflict and stage positions; conflict must
        // come before staged in the rendered output.
        final conflict = tester.terminalState.findText('conflict').first;
        final staged = tester.terminalState.findText('staged').first;
        expect(
          conflict.y < staged.y ||
              (conflict.y == staged.y && conflict.x < staged.x),
          isTrue,
          reason: 'conflict bucket should render before staged bucket',
        );
      });
    });

    test('renders line diff only when non-zero', () async {
      await testNocterm('git status widget line diff', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              addedLines: 12,
              deletedLines: 3,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 40, height: 8, child: GitStatusWidget(service: svc)),
        );
        expect(tester.terminalState.findText('12'), isNotEmpty);
        expect(tester.terminalState.findText('3'), isNotEmpty);
        expect(tester.terminalState.findText('+'), isNotEmpty);
        // No file counts in this scenario → no labels.
        expect(tester.terminalState.findText('staged'), isEmpty);
      });
    });

    test('combined diff + counts render as two separate rows', () async {
      // When both diff and counts are non-zero the widget shows
      // exactly two rows: line diff on top, counts on bottom.
      // No third "branch" row.
      await testNocterm('git status widget two rows', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              addedLines: 5,
              deletedLines: 2,
              modifiedFiles: 3,
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 40, height: 8, child: GitStatusWidget(service: svc)),
        );
        // Both rows' content present.
        expect(tester.terminalState.findText('5'), isNotEmpty);
        expect(tester.terminalState.findText('2'), isNotEmpty);
        expect(tester.terminalState.findText('modified'), isNotEmpty);
        expect(tester.terminalState.findText('3'), isNotEmpty);
        // No branch row → no `main` glyph.
        expect(tester.terminalState.findText('main'), isEmpty);
      });
    });

    test('re-renders when the service notifies a new snapshot', () async {
      await testNocterm('git status widget reactive', (tester) async {
        final svc = _FakeService()
          ..seedCurrent(
            GitStatus(
              isRepo: true,
              branch: 'main',
              fetchedAt: DateTime(2024, 1, 1),
            ),
          );
        await tester.pumpComponent(
          Container(width: 40, height: 8, child: GitStatusWidget(service: svc)),
        );
        expect(tester.terminalState.findText('clean'), isNotEmpty);

        // Push a snapshot with pending changes — the widget
        // should swap `clean` for the counts row without a
        // manual rebuild.
        svc.seedCurrent(
          GitStatus(
            isRepo: true,
            branch: 'main',
            modifiedFiles: 5,
            fetchedAt: DateTime(2024, 1, 2),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('clean'), isEmpty);
        // The target row appears immediately, while its number starts at the
        // previous value and advances theatrically over 2.5 seconds.
        expect(tester.terminalState.findText('modified'), isNotEmpty);
        expect(tester.terminalState.findText('5'), isEmpty);

        await tester.pump(const Duration(milliseconds: 2500));
        expect(tester.terminalState.findText('5'), isNotEmpty);
      });
    });
  });
}

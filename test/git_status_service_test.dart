import 'dart:async';
import 'dart:io';

import 'package:crux/src/services/git_status_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('GitStatusService.parse', () {
    test('clean repo with no upstream yields zero counts', () {
      final status = GitStatusService.parse(
        porcelain: '## main\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );

      expect(status.isRepo, isTrue);
      expect(status.branch, 'main');
      expect(status.ahead, 0);
      expect(status.behind, 0);
      expect(status.stagedFiles, 0);
      expect(status.modifiedFiles, 0);
      expect(status.deletedFiles, 0);
      expect(status.untrackedFiles, 0);
      expect(status.conflictedFiles, 0);
      expect(status.addedLines, 0);
      expect(status.deletedLines, 0);
      expect(status.isClean, isTrue);
      expect(status.hasAnyChanges, isFalse);
    });

    test('branch with upstream parses ahead/behind', () {
      final status = GitStatusService.parse(
        porcelain: '## main...origin/main [ahead 3, behind 1]\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, 'main');
      expect(status.ahead, 3);
      expect(status.behind, 1);
      expect(status.hasUpstream, isTrue);
    });

    test('branch with only ahead parses correctly', () {
      final status = GitStatusService.parse(
        porcelain: '## feature/foo...origin/feature/foo [ahead 7]\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, 'feature/foo');
      expect(status.ahead, 7);
      expect(status.behind, 0);
    });

    test('branch with only behind parses correctly', () {
      final status = GitStatusService.parse(
        porcelain: '## main...origin/main [behind 2]\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, 'main');
      expect(status.ahead, 0);
      expect(status.behind, 2);
    });

    test('detached HEAD parses as short SHA', () {
      final status = GitStatusService.parse(
        porcelain: '## (detached at abc1234)\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, 'abc1234');
      expect(status.ahead, 0);
      expect(status.behind, 0);
    });

    test('unborn branch surfaces the (no branch) sentinel', () {
      final status = GitStatusService.parse(
        porcelain: '## (no branch)\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, '(no branch)');
    });

    test('mixed file statuses bucket correctly', () {
      // ' M'  modified in worktree
      // 'M '  modified in index
      // 'MM'  modified in both
      // 'A '  added to index
      // ' D'  deleted in worktree
      // 'D '  deleted in index
      // 'R  old -> new'  rename in index
      // '??'  untracked
      // 'UU'  conflict (both modified)
      final status = GitStatusService.parse(
        porcelain: '''
## main
 M wt_modified.txt
M  idx_modified.txt
MM both.txt
A  added.txt
 D wt_deleted.txt
D  idx_deleted.txt
R  old_name.txt -> new_name.txt
?? untracked.txt
UU conflict.txt
''',
        unstagedShortstat: '3 files changed, 8 insertions(+), 2 deletions(-)',
        stagedShortstat: '2 files changed, 5 insertions(+), 1 deletion(-)',
        fetchedAt: DateTime(2024, 1, 1),
      );

      expect(status.modifiedFiles, 2, reason: 'wt_modified + both');
      expect(
        status.deletedFiles,
        1,
        reason: 'wt_deleted only — idx_deleted counts as staged, not modified',
      );
      expect(
        status.stagedFiles,
        5,
        reason:
            'idx_modified + both + added + idx_deleted + rename = 5 (mm counts once)',
      );
      expect(status.untrackedFiles, 1);
      expect(status.conflictedFiles, 1);
      expect(status.addedLines, 13, reason: '8 unstaged + 5 staged');
      expect(status.deletedLines, 3, reason: '2 unstaged + 1 staged');
      expect(status.hasAnyChanges, isTrue);
      expect(status.isClean, isFalse);
    });

    test('empty porcelain with branchFallback falls back', () {
      // Empty porcelain shouldn't really happen, but if it does
      // the branch should fall back to whatever was passed in.
      final status = GitStatusService.parse(
        porcelain: '',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
        branchFallback: 'fallback',
      );
      expect(status.branch, 'fallback');
    });

    test('zero-line diff produces zero counts', () {
      final status = GitStatusService.parse(
        porcelain: '## main\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.addedLines, 0);
      expect(status.deletedLines, 0);
    });

    test('parse is tolerant of CRLF line endings', () {
      // Windows checkout produces \r\n line endings; the parser
      // must strip them or it would never match the porcelain
      // status codes.
      final status = GitStatusService.parse(
        porcelain: '## main\r\n M file.txt\r\n',
        unstagedShortstat: '',
        stagedShortstat: '',
        fetchedAt: DateTime(2024, 1, 1),
      );
      expect(status.branch, 'main');
      expect(status.modifiedFiles, 1);
    });
  });

  group('GitStatus equality', () {
    test('two snapshots with identical fields compare equal', () {
      final a = GitStatus(
        isRepo: true,
        fetchedAt: DateTime(2024, 1, 1),
        branch: 'main',
        ahead: 2,
      );
      final b = GitStatus(
        isRepo: true,
        fetchedAt: DateTime(2024, 1, 2), // different time, not part of ==
        branch: 'main',
        ahead: 2,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different ahead counts are not equal', () {
      final a = GitStatus(
        isRepo: true,
        fetchedAt: DateTime(2024, 1, 1),
        ahead: 2,
      );
      final b = GitStatus(
        isRepo: true,
        fetchedAt: DateTime(2024, 1, 1),
        ahead: 3,
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('GitStatusService against a real git repo', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('crux_git_test_');
      // Initialise a real git repo with a known starting state.
      _runGitSync(tempDir.path, ['init', '--initial-branch=main']);
      _runGitSync(tempDir.path, ['config', 'user.email', 'test@test']);
      _runGitSync(tempDir.path, ['config', 'user.name', 'Test']);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('not a repo returns empty status', () async {
      // Use a sibling directory OUTSIDE the temp git repo so the
      // walk-up from this directory can't find the .git we just
      // created in setUp.
      final sibling = Directory.systemTemp.createTempSync('crux_git_not_repo_');
      try {
        final svc = GitStatusService(pathProvider: () => sibling.path);
        final status = await svc.refresh();
        expect(status.isRepo, isFalse);
        expect(status, equals(GitStatus.empty));
        svc.dispose();
      } finally {
        if (sibling.existsSync()) sibling.deleteSync(recursive: true);
      }
    });

    test('clean repo reports branch with zero changes', () async {
      // Commit an initial file so HEAD points somewhere.
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Test\n');
      _runGitSync(tempDir.path, ['add', '.']);
      _runGitSync(tempDir.path, ['commit', '-m', 'init']);

      final svc = GitStatusService(pathProvider: () => tempDir.path);
      final status = await svc.refresh();
      expect(status.isRepo, isTrue);
      expect(status.branch, 'main');
      expect(status.isClean, isTrue);
      svc.dispose();
    });

    test('working-tree changes show up in modifiedFiles', () async {
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Test\n');
      _runGitSync(tempDir.path, ['add', '.']);
      _runGitSync(tempDir.path, ['commit', '-m', 'init']);
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Changed\n');

      final svc = GitStatusService(pathProvider: () => tempDir.path);
      final status = await svc.refresh();
      expect(status.branch, 'main');
      expect(status.modifiedFiles, greaterThanOrEqualTo(1));
      svc.dispose();
    });

    test('staged file shows up in stagedFiles', () async {
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Test\n');
      _runGitSync(tempDir.path, ['add', '.']);
      _runGitSync(tempDir.path, ['commit', '-m', 'init']);
      File(p.join(tempDir.path, 'new.txt')).writeAsStringSync('new\n');
      _runGitSync(tempDir.path, ['add', 'new.txt']);

      final svc = GitStatusService(pathProvider: () => tempDir.path);
      final status = await svc.refresh();
      expect(status.stagedFiles, greaterThanOrEqualTo(1));
      svc.dispose();
    });

    test('start() performs the initial fetch and does not crash the isolate',
        () async {
      // Regression test for the start-message arg-order bug: `start()`
      // used to send [interval, refreshImmediately, path] while the
      // isolate handler read message[2] as the path (String) and
      // message[3] as the flag (bool). That made message[2] a bool, so
      // the `as String` cast threw inside the isolate, killing both the
      // immediate fetch and the periodic-refresh timer. Exercising
      // `start()` directly (rather than `refresh()`, which sends a
      // different, correctly-ordered message) is what catches it.
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync('# Test\n');
      _runGitSync(tempDir.path, ['add', '.']);
      _runGitSync(tempDir.path, ['commit', '-m', 'init']);

      final svc = GitStatusService(pathProvider: () => tempDir.path);
      addTearDown(svc.dispose);

      // start() is fire-and-forget: it spawns the isolate and kicks off
      // the immediate fetch (refreshImmediately defaults to true). Wait
      // for the ChangeNotifier to fire with the fetched status. If the
      // isolate crashed on the arg-order bug, no notification ever
      // arrives and the test times out.
      final notified = svc.firstWhere((s) => s.isRepo);
      svc.start();
      final status = await notified.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('start() never delivered a status — isolate likely crashed'),
      );
      expect(status.branch, 'main');
      expect(status.isClean, isTrue);
    });
  });
}

extension on GitStatusService {
  /// The next emitted status matching [test], as a Future. Wraps the
  /// ChangeNotifier listener so tests can `await` a state instead of
  /// polling.
  Future<GitStatus> firstWhere(bool Function(GitStatus) test) {
    // If the current snapshot already matches, return it immediately.
    if (test(current)) return Future.value(current);
    final completer = Completer<GitStatus>();
    void listener() {
      if (test(current) && !completer.isCompleted) {
        completer.complete(current);
      }
    }

    addListener(listener);
    return completer.future.whenComplete(() => removeListener(listener));
  }
}

/// Run a `git` subprocess synchronously and assert success. Used
/// in setUp blocks where an exception would otherwise leave the
/// test in an indeterminate state.
void _runGitSync(String cwd, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} in $cwd failed (exit ${result.exitCode})\n'
      'stdout: ${result.stdout}\nstderr: ${result.stderr}',
    );
  }
}

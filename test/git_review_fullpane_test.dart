import 'package:crux/src/components/git_review_fullpane.dart';
import 'package:crux/src/components/ui/highlight_service.dart';
import 'package:crux/src/i18n/app_locale.dart';
import 'package:crux/src/i18n/strings.dart';
import 'package:crux/src/services/git_review_service.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  setUpAll(HighlightService.initialize);

  test(
    'renders files, staged and unstaged patches, and chunk actions',
    () async {
      final backend = _FakeGitReviewBackend();
      await testNocterm('git review layout', (tester) async {
        await _mount(tester, backend);
        final text = tester.terminalState.getText();
        expect(text, contains('Git changes · main'));
        expect(text, contains('lib/example.dart'));
        expect(text, contains('▾ lib'));
        expect(text, contains('Staged changes'));
        expect(text, contains('Unstaged changes'));
        expect(text, contains('Change 1 of 2'));
        expect(text, isNot(contains('diff --git')));
        expect(text, isNot(contains('@@ -')));
        expect(text, contains('stage chunk'));
        expect(text, contains('unstage chunk'));
        expect(text, contains('newValue'));
        expect(text, contains('M modified'));
        expect(text, contains('+ new'));
        expect(text, contains('- deleted'));
        expect(text, contains('Search files'));
        expect(text, isNot(contains('┌────────')));

        final selectedFile = tester.terminalState
            .findText('example.dart')
            .reduce((a, b) => a.x < b.x ? a : b);
        expect(
          tester.terminalState
              .getCellAt(selectedFile.x, selectedFile.y)
              ?.style
              .backgroundColor,
          CruxThemeData.draculaFallback.selectionColor,
        );
      }, size: const Size(120, 34));
    },
  );

  test('tree folders collapse and scope tabs are clickable', () async {
    final backend = _FakeGitReviewBackend();
    await testNocterm('git review tree and tabs', (tester) async {
      await _mount(tester, backend, width: 160);

      final folder = tester.terminalState.findText('▾ lib').single;
      await tester.tap(folder.x + 1, folder.y);
      await tester.pump();
      expect(tester.terminalState.getText(), contains('▸ lib'));

      final expandAll = tester.terminalState.findText('Expand all').single;
      await tester.tap(expandAll.x + 2, expandAll.y);
      await tester.pump();
      expect(tester.terminalState.getText(), contains('▾ lib'));

      final collapseAll = tester.terminalState.findText('Collapse all').single;
      await tester.tap(collapseAll.x + 2, collapseAll.y);
      await tester.pump();
      expect(tester.terminalState.getText(), contains('▸ lib'));

      final unstagedTab = tester.terminalState
          .findText('unstaged')
          .reduce((a, b) => a.y < b.y ? a : b);
      await tester.tap(unstagedTab.x + 2, unstagedTab.y);
      await _pumpAsync(tester);
      final text = tester.terminalState.getText();
      expect(text, contains('Unstaged changes'));
      expect(text, isNot(contains('Staged changes')));
    }, size: const Size(160, 34));
  });

  test('file search filters the tree as the user types', () async {
    final backend = _FakeGitReviewBackend(fileCount: 3);
    await testNocterm('git review file search', (tester) async {
      await _mount(tester, backend, width: 140);
      final search = tester.terminalState.findText('Search files').single;
      await tester.tap(search.x + 2, search.y);
      await tester.enterText('_2');
      await tester.pump();
      expect(tester.terminalState.getText(), contains('_2'));
      expect(backend.loadPatchCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await _pumpAsync(tester);

      var text = tester.terminalState.getText();
      expect(text, contains('example_2.dart'));
      expect(text, isNot(contains('example_1.dart')));
      expect(backend.loadPatchCalls, 1);

      final result = tester.terminalState.findText('example_2.dart').single;
      await tester.tap(result.x + 2, result.y);
      await _pumpAsync(tester);
      expect(backend.loadPatchCalls, 2);

      await tester.sendEscape();
      await _pumpAsync(tester);
      text = tester.terminalState.getText();
      expect(text, contains('example_1.dart'));
      expect(text, contains('example_2.dart'));
    }, size: const Size(140, 34));
  });

  test('file status glyphs use conventional colors', () async {
    final backend = _FakeGitReviewBackend(
      snapshotFiles: const [
        GitReviewFile(
          path: 'lib/aaa_modified.dart',
          indexStatus: ' ',
          workTreeStatus: 'M',
        ),
        GitReviewFile(
          path: 'lib/added.dart',
          indexStatus: '?',
          workTreeStatus: '?',
        ),
        GitReviewFile(
          path: 'lib/deleted.dart',
          indexStatus: ' ',
          workTreeStatus: 'D',
        ),
        GitReviewFile(
          path: 'lib/renamed.dart',
          indexStatus: 'R',
          workTreeStatus: ' ',
        ),
      ],
    );
    await testNocterm('git review status colors', (tester) async {
      await _mount(tester, backend, width: 140);
      final theme = CruxThemeData.draculaFallback;

      Color? colorOf(String text) {
        final match = tester.terminalState.findText(text).single;
        return tester.terminalState.getCellAt(match.x, match.y)?.style.color;
      }

      expect(colorOf('+ added.dart'), theme.successColor);
      expect(colorOf('- deleted.dart'), theme.errorColor);
      expect(colorOf('R renamed.dart'), theme.info);
    }, size: const Size(140, 34));
  });

  test('Chinese review copy stays human-readable at standard width', () async {
    final backend = _FakeGitReviewBackend();
    await testNocterm('git review Chinese copy', (tester) async {
      await _mount(tester, backend, strings: const Strings(AppLocale.zh));
      final text = tester.terminalState.getText();
      expect(text, contains('全部  1'));
      expect(text, contains('已暂存的改动'));
      expect(text, contains('未暂存的改动'));
      expect(text, contains('改动 1 / 2'));
      expect(text, isNot(contains('diff --git')));
      expect(text, isNot(contains('@@ -')));
    }, size: const Size(120, 34));
  });

  test(
    'wide diff uses before/after columns with syntax highlighting',
    () async {
      final backend = _FakeGitReviewBackend();
      await testNocterm('git review split diff', (tester) async {
        await _mount(tester, backend, width: 160, height: 40);
        final text = tester.terminalState.getText();
        expect(text, contains('BEFORE'));
        expect(text, contains('AFTER'));
        expect(text, contains('oldValue'));
        expect(text, contains('newValue'));

        final keywordCells = tester.terminalState.findText('final');
        expect(keywordCells, isNotEmpty);
        expect(
          keywordCells.any(
            (match) =>
                tester.terminalState.getCellAt(match.x, match.y)?.style.color ==
                CruxThemeData.draculaFallback.syntaxKeyword,
          ),
          isTrue,
        );
      }, size: const Size(160, 40));
    },
  );

  test('narrow diff falls back to unified rendering', () async {
    final backend = _FakeGitReviewBackend();
    await testNocterm('git review unified diff', (tester) async {
      await _mount(tester, backend, width: 70, height: 28);
      final text = tester.terminalState.getText();
      expect(text, isNot(contains('BEFORE')));
      expect(text, contains('-final oldValue'));
      expect(text, contains('+final newValue'));
    }, size: const Size(70, 28));
  });

  test('file list and diff expose independent visible scrollbars', () async {
    final backend = _FakeGitReviewBackend(fileCount: 40, diffLineCount: 60);
    await testNocterm('git review scrollbars', (tester) async {
      await _mount(tester, backend, width: 120, height: 24);
      final thumbs = tester.terminalState.findText('█');
      expect(thumbs, isNotEmpty);
      expect(
        thumbs.map((match) => match.x).toSet().length,
        greaterThanOrEqualTo(2),
      );
    }, size: const Size(120, 24));
  });

  test('keyboard stage and unstage target the selected hunk', () async {
    final backend = _FakeGitReviewBackend();
    await testNocterm('git review hunk keys', (tester) async {
      await _mount(tester, backend);

      // First hunk is staged, so `u` reverses it from the index.
      await tester.sendKeyEvent(
        const KeyboardEvent(logicalKey: LogicalKey.keyU, character: 'u'),
      );
      await _pumpAsync(tester);
      expect(backend.unstagedHunks, 1);

      // Move to the unstaged hunk and stage it.
      await tester.sendKeyEvent(
        const KeyboardEvent(logicalKey: LogicalKey.bracketRight),
      );
      await tester.sendKeyEvent(
        const KeyboardEvent(logicalKey: LogicalKey.keyS, character: 's'),
      );
      await _pumpAsync(tester);
      expect(backend.stagedHunks, 1);
    }, size: const Size(120, 34));
  });

  test('generates commit message only from staged context', () async {
    final backend = _FakeGitReviewBackend();
    String? receivedDiff;
    await testNocterm('git review commit message', (tester) async {
      await _mount(
        tester,
        backend,
        generator: (diff, subjects) async {
          receivedDiff = diff;
          expect(subjects, ['existing style']);
          return 'feat: explain staged change';
        },
      );
      await tester.sendKeyEvent(
        const KeyboardEvent(logicalKey: LogicalKey.keyG, character: 'g'),
      );
      await _pumpAsync(tester);
      expect(receivedDiff, contains('cached change'));
      expect(
        tester.terminalState.getText(),
        contains('feat: explain staged change'),
      );
      expect(tester.terminalState.getText(), contains('Commit + Push'));
    }, size: const Size(120, 34));
  });

  test(
    'prepared draft opens staged commit review and commits on approval',
    () async {
      final backend = _FakeGitReviewBackend();
      var closed = false;
      await testNocterm('prepared commit review', (tester) async {
        await _mount(
          tester,
          backend,
          initialDraft: const GitCommitDraft(
            title: 'feat: add review handoff',
            description:
                'Stage the requested files and wait for human approval.',
          ),
          onClose: () => closed = true,
        );
        var text = tester.terminalState.getText();
        expect(text, contains('staged  1'));
        expect(text, contains('Commit title'));
        expect(text, contains('feat: add review handoff'));
        expect(text, contains('Detailed description'));
        expect(text, contains('Commit + Push'));
        expect(text, isNot(contains('Staged changes')));

        // Clicking the already-selected file is an explicit request to inspect
        // it, so it must leave commit details and return to the staged diff.
        final selectedFile = tester.terminalState
            .findText('example.dart')
            .single;
        await tester.tap(selectedFile.x + 1, selectedFile.y);
        await _pumpAsync(tester);
        text = tester.terminalState.getText();
        expect(text, contains('Staged changes'));
        expect(text, isNot(contains('Commit title')));

        final details = tester.terminalState.findText('Commit details').single;
        await tester.tap(details.x + 1, details.y);
        await tester.pump();
        final push = tester.terminalState.findText('Commit + Push').single;
        final commit = tester.terminalState
            .findText('Commit')
            .where((match) => match.y == push.y && match.x < push.x)
            .reduce((a, b) => a.x > b.x ? a : b);
        await tester.tap(commit.x + 1, commit.y);
        await _pumpAsync(tester);

        expect(backend.commitCalls, 1);
        expect(backend.lastDraft?.title, 'feat: add review handoff');
        expect(backend.lastDraft?.description, contains('human approval'));
        expect(backend.lastPush, isFalse);
        expect(closed, isTrue);
      }, size: const Size(120, 34));
    },
  );

  test('Commit + Push requests an ordinary push after commit', () async {
    final backend = _FakeGitReviewBackend();
    await testNocterm('commit and push approval', (tester) async {
      await _mount(
        tester,
        backend,
        initialDraft: const GitCommitDraft(
          title: 'fix: ship reviewed change',
          description: '',
        ),
      );
      final action = tester.terminalState.findText('Commit + Push').single;
      await tester.tap(action.x + 2, action.y);
      await _pumpAsync(tester);

      expect(backend.commitCalls, 1);
      expect(backend.lastPush, isTrue);
    }, size: const Size(120, 34));
  });
}

Future<void> _mount(
  dynamic tester,
  GitReviewBackend backend, {
  CommitMessageGenerator? generator,
  Strings strings = kEnglishStrings,
  GitCommitDraft? initialDraft,
  VoidCallback? onClose,
  double width = 120,
  double height = 34,
}) async {
  await tester.pumpComponent(
    Container(
      width: width,
      height: height,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: GitReviewFullpane(
          backend: backend,
          onClose: onClose ?? () {},
          generateCommitMessage: generator,
          initialDraft: initialDraft,
          strings: strings,
        ),
      ),
    ),
  );
  await _pumpAsync(tester);
}

Future<void> _pumpAsync(dynamic tester) async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

class _FakeGitReviewBackend implements GitReviewBackend {
  final int fileCount;
  final int diffLineCount;
  final List<GitReviewFile>? snapshotFiles;
  int stagedHunks = 0;
  int unstagedHunks = 0;
  int loadPatchCalls = 0;
  int commitCalls = 0;
  GitCommitDraft? lastDraft;
  bool? lastPush;

  _FakeGitReviewBackend({
    this.fileCount = 1,
    this.diffLineCount = 0,
    this.snapshotFiles,
  });

  final file = const GitReviewFile(
    path: 'lib/example.dart',
    indexStatus: 'M',
    workTreeStatus: 'M',
  );

  GitReviewHunk _hunk(String label) => GitReviewHunk(
    header: '@@ -1 +1 @@ $label',
    lines: [
      '-final oldValue = 1;',
      '+final newValue = 2;',
      for (var i = 0; i < diffLineCount; i++) ' context line $i',
    ],
    patch: 'patch',
  );

  @override
  Future<GitReviewSnapshot> loadSnapshot() async => GitReviewSnapshot(
    branch: 'main',
    files:
        snapshotFiles ??
        [
          file,
          for (var i = 1; i < fileCount; i++)
            GitReviewFile(
              path: 'lib/example_$i.dart',
              indexStatus: ' ',
              workTreeStatus: 'M',
            ),
        ],
  );

  @override
  Future<List<GitReviewPatch>> loadPatches(GitReviewFile file) async {
    loadPatchCalls++;
    return [
      GitReviewPatch(
        kind: GitReviewPatchKind.staged,
        headerLines: const ['diff --git a/lib/example.dart b/lib/example.dart'],
        hunks: [_hunk('staged')],
      ),
      GitReviewPatch(
        kind: GitReviewPatchKind.unstaged,
        headerLines: const ['diff --git a/lib/example.dart b/lib/example.dart'],
        hunks: [_hunk('unstaged')],
      ),
    ];
  }

  @override
  Future<void> stageFile(GitReviewFile file) async {}

  @override
  Future<void> unstageFile(GitReviewFile file) async {}

  @override
  Future<void> stageHunk(GitReviewHunk hunk) async {
    stagedHunks++;
  }

  @override
  Future<void> unstageHunk(GitReviewHunk hunk) async {
    unstagedHunks++;
  }

  @override
  Future<GitCommitContext> loadCommitContext() async => const GitCommitContext(
    stagedDiff: 'cached change',
    recentSubjects: ['existing style'],
  );

  @override
  Future<GitCommitOutcome> commit(
    GitCommitDraft draft, {
    bool push = false,
  }) async {
    commitCalls++;
    lastDraft = draft;
    lastPush = push;
    return GitCommitOutcome(commitHash: 'abc1234', pushed: push);
  }
}

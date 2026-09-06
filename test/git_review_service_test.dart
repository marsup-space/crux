import 'dart:io';

import 'package:crux/src/services/git_review_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crux_git_review_');
    _git(dir.path, ['init', '--initial-branch=main']);
    _git(dir.path, ['config', 'user.email', 'test@example.com']);
    _git(dir.path, ['config', 'user.name', 'Test User']);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('parses a unified patch into independently applicable hunks', () {
    final parsed = parseGitReviewPatch('''
diff --git a/a.txt b/a.txt
index 123..456 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
 one
-two
+TWO
@@ -10,2 +10,2 @@
 ten
-eleven
+ELEVEN
''', GitReviewPatchKind.unstaged);

    expect(parsed.hunks, hasLength(2));
    expect(parsed.hunks.first.patch, contains('@@ -1,2 +1,2 @@'));
    expect(parsed.hunks.first.patch, isNot(contains('@@ -10,2 +10,2 @@')));
    expect(parsed.hunks.last.patch, contains('diff --git a/a.txt b/a.txt'));
    expect(parsed.hunks.first.patch, isNot(contains('index 123..456')));
  });

  test('uses familiar source-control status symbols', () {
    expect(
      const GitReviewFile(
        path: 'new.txt',
        indexStatus: '?',
        workTreeStatus: '?',
      ).displayStatus,
      '+',
    );
    expect(
      const GitReviewFile(
        path: 'deleted.txt',
        indexStatus: ' ',
        workTreeStatus: 'D',
      ).displayStatus,
      '-',
    );
    expect(
      const GitReviewFile(
        path: 'renamed.txt',
        indexStatus: 'R',
        workTreeStatus: ' ',
      ).displayStatus,
      'R',
    );
    expect(
      const GitReviewFile(
        path: 'modified.txt',
        indexStatus: ' ',
        workTreeStatus: 'M',
      ).displayStatus,
      'M',
    );
  });

  test('stages and unstages one hunk without touching the other', () async {
    final path = p.join(dir.path, 'sample.txt');
    final original = [for (var i = 1; i <= 24; i++) 'line $i'];
    File(path).writeAsStringSync('${original.join('\n')}\n');
    _git(dir.path, ['add', 'sample.txt']);
    _git(dir.path, ['commit', '-m', 'initial']);

    final changed = [...original];
    changed[1] = 'changed near top';
    changed[21] = 'changed near bottom';
    File(path).writeAsStringSync('${changed.join('\n')}\n');

    final service = GitReviewService(projectPath: dir.path);
    var snapshot = await service.loadSnapshot();
    expect(snapshot.files, hasLength(1));
    expect(snapshot.files.single.hasUnstaged, isTrue);

    var patches = await service.loadPatches(snapshot.files.single);
    final unstaged = patches.singleWhere(
      (patch) => patch.kind == GitReviewPatchKind.unstaged,
    );
    expect(unstaged.hunks, hasLength(2));

    await service.stageHunk(unstaged.hunks.first);
    snapshot = await service.loadSnapshot();
    expect(snapshot.files.single.isPartiallyStaged, isTrue);
    final cached = _git(dir.path, ['diff', '--cached']);
    final working = _git(dir.path, ['diff']);
    expect(cached, contains('changed near top'));
    expect(cached, isNot(contains('changed near bottom')));
    expect(working, contains('changed near bottom'));

    patches = await service.loadPatches(snapshot.files.single);
    final staged = patches.singleWhere(
      (patch) => patch.kind == GitReviewPatchKind.staged,
    );
    await service.unstageHunk(staged.hunks.single);

    expect(_git(dir.path, ['diff', '--cached']).trim(), isEmpty);
    expect(_git(dir.path, ['diff']), contains('changed near top'));
    expect(_git(dir.path, ['diff']), contains('changed near bottom'));
  });

  test('refreshes a stale hunk before staging it', () async {
    final path = p.join(dir.path, 'consecutive.txt');
    final original = [for (var i = 1; i <= 30; i++) 'line $i'];
    File(path).writeAsStringSync('${original.join('\n')}\n');
    _git(dir.path, ['add', 'consecutive.txt']);
    _git(dir.path, ['commit', '-m', 'initial']);

    final changed = [...original];
    changed[1] = 'changed near top';
    changed[27] = 'changed near bottom';
    File(path).writeAsStringSync('${changed.join('\n')}\n');

    final service = GitReviewService(projectPath: dir.path);
    final file = (await service.loadSnapshot()).files.single;
    final hunks = (await service.loadPatches(file)).single.hunks;
    expect(hunks, hasLength(2));

    final staleHeader = '@@ -999,1 +999,1 @@';
    final stale = GitReviewHunk(
      header: staleHeader,
      lines: hunks.first.lines,
      patch: hunks.first.patch.replaceFirst(hunks.first.header, staleHeader),
      filePath: file.path,
    );

    // The UI may have been open while another tool refreshed or formatted the
    // file. The service re-identifies the requested change in the current
    // diff instead of feeding stale line coordinates to `git apply`.
    await service.stageHunk(stale);
    await service.stageHunk(hunks.last);

    expect(_git(dir.path, ['diff', '--cached']), contains('changed near top'));
    expect(
      _git(dir.path, ['diff', '--cached']),
      contains('changed near bottom'),
    );
  });

  test('whole-file stage and unstage preserve the working tree', () async {
    final path = p.join(dir.path, 'a.txt');
    File(path).writeAsStringSync('before\n');
    _git(dir.path, ['add', 'a.txt']);
    _git(dir.path, ['commit', '-m', 'initial']);
    File(path).writeAsStringSync('after\n');

    final service = GitReviewService(projectPath: dir.path);
    var snapshot = await service.loadSnapshot();
    await service.stageFile(snapshot.files.single);
    snapshot = await service.loadSnapshot();
    expect(snapshot.files.single.hasStaged, isTrue);
    expect(snapshot.files.single.hasUnstaged, isFalse);

    await service.unstageFile(snapshot.files.single);
    snapshot = await service.loadSnapshot();
    expect(snapshot.files.single.hasStaged, isFalse);
    expect(snapshot.files.single.hasUnstaged, isTrue);
    expect(File(path).readAsStringSync(), 'after\n');
  });

  test('whole-file staging includes both sides of a rename', () async {
    final oldPath = p.join(dir.path, 'before.txt');
    final newPath = p.join(dir.path, 'after.txt');
    File(oldPath).writeAsStringSync('same content\n');
    _git(dir.path, ['add', 'before.txt']);
    _git(dir.path, ['commit', '-m', 'initial']);
    File(oldPath).renameSync(newPath);

    final service = GitReviewService(projectPath: dir.path);
    await service.stageFile(
      const GitReviewFile(
        path: 'after.txt',
        oldPath: 'before.txt',
        indexStatus: 'R',
        workTreeStatus: ' ',
      ),
    );

    final status = _git(dir.path, ['status', '--short']);
    expect(status, contains('before.txt -> after.txt'));
    expect(status.trimLeft(), startsWith('R '));
  });

  test('an untracked text file can be staged as one chunk', () async {
    final path = p.join(dir.path, 'new.txt');
    File(path).writeAsStringSync('first\nsecond');
    final service = GitReviewService(projectPath: dir.path);

    var snapshot = await service.loadSnapshot();
    expect(snapshot.files.single.isUntracked, isTrue);
    final patch = (await service.loadPatches(snapshot.files.single)).single;
    expect(patch.hunks, hasLength(1));
    expect(patch.hunks.single.lines.last, r'\ No newline at end of file');

    await service.stageHunk(patch.hunks.single);
    snapshot = await service.loadSnapshot();
    expect(snapshot.files.single.hasStaged, isTrue);
    expect(snapshot.files.single.hasUnstaged, isFalse);
    expect(_git(dir.path, ['show', ':new.txt']), 'first\nsecond');
  });

  test('creates a commit from the reviewed title and description', () async {
    final path = p.join(dir.path, 'reviewed.txt');
    File(path).writeAsStringSync('reviewed change\n');
    final service = GitReviewService(projectPath: dir.path);
    await service.stageFile((await service.loadSnapshot()).files.single);

    final outcome = await service.commit(
      const GitCommitDraft(
        title: 'feat: add reviewed change',
        description: 'Explain why the reviewed change is needed.',
      ),
    );

    expect(outcome.commitHash, isNotEmpty);
    expect(outcome.pushed, isFalse);
    expect(
      _git(dir.path, ['log', '-1', '--pretty=%s']),
      'feat: add reviewed change\n',
    );
    expect(
      _git(dir.path, ['log', '-1', '--pretty=%b']).trim(),
      'Explain why the reviewed change is needed.',
    );
  });

  test('commit and push sends the reviewed commit to the upstream', () async {
    final remote = Directory.systemTemp.createTempSync('crux_git_remote_');
    addTearDown(() {
      try {
        remote.deleteSync(recursive: true);
      } catch (_) {}
    });
    _git(remote.path, ['init', '--bare']);

    final path = p.join(dir.path, 'pushed.txt');
    File(path).writeAsStringSync('initial\n');
    _git(dir.path, ['add', 'pushed.txt']);
    _git(dir.path, ['commit', '-m', 'initial']);
    _git(dir.path, ['remote', 'add', 'origin', remote.path]);
    _git(dir.path, ['push', '-u', 'origin', 'main']);
    File(path).writeAsStringSync('reviewed and pushed\n');

    final service = GitReviewService(projectPath: dir.path);
    await service.stageFile((await service.loadSnapshot()).files.single);
    final outcome = await service.commit(
      const GitCommitDraft(
        title: 'feat: push reviewed change',
        description: 'Publish only after the user approves it.',
      ),
      push: true,
    );

    expect(outcome.pushed, isTrue);
    expect(
      _git(remote.path, ['log', '-1', '--pretty=%s', 'main']).trim(),
      'feat: push reviewed change',
    );
  });

  test(
    'reports push failure without hiding the created local commit',
    () async {
      final path = p.join(dir.path, 'local-only.txt');
      File(path).writeAsStringSync('local commit\n');
      final service = GitReviewService(projectPath: dir.path);
      await service.stageFile((await service.loadSnapshot()).files.single);

      await expectLater(
        service.commit(
          const GitCommitDraft(
            title: 'fix: preserve local commit',
            description: '',
          ),
          push: true,
        ),
        throwsA(
          isA<GitReviewException>().having(
            (error) => error.message,
            'message',
            allOf(contains('was created'), contains('push failed')),
          ),
        ),
      );
      expect(
        _git(dir.path, ['log', '-1', '--pretty=%s']),
        'fix: preserve local commit\n',
      );
    },
  );
}

String _git(String cwd, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

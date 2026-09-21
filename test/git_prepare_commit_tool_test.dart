import 'dart:io';

import 'package:crux/src/services/git_review_service.dart';
import 'package:crux/src/tools/git_prepare_commit_tool.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crux_prepare_commit_');
    _git(dir.path, ['init', '--initial-branch=main']);
    _git(dir.path, ['config', 'user.email', 'test@example.com']);
    _git(dir.path, ['config', 'user.name', 'Test User']);
    File(p.join(dir.path, 'keep.txt')).writeAsStringSync('before\n');
    File(p.join(dir.path, 'other.txt')).writeAsStringSync('before\n');
    _git(dir.path, ['add', '.']);
    _git(dir.path, ['commit', '-m', 'initial']);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('stages only requested files and opens human review', () async {
    File(p.join(dir.path, 'keep.txt')).writeAsStringSync('after\n');
    File(p.join(dir.path, 'other.txt')).writeAsStringSync('unrelated\n');
    GitCommitReviewRequest? opened;
    final tool = GitPrepareCommitTool(
      onPrepared: (request) => opened = request,
    );

    final result = await tool.execute({
      'files': ['keep.txt'],
      'title': 'feat: prepare reviewed commit',
      'description': 'Keep final commit and push actions human-owned.',
    }, _context(dir.path));

    expect(result.title, 'Commit ready for review');
    expect(result.metadata['awaitingHumanApproval'], isTrue);
    expect(opened?.stagedPaths, ['keep.txt']);
    expect(opened?.draft.title, 'feat: prepare reviewed commit');
    expect(_git(dir.path, ['diff', '--cached', '--name-only']), 'keep.txt\n');
    expect(_git(dir.path, ['diff', '--name-only']), 'other.txt\n');
    expect(_git(dir.path, ['rev-list', '--count', 'HEAD']), '1\n');
  });

  test(
    'passes note and approval through to the opened review request',
    () async {
      File(p.join(dir.path, 'keep.txt')).writeAsStringSync('after\n');
      GitCommitReviewRequest? opened;
      final tool = GitPrepareCommitTool(
        onPrepared: (request) => opened = request,
      );

      final result = await tool.execute({
        'files': ['keep.txt'],
        'title': 'feat: review context',
        'description': '',
        'note': 'Verified: dart analyze',
        'approval': 'commit',
      }, _context(dir.path));

      expect(result.title, 'Commit ready for review');
      expect(opened?.note, 'Verified: dart analyze');
      expect(opened?.approval, GitCommitApproval.commit);
      expect(result.metadata['approval'], 'commit');
    },
  );

  test('rejects invalid approval before staging or opening review', () async {
    File(p.join(dir.path, 'keep.txt')).writeAsStringSync('after\n');
    var opened = false;
    final tool = GitPrepareCommitTool(onPrepared: (_) => opened = true);

    final result = await tool.execute({
      'files': ['keep.txt'],
      'title': 'feat: impossible approval',
      'description': '',
      'approval': 'ship-it',
    }, _context(dir.path));

    expect(result.title, 'Error');
    expect(opened, isFalse);
    expect(_git(dir.path, ['diff', '--cached', '--name-only']), isEmpty);
    expect(_git(dir.path, ['rev-list', '--count', 'HEAD']), '1\n');
  });

  test('defaults omitted approval to both', () async {
    File(p.join(dir.path, 'keep.txt')).writeAsStringSync('after\n');
    GitCommitReviewRequest? opened;
    final tool = GitPrepareCommitTool(
      onPrepared: (request) => opened = request,
    );

    await tool.execute({
      'files': ['keep.txt'],
      'title': 'feat: default approval',
      'description': '',
    }, _context(dir.path));

    expect(opened?.approval, GitCommitApproval.both);
  });

  test('rejects paths that are not currently changed', () async {
    var opened = false;
    final tool = GitPrepareCommitTool(onPrepared: (_) => opened = true);

    final result = await tool.execute({
      'files': ['missing.txt'],
      'title': 'fix: impossible draft',
      'description': '',
    }, _context(dir.path));

    expect(result.title, 'Error');
    expect(result.output, contains('not currently changed'));
    expect(opened, isFalse);
    expect(_git(dir.path, ['rev-list', '--count', 'HEAD']), '1\n');
  });

  test('tool contract requires title and description in Crux language', () {
    final tool = GitPrepareCommitTool(onPrepared: (_) {});
    expect(tool.description, contains('current Crux language setting'));
    final properties = tool.parametersSchema['properties'] as Map;
    expect(
      (properties['title'] as Map)['description'],
      contains('current Crux reply language'),
    );
    expect(
      (properties['description'] as Map)['description'],
      contains('current Crux reply language'),
    );
  });
}

ToolContext _context(String cwd) => ToolContext(
  sessionId: 1,
  messageId: 1,
  abort: AbortSignal(),
  workingDirectory: cwd,
);

String _git(String cwd, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

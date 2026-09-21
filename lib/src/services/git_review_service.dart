import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Which side of the index a review patch describes.
enum GitReviewPatchKind { staged, unstaged }

/// File state reported by `git status --porcelain`.
class GitReviewFile {
  final String path;
  final String? oldPath;
  final String indexStatus;
  final String workTreeStatus;

  const GitReviewFile({
    required this.path,
    required this.indexStatus,
    required this.workTreeStatus,
    this.oldPath,
  });

  bool get isUntracked => indexStatus == '?' && workTreeStatus == '?';
  bool get isConflicted =>
      const {
        'DD',
        'AU',
        'UD',
        'UA',
        'DU',
        'AA',
        'UU',
      }.contains('$indexStatus$workTreeStatus') ||
      indexStatus == 'U' ||
      workTreeStatus == 'U';
  bool get hasStaged =>
      !isUntracked && indexStatus != ' ' && indexStatus != '?';
  bool get hasUnstaged =>
      isUntracked || (workTreeStatus != ' ' && workTreeStatus != '?');
  bool get isPartiallyStaged => hasStaged && hasUnstaged;

  bool get isAdded =>
      isUntracked || indexStatus == 'A' || workTreeStatus == 'A';
  bool get isDeleted => indexStatus == 'D' || workTreeStatus == 'D';
  bool get isRenamed =>
      indexStatus == 'R' ||
      workTreeStatus == 'R' ||
      indexStatus == 'C' ||
      workTreeStatus == 'C';

  String get displayStatus {
    if (isConflicted) return '!';
    if (isAdded) return '+';
    if (isDeleted) return '-';
    if (isRenamed) return 'R';
    return 'M';
  }
}

class GitReviewSnapshot {
  final String branch;
  final List<GitReviewFile> files;

  const GitReviewSnapshot({required this.branch, required this.files});

  int get stagedCount => files.where((file) => file.hasStaged).length;
  int get unstagedCount => files.where((file) => file.hasUnstaged).length;
}

/// One independently applicable hunk. [patch] contains the file header plus
/// this hunk only, so it can be piped directly to `git apply --cached`.
class GitReviewHunk {
  final String header;
  final List<String> lines;
  final String patch;
  final String? filePath;

  const GitReviewHunk({
    required this.header,
    required this.lines,
    required this.patch,
    this.filePath,
  });
}

class GitReviewPatch {
  final GitReviewPatchKind kind;
  final List<String> headerLines;
  final List<GitReviewHunk> hunks;
  final List<String> trailingLines;

  const GitReviewPatch({
    required this.kind,
    required this.headerLines,
    required this.hunks,
    this.trailingLines = const [],
  });

  bool get isEmpty => headerLines.isEmpty && hunks.isEmpty;
  bool get isBinary =>
      headerLines.any((line) => line.startsWith('Binary files ')) ||
      trailingLines.any((line) => line.startsWith('Binary files '));
}

class GitCommitContext {
  final String stagedDiff;
  final List<String> recentSubjects;

  const GitCommitContext({
    required this.stagedDiff,
    required this.recentSubjects,
  });
}

class GitCommitDraft {
  final String title;
  final String description;

  const GitCommitDraft({required this.title, required this.description});

  String get message => description.trim().isEmpty
      ? title.trim()
      : '${title.trim()}\n\n${description.trim()}';
}

/// Which final actions the commit review screen offers.
enum GitCommitApproval {
  /// Commit only — no push button.
  commit,

  /// Commit + Push only — no plain commit button.
  commitPush,

  /// Both buttons; the user chooses. Default.
  both;

  /// Parses the tool argument value; null for unknown input.
  static GitCommitApproval? fromName(String name) => switch (name) {
    'commit' => commit,
    'commit-push' => commitPush,
    'both' => both,
    _ => null,
  };
}

class GitCommitOutcome {
  final String commitHash;
  final bool pushed;

  const GitCommitOutcome({required this.commitHash, required this.pushed});
}

/// Injectable backend used by the fullpane and its headless tests.
abstract class GitReviewBackend {
  Future<GitReviewSnapshot> loadSnapshot();
  Future<List<GitReviewPatch>> loadPatches(GitReviewFile file);
  Future<void> stageFile(GitReviewFile file);
  Future<void> unstageFile(GitReviewFile file);
  Future<void> stageHunk(GitReviewHunk hunk);
  Future<void> unstageHunk(GitReviewHunk hunk);
  Future<GitCommitContext> loadCommitContext();
  Future<GitCommitOutcome> commit(GitCommitDraft draft, {bool push = false});
}

/// Read/write Git operations for the review pane. Staging mutations are
/// limited to the index; commits and pushes are exposed separately so the UI
/// can keep those final actions behind explicit human approval.
class GitReviewService implements GitReviewBackend {
  final String projectPath;
  final Duration timeout;

  const GitReviewService({
    required this.projectPath,
    this.timeout = const Duration(seconds: 8),
  });

  @override
  Future<GitReviewSnapshot> loadSnapshot() async {
    final result = await _run([
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=all',
    ]);
    if (result.exitCode != 0) {
      throw GitReviewException(
        result.stderrText.isEmpty
            ? 'Unable to read git status'
            : result.stderrText,
      );
    }

    final parts = result.stdoutText.split('\u0000');
    final files = <GitReviewFile>[];
    for (var i = 0; i < parts.length; i++) {
      final entry = parts[i];
      if (entry.length < 4) continue;
      final x = entry[0];
      final y = entry[1];
      final path = entry.substring(3);
      String? oldPath;
      if (x == 'R' || x == 'C' || y == 'R' || y == 'C') {
        if (i + 1 < parts.length && parts[i + 1].isNotEmpty) {
          oldPath = parts[++i];
        }
      }
      files.add(
        GitReviewFile(
          path: path,
          oldPath: oldPath,
          indexStatus: x,
          workTreeStatus: y,
        ),
      );
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    final branchResult = await _run(['symbolic-ref', '--short', 'HEAD']);
    var branch = branchResult.exitCode == 0
        ? branchResult.stdoutText.trim()
        : '';
    if (branch.isEmpty) {
      final sha = await _run(['rev-parse', '--short', 'HEAD']);
      branch = sha.exitCode == 0 ? sha.stdoutText.trim() : '(no branch)';
    }
    return GitReviewSnapshot(branch: branch, files: files);
  }

  @override
  Future<List<GitReviewPatch>> loadPatches(GitReviewFile file) async {
    final patches = <GitReviewPatch>[];
    if (file.hasStaged) {
      final result = await _run([
        'diff',
        '--cached',
        '--no-ext-diff',
        '--no-color',
        '--find-renames',
        '--',
        file.path,
      ]);
      if (result.stdoutText.isNotEmpty) {
        patches.add(
          parseGitReviewPatch(
            result.stdoutText,
            GitReviewPatchKind.staged,
            filePath: file.path,
          ),
        );
      }
    }
    if (file.hasUnstaged && !file.isUntracked) {
      final result = await _run([
        'diff',
        '--no-ext-diff',
        '--no-color',
        '--find-renames',
        '--',
        file.path,
      ]);
      if (result.stdoutText.isNotEmpty) {
        patches.add(
          parseGitReviewPatch(
            result.stdoutText,
            GitReviewPatchKind.unstaged,
            filePath: file.path,
          ),
        );
      }
    }
    if (file.isUntracked) {
      patches.add(await _untrackedPatch(file));
    }
    return patches;
  }

  Future<GitReviewPatch> _untrackedPatch(GitReviewFile file) async {
    final diskPath = p.join(projectPath, file.path);
    final bytes = await File(diskPath).readAsBytes();
    if (bytes.contains(0)) {
      return GitReviewPatch(
        kind: GitReviewPatchKind.unstaged,
        headerLines: ['Binary file ${file.path} is untracked'],
        hunks: const [],
      );
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(text);
    final header = <String>[
      'diff --git a/${file.path} b/${file.path}',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/${file.path}',
    ];
    if (lines.isEmpty) {
      return GitReviewPatch(
        kind: GitReviewPatchKind.unstaged,
        headerLines: header,
        hunks: const [],
      );
    }
    final hunkHeader = '@@ -0,0 +1,${lines.length} @@';
    final hunkLines = [for (final line in lines) '+$line'];
    if (bytes.isNotEmpty && bytes.last != 10) {
      hunkLines.add(r'\ No newline at end of file');
    }
    final patch = '${[...header, hunkHeader, ...hunkLines].join('\n')}\n';
    return GitReviewPatch(
      kind: GitReviewPatchKind.unstaged,
      headerLines: header,
      hunks: [
        GitReviewHunk(
          header: hunkHeader,
          lines: hunkLines,
          patch: patch,
          filePath: file.path,
        ),
      ],
    );
  }

  @override
  Future<void> stageFile(GitReviewFile file) async {
    await stageFiles([file]);
  }

  Future<void> stageFiles(List<GitReviewFile> files) async {
    if (files.isEmpty) return;
    final paths = <String>{};
    for (final file in files) {
      if (file.isConflicted) {
        throw const GitReviewException('Resolve conflicts in chat first');
      }
      paths.add(file.path);
      if (file.oldPath case final oldPath?) paths.add(oldPath);
    }
    await _runChecked(['add', '-A', '--', ...paths]);
  }

  @override
  Future<void> unstageFile(GitReviewFile file) async {
    if (file.isConflicted) {
      throw const GitReviewException('Resolve conflicts in chat first');
    }
    final restore = await _run(['restore', '--staged', '--', file.path]);
    if (restore.exitCode == 0) return;
    // An unborn branch has no HEAD for `restore --staged`; removing the
    // index entry preserves the working-tree file.
    final head = await _run(['rev-parse', '--verify', 'HEAD']);
    if (head.exitCode != 0) {
      await _runChecked([
        'rm',
        '--cached',
        '--ignore-unmatch',
        '--',
        file.path,
      ]);
      return;
    }
    throw GitReviewException(
      restore.stderrText.isEmpty
          ? 'Unable to unstage ${file.path}'
          : restore.stderrText,
    );
  }

  @override
  Future<void> stageHunk(GitReviewHunk hunk) =>
      _applyLatestHunk(hunk, GitReviewPatchKind.unstaged);

  @override
  Future<void> unstageHunk(GitReviewHunk hunk) =>
      _applyLatestHunk(hunk, GitReviewPatchKind.staged, reverse: true);

  Future<void> _applyLatestHunk(
    GitReviewHunk requested,
    GitReviewPatchKind kind, {
    bool reverse = false,
  }) async {
    var hunk = requested;
    final filePath = requested.filePath;
    if (filePath != null) {
      final snapshot = await loadSnapshot();
      final matchingFiles = snapshot.files.where(
        (file) => file.path == filePath,
      );
      if (matchingFiles.isEmpty) {
        throw const GitReviewException(
          'This change is no longer available. Refresh and try again.',
        );
      }
      final patches = await loadPatches(matchingFiles.first);
      final candidates = [
        for (final patch in patches)
          if (patch.kind == kind) ...patch.hunks,
      ];
      final fingerprint = _hunkFingerprint(requested);
      final matches = candidates
          .where((candidate) => _hunkFingerprint(candidate) == fingerprint)
          .toList();
      if (matches.isEmpty) {
        throw const GitReviewException(
          'This change was updated. Review it again before staging.',
        );
      }
      matches.sort(
        (a, b) => (_hunkStart(a) - _hunkStart(requested)).abs().compareTo(
          (_hunkStart(b) - _hunkStart(requested)).abs(),
        ),
      );
      hunk = matches.first;
    }
    await _applyHunk(hunk.patch, reverse: reverse);
  }

  Future<void> _applyHunk(String patch, {bool reverse = false}) async {
    final args = <String>[
      'apply',
      '--cached',
      '--recount',
      '--whitespace=nowarn',
    ];
    if (reverse) args.add('--reverse');
    args.add('-');
    final process = await Process.start(
      'git',
      args,
      workingDirectory: projectPath,
      runInShell: false,
    );
    process.stdin.write(patch);
    await process.stdin.close();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw const GitReviewException('Git operation timed out');
    }
    final stderr = await stderrFuture;
    if (exitCode != 0) {
      throw GitReviewException(
        stderr.trim().isEmpty
            ? 'Unable to apply selected chunk'
            : stderr.trim(),
      );
    }
  }

  @override
  Future<GitCommitContext> loadCommitContext() async {
    final diff = await _run([
      'diff',
      '--cached',
      '--no-ext-diff',
      '--no-color',
      '--find-renames',
    ]);
    if (diff.exitCode != 0) {
      throw GitReviewException(diff.stderrText);
    }
    final log = await _run(['log', '-10', '--pretty=%s']);
    return GitCommitContext(
      stagedDiff: diff.stdoutText,
      recentSubjects: log.exitCode == 0
          ? const LineSplitter().convert(log.stdoutText)
          : const [],
    );
  }

  @override
  Future<GitCommitOutcome> commit(
    GitCommitDraft draft, {
    bool push = false,
  }) async {
    final title = draft.title.trim();
    final description = draft.description.trim();
    if (title.isEmpty) {
      throw const GitReviewException('Commit title is required');
    }
    if (title.contains('\n') || title.contains('\r')) {
      throw const GitReviewException('Commit title must be one line');
    }
    final context = await loadCommitContext();
    if (context.stagedDiff.trim().isEmpty) {
      throw const GitReviewException('There are no staged changes to commit');
    }

    final args = <String>['commit', '-m', title];
    if (description.isNotEmpty) args.addAll(['-m', description]);
    final commitResult = await _run(
      args,
      operationTimeout: const Duration(minutes: 2),
    );
    if (commitResult.exitCode != 0) {
      throw GitReviewException(
        commitResult.stderrText.isEmpty
            ? 'Unable to create commit'
            : commitResult.stderrText,
      );
    }
    final sha = await _run(['rev-parse', '--short', 'HEAD']);
    final hash = sha.exitCode == 0 ? sha.stdoutText.trim() : 'HEAD';
    if (push) {
      final pushResult = await _run([
        'push',
      ], operationTimeout: const Duration(minutes: 2));
      if (pushResult.exitCode != 0) {
        throw GitReviewException(
          'Commit $hash was created, but push failed: '
          '${pushResult.stderrText.isEmpty ? 'git push failed' : pushResult.stderrText}',
        );
      }
    }
    return GitCommitOutcome(commitHash: hash, pushed: push);
  }

  Future<void> _runChecked(List<String> args) async {
    final result = await _run(args);
    if (result.exitCode != 0) {
      throw GitReviewException(
        result.stderrText.isEmpty
            ? 'git ${args.join(' ')} failed'
            : result.stderrText,
      );
    }
  }

  Future<_GitReviewResult> _run(
    List<String> args, {
    Duration? operationTimeout,
  }) async {
    try {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: projectPath,
        runInShell: false,
      ).timeout(operationTimeout ?? timeout);
      return _GitReviewResult(
        result.exitCode,
        (result.stdout as String?) ?? '',
        (result.stderr as String?) ?? '',
      );
    } on TimeoutException {
      throw const GitReviewException('Git operation timed out');
    } on ProcessException catch (error) {
      throw GitReviewException(error.message);
    }
  }
}

class _GitReviewResult {
  final int exitCode;
  final String stdoutText;
  final String stderrText;

  const _GitReviewResult(this.exitCode, this.stdoutText, this.stderrText);
}

class GitReviewException implements Exception {
  final String message;
  const GitReviewException(this.message);

  @override
  String toString() => message;
}

/// Parse one-file unified diff output and create standalone per-hunk patches.
GitReviewPatch parseGitReviewPatch(
  String raw,
  GitReviewPatchKind kind, {
  String? filePath,
}) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final header = <String>[];
  final hunks = <GitReviewHunk>[];
  final trailing = <String>[];
  var index = 0;
  while (index < lines.length && !lines[index].startsWith('@@')) {
    header.add(lines[index++]);
  }
  // A per-hunk patch must not retain the full file's output blob id. That id
  // describes all hunks together and can make an otherwise valid partial
  // apply fail after the index changes elsewhere in the file.
  final applicableHeader = header
      .where((line) => !line.startsWith('index '))
      .toList();
  while (index < lines.length) {
    if (!lines[index].startsWith('@@')) {
      trailing.add(lines[index++]);
      continue;
    }
    final hunkHeader = lines[index++];
    final hunkLines = <String>[];
    while (index < lines.length && !lines[index].startsWith('@@')) {
      hunkLines.add(lines[index++]);
    }
    hunks.add(
      GitReviewHunk(
        header: hunkHeader,
        lines: hunkLines,
        patch:
            '${[...applicableHeader, hunkHeader, ...hunkLines].join('\n')}\n',
        filePath: filePath,
      ),
    );
  }
  return GitReviewPatch(
    kind: kind,
    headerLines: header,
    hunks: hunks,
    trailingLines: trailing,
  );
}

String _hunkFingerprint(GitReviewHunk hunk) => hunk.lines
    .where((line) => line.startsWith('+') || line.startsWith('-'))
    .join('\n');

int _hunkStart(GitReviewHunk hunk) {
  final match = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)').firstMatch(hunk.header);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

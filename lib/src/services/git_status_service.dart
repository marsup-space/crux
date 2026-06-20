import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

/// Snapshot of a git repository's working state.
///
/// All counts default to zero. [isRepo] is `false` when [pathProvider]
/// doesn't sit inside a git repository, in which case the rest of the
/// fields are meaningless and the UI should hide the widget.
///
/// The struct is immutable: a new instance is produced on every
/// refresh so the service can hand it out without locking and the
/// widget can compare two snapshots by `==` to skip no-op repaints.
class GitStatus {
  /// `false` when [pathProvider]'s directory is not inside a git
  /// repo (or git is not installed). When `false`, every other
  /// field is `0` / empty.
  final bool isRepo;

  /// Current branch name. Empty when [isRepo] is `false`. For a
  /// detached HEAD this is the short commit SHA (`abc1234`); for an
  /// unborn branch it's the literal string `(no branch)`.
  final String branch;

  /// Commits on the local branch that the upstream doesn't have yet
  /// (i.e. "to push"). Zero when no upstream is configured.
  final int ahead;

  /// Commits on the upstream that the local branch doesn't have
  /// yet (i.e. "to pull"). Zero when no upstream is configured.
  final int behind;

  /// Files with staged changes (modifications, additions, deletions,
  /// or renames that have been `git add`ed but not yet committed).
  final int stagedFiles;

  /// Files modified in the working tree but not yet staged.
  final int modifiedFiles;

  /// Files deleted from the working tree but not yet staged.
  final int deletedFiles;

  /// Files git doesn't yet know about.
  final int untrackedFiles;

  /// Files in an unresolved merge / rebase / cherry-pick conflict.
  final int conflictedFiles;

  /// Lines added across both staged and unstaged changes.
  final int addedLines;

  /// Lines deleted across both staged and unstaged changes.
  final int deletedLines;

  /// When this snapshot was assembled. Useful for "stale" detection
  /// in the UI and for tests.
  final DateTime fetchedAt;

  const GitStatus({
    required this.isRepo,
    required this.fetchedAt,
    this.branch = '',
    this.ahead = 0,
    this.behind = 0,
    this.stagedFiles = 0,
    this.modifiedFiles = 0,
    this.deletedFiles = 0,
    this.untrackedFiles = 0,
    this.conflictedFiles = 0,
    this.addedLines = 0,
    this.deletedLines = 0,
  });

  /// Sentinel value used before the first successful refresh and
  /// when [pathProvider] is outside a git repo. `final` rather than
  /// `const` because [DateTime] literals can't be `const`.
  static final GitStatus empty = GitStatus(
    isRepo: false,
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  bool get hasUpstream => ahead > 0 || behind > 0;
  bool get hasWorkingTreeChanges =>
      modifiedFiles > 0 || deletedFiles > 0 || untrackedFiles > 0;
  bool get hasStagedChanges => stagedFiles > 0;
  bool get hasConflicts => conflictedFiles > 0;

  /// `true` iff the repo has nothing to commit and no sync to do.
  /// We deliberately exclude `ahead`/`behind` here — having unpushed
  /// commits is not "dirty", it just means sync is pending.
  bool get isClean =>
      isRepo && !hasWorkingTreeChanges && !hasStagedChanges && !hasConflicts;

  /// Any kind of pending change that should be surfaced to the user:
  /// working-tree edits, staged changes, or merge conflicts.
  bool get hasAnyChanges =>
      hasWorkingTreeChanges || hasStagedChanges || hasConflicts;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GitStatus &&
        other.isRepo == isRepo &&
        other.branch == branch &&
        other.ahead == ahead &&
        other.behind == behind &&
        other.stagedFiles == stagedFiles &&
        other.modifiedFiles == modifiedFiles &&
        other.deletedFiles == deletedFiles &&
        other.untrackedFiles == untrackedFiles &&
        other.conflictedFiles == conflictedFiles &&
        other.addedLines == addedLines &&
        other.deletedLines == deletedLines;
  }

  @override
  int get hashCode => Object.hash(
    isRepo,
    branch,
    ahead,
    behind,
    stagedFiles,
    modifiedFiles,
    deletedFiles,
    untrackedFiles,
    conflictedFiles,
    addedLines,
    deletedLines,
  );

  @override
  String toString() =>
      'GitStatus(repo=$isRepo, branch=$branch, ahead=$ahead, '
      'behind=$behind, staged=$stagedFiles, modified=$modifiedFiles, '
      'deleted=$deletedFiles, untracked=$untrackedFiles, '
      'conflicted=$conflictedFiles, +$addedLines/-$deletedLines)';
}

/// Polls a git repository and broadcasts [GitStatus] snapshots.
///
/// The service is owned by [ChatPanel] and lives for the lifetime of
/// the TUI. It is intentionally simple — one timer, one cached
/// status, a listener callback for changes — because the surface area
/// is small and the widget tree already provides the reactive
/// plumbing.
///
/// `PathProvider` is a `String Function()` rather than a fixed
/// `String` so the service can react to `/project <path>` switches
/// without being recreated. Defaults to `Directory.current.path`,
/// which matches how the rest of the app locates the project.
class GitStatusService extends ChangeNotifier {
  /// Hard cap on how long any single `git` invocation can take. The
  /// porcelain / shortstat commands are normally sub-100ms even on
  /// large repos, but a pathological setup (huge ignored tree,
  /// network filesystem, slow antivirus) could hang. Bailing out
  /// after [kCommandTimeout] lets the UI fall back to the previous
  /// snapshot instead of blocking the timer forever.
  static const Duration kCommandTimeout = Duration(seconds: 4);

  /// How often the timer fires a background refresh. 60s is
  /// intentionally lazy — the user typically edits files via the
  /// agent (which triggers an event-driven refresh in
  /// [ChatTurnOrchestrator] after an `edit`/`write` tool round, and
  /// again unconditionally on agent turn end to catch shell-driven
  /// mutations), so a 1-minute tick is enough to catch out-of-band
  /// mutations (manual edits in another window, a `git` command
  /// run by hand, branch switches). Drops the idle-repo
  /// `git status` cost by 12x versus the original 5s interval.
  static const Duration kDefaultRefreshInterval = Duration(seconds: 60);

  /// Resolves the directory to query. Invoked on every refresh, so
  /// a `/project <path>` switch is picked up automatically on the
  /// next tick without the chat panel needing to poke us.
  final String Function() _pathProvider;

  final Duration _interval;
  Timer? _timer;
  GitStatus _status;
  bool _refreshing = false;
  bool _disposed = false;

  GitStatusService({
    String Function()? pathProvider,
    Duration refreshInterval = kDefaultRefreshInterval,
  }) : _pathProvider = pathProvider ?? _defaultPathProvider,
       _interval = refreshInterval,
       _status = GitStatus.empty;

  /// The most recent snapshot. Safe to read from any context —
  /// never mutated in place, always replaced atomically before
  /// [notifyListeners] fires.
  GitStatus get current => _status;

  /// Start the periodic refresh. Idempotent — calling [start] while
  /// already running is a no-op. Fires one immediate refresh by default
  /// so the UI has real data as soon as possible after mount.
  void start({bool refreshImmediately = true}) {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(_interval, (_) => refresh());
    // Kick off an immediate refresh. We don't `await` here — the
    // caller is typically the panel's initState, and we don't want
    // the constructor to block on a git subprocess.
    if (refreshImmediately) refresh();
  }

  /// Stop the periodic refresh. Idempotent. Safe to call multiple
  /// times (e.g. from `didUpdateComponent` when the interval
  /// changes).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Force a refresh right now. Returns the new snapshot, but most
  /// callers should ignore the return value and rely on
  /// [ChangeNotifier] notifications instead.
  Future<GitStatus> refresh() async {
    if (_disposed) return _status;
    if (_refreshing) return _status;

    _refreshing = true;
    try {
      final path = _pathProvider();
      final next = await _fetch(path);
      if (_disposed) return next;
      // Only notify when something actually changed. Avoids waking
      // the widget tree on every timer tick for an idle repo.
      if (next != _status) {
        _status = next;
        notifyListeners();
      }
      return next;
    } catch (_) {
      // Swallow unexpected failures (ProcessException, timeouts).
      // The previous snapshot stays visible, which is the right
      // degradation: stale data beats a blank panel.
      return _status;
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }

  /// Resolve the project root from [start] by walking up until we
  /// find a `.git` directory or `.git` file (the latter covers
  /// submodules, which record their gitdir as a file rather than a
  /// directory). Returns `null` if [start] is not in a git repo.
  static Future<String?> _findRepoRoot(String start) async {
    if (start.isEmpty) return null;
    var dir = Directory(start);
    while (true) {
      try {
        // .git can be a directory (regular repo) or a file pointing
        // at the parent's gitdir (submodule / worktree). Either
        // form means "this directory is inside a repo".
        final gitPath = p.join(dir.path, '.git');
        if (await Directory(gitPath).exists() || await File(gitPath).exists()) {
          return dir.path;
        }
      } catch (_) {
        // Permission errors, broken symlinks, etc. — treat as
        // "no .git here" and keep walking up.
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Fetch + parse a single snapshot. Public-package-internal so
  /// tests can drive it against arbitrary working directories.
  ///
  /// Returns [GitStatus.empty] when [path] isn't in a repo or when
  /// git is not installed. The distinction between "not a repo" and
  /// "repo but errored" is preserved via [isRepo]: errors leave
  /// [isRepo] `true` so the UI can still show the branch line plus
  /// an error indicator if it wants to.
  Future<GitStatus> _fetch(String path) async {
    final repoRoot = await _findRepoRoot(path);
    if (repoRoot == null) return GitStatus.empty;

    // Run the three git commands concurrently. They share no state
    // and `git status --branch` only writes to its own process
    // index, so parallelising them is safe and roughly 3x faster
    // than serialising them on a cold cache.
    final statusFut = _runGit([
      'status',
      '--porcelain=v1',
      '--branch',
      '--untracked-files=normal',
    ], cwd: repoRoot);
    final unstagedFut = _runGit(['diff', '--shortstat'], cwd: repoRoot);
    final stagedFut = _runGit([
      'diff',
      '--cached',
      '--shortstat',
    ], cwd: repoRoot);

    final statusResult = await statusFut;
    if (statusResult.exitCode != 0) {
      // Repo exists but `git status` failed (corrupt index, missing
      // objects, permission denied). Surface the failure with
      // [isRepo]=true so the branch name is still shown when we
      // can recover it from a second pass.
      return GitStatus(
        isRepo: true,
        branch: await _safeBranchName(repoRoot),
        fetchedAt: DateTime.now(),
      );
    }

    final unstagedResult = await unstagedFut;
    final stagedResult = await stagedFut;

    return parse(
      porcelain: statusResult.stdout,
      unstagedShortstat: unstagedResult.stdout,
      stagedShortstat: stagedResult.stdout,
      fetchedAt: DateTime.now(),
      branchFallback: await _safeBranchName(repoRoot),
    );
  }

  /// Try to read the branch name with a separate, narrow command.
  /// Used as a fallback when `git status` errors out so the branch
  /// line still has something useful to display.
  Future<String> _safeBranchName(String repoRoot) async {
    try {
      final r = await _runGit([
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], cwd: repoRoot);
      if (r.exitCode != 0) return '';
      final name = r.stdout.trim();
      // `git rev-parse --abbrev-ref HEAD` returns the literal
      // string `HEAD` when on a detached HEAD. The porcelain
      // `--branch` output uses the short SHA instead, so we fall
      // back to that for parity.
      if (name == 'HEAD') {
        final sha = await _runGit([
          'rev-parse',
          '--short',
          'HEAD',
        ], cwd: repoRoot);
        return sha.exitCode == 0 ? sha.stdout.trim() : 'HEAD';
      }
      return name;
    } catch (_) {
      return '';
    }
  }

  /// Run a `git` subprocess with a timeout. Returns a [ProcessResult]
  /// even on timeout (exitCode = -1, stdout = '') so the caller
  /// doesn't have to deal with a separate exception path.
  Future<_GitResult> _runGit(List<String> args, {required String cwd}) async {
    try {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: cwd,
        // `runInShell: true` would let users point at a non-git
        // binary via PATH-aliasing. We want the real git, so we
        // pass `false` (the default) and rely on the system PATH.
      ).timeout(kCommandTimeout);
      return _GitResult(
        exitCode: result.exitCode,
        stdout: (result.stdout as String?) ?? '',
      );
    } on TimeoutException {
      return _GitResult(exitCode: -1, stdout: '');
    } on ProcessException {
      // `git` not on PATH, or other Process-level failure.
      return _GitResult(exitCode: -1, stdout: '');
    }
  }

  /// Parse the three git outputs into a [GitStatus]. Exposed for
  /// unit tests so we can drive it with synthetic git output
  /// without spawning a real subprocess.
  static GitStatus parse({
    required String porcelain,
    required String unstagedShortstat,
    required String stagedShortstat,
    required DateTime fetchedAt,
    String branchFallback = '',
  }) {
    var branch = branchFallback;
    var ahead = 0;
    var behind = 0;
    var stagedFiles = 0;
    var modifiedFiles = 0;
    var deletedFiles = 0;
    var untrackedFiles = 0;
    var conflictedFiles = 0;

    var branchLineSeen = false;

    for (final rawLine in porcelain.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (line.isEmpty) continue;

      if (line.startsWith('## ')) {
        final info = _parseBranchLine(line.substring(3));
        branch = info.branch;
        ahead = info.ahead;
        behind = info.behind;
        branchLineSeen = true;
        continue;
      }

      if (line.length < 2) continue;
      final x = line[0];
      final y = line[1];

      if (x == '?' && y == '?') {
        untrackedFiles++;
      } else if (x == '!' && y == '!') {
        // Ignored — surfaced by `git status --ignored` which we
        // don't request, so this branch is defensive.
      } else if (x == 'U' || y == 'U') {
        conflictedFiles++;
      } else {
        // Index status: anything non-space, non-`?` means the file
        // is staged. Renames (`R `) and copies (`C `) land here.
        if (x != ' ' && x != '?') stagedFiles++;
        // Worktree status: `M` for modified, `D` for deleted.
        if (y == 'M') {
          modifiedFiles++;
        } else if (y == 'D') {
          deletedFiles++;
        }
        // Other worktree codes (`A` added in WT, `R` renamed in
        // WT) are rare and don't affect "needs to commit" — skip.
      }
    }

    // If the porcelain output was empty (clean repo) we still want
    // a sensible branch name. The branch line is always emitted by
    // `git status --branch` even on a clean repo, so
    // branchLineSeen is effectively always true; the check is
    // defensive against an empty stdout from a broken git.
    if (!branchLineSeen && branch.isEmpty) {
      branch = branchFallback;
    }

    final addedLines =
        _sumInsertions(unstagedShortstat) + _sumInsertions(stagedShortstat);
    final deletedLines =
        _sumDeletions(unstagedShortstat) + _sumDeletions(stagedShortstat);

    return GitStatus(
      isRepo: true,
      branch: branch,
      ahead: ahead,
      behind: behind,
      stagedFiles: stagedFiles,
      modifiedFiles: modifiedFiles,
      deletedFiles: deletedFiles,
      untrackedFiles: untrackedFiles,
      conflictedFiles: conflictedFiles,
      addedLines: addedLines,
      deletedLines: deletedLines,
      fetchedAt: fetchedAt,
    );
  }

  /// Pull the insertion count out of a `git diff --shortstat` line
  /// like `3 files changed, 12 insertions(+), 5 deletions(-)`.
  /// Returns 0 when the line is empty (no diff).
  static int _sumInsertions(String shortstat) {
    final m = RegExp(r'(\d+) insertions?\(\+\)').firstMatch(shortstat);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Same as [_sumInsertions] but for deletions.
  static int _sumDeletions(String shortstat) {
    final m = RegExp(r'(\d+) deletions?\(-\)').firstMatch(shortstat);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Parse the `## branch...upstream [ahead N, behind M]` line that
  /// `git status --branch` always emits as the first line of the
  /// porcelain output. The full grammar (from `git-status` docs):
  ///
  ///   `## <branch>`                         (no upstream)
  ///   `## <branch>...<upstream>`            (clean, in sync)
  ///   `## <branch>...<upstream> [ahead N]`
  ///   `## <branch>...<upstream> [behind N]`
  ///   `## <branch>...<upstream> [ahead N, behind M]`
  ///   `## (detached at <sha>)`              (detached HEAD)
  ///   `## (no branch)`                      (unborn branch)
  static _BranchInfo _parseBranchLine(String body) {
    if (body.startsWith('(detached at ')) {
      final end = body.indexOf(')');
      final sha = end > '(detached at '.length
          ? body.substring('(detached at '.length, end)
          : '';
      return _BranchInfo(branch: sha, ahead: 0, behind: 0);
    }
    if (body.startsWith('(no branch)')) {
      return const _BranchInfo(branch: '(no branch)', ahead: 0, behind: 0);
    }

    var rest = body;
    var ahead = 0;
    var behind = 0;

    // The optional `[ahead N, behind M]` suffix. Strip it off
    // before splitting on `...` so the upstream name doesn't get
    // polluted by the trailing bracket text.
    final bracket = RegExp(r' \[(.+?)\]\s*$').firstMatch(rest);
    if (bracket != null) {
      final inner = bracket.group(1)!;
      rest = rest.substring(0, bracket.start);
      final aheadMatch = RegExp(r'ahead (\d+)').firstMatch(inner);
      final behindMatch = RegExp(r'behind (\d+)').firstMatch(inner);
      if (aheadMatch != null) ahead = int.parse(aheadMatch.group(1)!);
      if (behindMatch != null) behind = int.parse(behindMatch.group(1)!);
    }

    final sepIdx = rest.indexOf('...');
    final branch = sepIdx < 0 ? rest : rest.substring(0, sepIdx);
    return _BranchInfo(branch: branch, ahead: ahead, behind: behind);
  }

  static String _defaultPathProvider() => Directory.current.path;
}

class _GitResult {
  final int exitCode;
  final String stdout;
  const _GitResult({required this.exitCode, required this.stdout});
}

class _BranchInfo {
  final String branch;
  final int ahead;
  final int behind;
  const _BranchInfo({
    required this.branch,
    required this.ahead,
    required this.behind,
  });
}

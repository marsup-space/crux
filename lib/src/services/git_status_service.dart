import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

  /// JSON representation for cross-isolate transfer. The git-status
  /// isolate sends snapshots to the main isolate as a map of
  /// primitives so [GitStatus] (which is otherwise immutable but not
  /// natively transferable) can cross the isolate boundary without
  /// needing a hand-written copy constructor.
  Map<String, dynamic> toJson() => {
        'isRepo': isRepo,
        'fetchedAt': fetchedAt.millisecondsSinceEpoch,
        'branch': branch,
        'ahead': ahead,
        'behind': behind,
        'stagedFiles': stagedFiles,
        'modifiedFiles': modifiedFiles,
        'deletedFiles': deletedFiles,
        'untrackedFiles': untrackedFiles,
        'conflictedFiles': conflictedFiles,
        'addedLines': addedLines,
        'deletedLines': deletedLines,
      };

  /// Inverse of [toJson]. Tolerant of missing keys (defaults match
  /// the constructor) so older snapshots from before a field was
  /// added still deserialise cleanly.
  factory GitStatus.fromJson(Map<String, dynamic> json) => GitStatus(
        isRepo: json['isRepo'] as bool? ?? false,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          json['fetchedAt'] as int? ?? 0,
        ),
        branch: json['branch'] as String? ?? '',
        ahead: json['ahead'] as int? ?? 0,
        behind: json['behind'] as int? ?? 0,
        stagedFiles: json['stagedFiles'] as int? ?? 0,
        modifiedFiles: json['modifiedFiles'] as int? ?? 0,
        deletedFiles: json['deletedFiles'] as int? ?? 0,
        untrackedFiles: json['untrackedFiles'] as int? ?? 0,
        conflictedFiles: json['conflictedFiles'] as int? ?? 0,
        addedLines: json['addedLines'] as int? ?? 0,
        deletedLines: json['deletedLines'] as int? ?? 0,
      );
}

// ─────────────────────────────────────────────────────────────────────
// Isolate plumbing
//
// The actual `git` subprocess work AND the porcelain parsing run in
// their own long-lived isolate ([_gitIsolateEntry]). The main isolate
// only talks to it via [_GitCommand] messages on a SendPort and
// receives [_GitResponse] messages back.
//
// Why isolate at all? `Process.run` is non-blocking on the main isolate
// (the subprocess runs in its own OS process), but three things still
// cost main-isolate time when a fetch happens:
//   1. The I/O wait for the three `git` commands to finish.
//   2. The porcelain parser — regex + string split on potentially
//      multi-megabyte output for a large repo.
//   3. The line-diff shortstat regex.
// All three move to the git isolate so the main isolate's frame loop
// only pays for a SendPort hop (microseconds) per refresh, regardless
// of repo size or git command latency. This matters because the
// widget tree reacts to every notification on the main isolate.
// ─────────────────────────────────────────────────────────────────────

/// Entry point for the long-lived git-status isolate. Receives a
/// [SendPort] from main, opens its own command port, sends a `ready`
/// handshake back, and then runs the command loop forever (or until
/// it receives a `dispose` command).
void _gitIsolateEntry(SendPort mainSendPort) {
  final commandPort = ReceivePort();
  mainSendPort.send(['ready', commandPort.sendPort]);

  const commandTimeout = Duration(seconds: 4);
  Duration interval = const Duration(seconds: 60);
  Timer? timer;
  var currentPath = '';
  var cachedStatus = GitStatus.empty;
  var refreshing = false;

  void doFetch(String path) {
    if (refreshing) {
      // Coalesce: a refresh is already in flight. Return the latest
      // cached snapshot immediately so the main isolate doesn't
      // hang on a Completer. Mirrors the pre-isolate behaviour where
      // a second `refresh()` returned `_status` synchronously.
      mainSendPort.send(['status', cachedStatus.toJson()]);
      return;
    }
    refreshing = true;
    _gitFetchAndParse(path, commandTimeout).then((status) {
      cachedStatus = status;
      mainSendPort.send(['status', status.toJson()]);
    }).catchError((Object e) {
      mainSendPort.send(['error', e.toString()]);
    }).whenComplete(() {
      refreshing = false;
    });
  }

  commandPort.listen((message) {
    if (message is! List || message.isEmpty) return;
    final cmd = message[0];
    switch (cmd) {
      case 'start':
        interval = Duration(milliseconds: message[1] as int);
        currentPath = message[2] as String;
        timer?.cancel();
        timer = Timer.periodic(interval, (_) => doFetch(currentPath));
        if (message[3] as bool) doFetch(currentPath);
      case 'refresh':
        final path = message[1] as String;
        currentPath = path;
        doFetch(path);
      case 'stop':
        timer?.cancel();
        timer = null;
      case 'dispose':
        timer?.cancel();
        commandPort.close();
        mainSendPort.send('disposed');
    }
  });
}

/// Fetch + parse for a single path. Runs entirely inside the
/// git-status isolate; never touches the main isolate. Returns
/// [GitStatus.empty] when [path] isn't in a repo or when git is not
/// installed. The distinction between "not a repo" and "repo but
/// errored" is preserved via [isRepo]: errors leave [isRepo] `true`
/// so the UI can still show the branch line plus an error indicator
/// if it wants to.
Future<GitStatus> _gitFetchAndParse(
  String path,
  Duration commandTimeout,
) async {
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
  ], cwd: repoRoot, commandTimeout: commandTimeout);
  final unstagedFut = _runGit(
    ['diff', '--shortstat'],
    cwd: repoRoot,
    commandTimeout: commandTimeout,
  );
  final stagedFut = _runGit([
    'diff',
    '--cached',
    '--shortstat',
  ], cwd: repoRoot, commandTimeout: commandTimeout);

  final statusResult = await statusFut;
  if (statusResult.exitCode != 0) {
    // Repo exists but `git status` failed (corrupt index, missing
    // objects, permission denied). Surface the failure with
    // [isRepo]=true so the branch name is still shown when we
    // can recover it from a second pass.
    return GitStatus(
      isRepo: true,
      branch: await _safeBranchName(repoRoot, commandTimeout),
      fetchedAt: DateTime.now(),
    );
  }

  final unstagedResult = await unstagedFut;
  final stagedResult = await stagedFut;

  return GitStatusService.parse(
    porcelain: statusResult.stdout,
    unstagedShortstat: unstagedResult.stdout,
    stagedShortstat: stagedResult.stdout,
    fetchedAt: DateTime.now(),
    branchFallback: await _safeBranchName(repoRoot, commandTimeout),
  );
}

/// Resolve the project root from [start] by walking up until we
/// find a `.git` directory or `.git` file (the latter covers
/// submodules, which record their gitdir as a file rather than a
/// directory). Returns `null` if [start] is not in a git repo.
Future<String?> _findRepoRoot(String start) async {
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

/// Try to read the branch name with a separate, narrow command.
/// Used as a fallback when `git status` errors out so the branch
/// line still has something useful to display.
Future<String> _safeBranchName(
  String repoRoot,
  Duration commandTimeout,
) async {
  try {
    final r = await _runGit([
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], cwd: repoRoot, commandTimeout: commandTimeout);
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
      ], cwd: repoRoot, commandTimeout: commandTimeout);
      return sha.exitCode == 0 ? sha.stdout.trim() : 'HEAD';
    }
    return name;
  } catch (_) {
    return '';
  }
}

/// Run a `git` subprocess with a timeout. Returns a [_GitResult]
/// even on timeout (exitCode = -1, stdout = '') so the caller
/// doesn't have to deal with a separate exception path.
Future<_GitResult> _runGit(
  List<String> args, {
  required String cwd,
  required Duration commandTimeout,
}) async {
  try {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: cwd,
      // `runInShell: true` would let users point at a non-git
      // binary via PATH-aliasing. We want the real git, so we
      // pass `false` (the default) and rely on the system PATH.
    ).timeout(commandTimeout);
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

/// Polls a git repository and broadcasts [GitStatus] snapshots.
///
/// The service is owned by [ChatPanel] and lives for the lifetime of
/// the TUI. All `git` subprocess work and porcelain parsing run in a
/// dedicated [_gitIsolateEntry] isolate so the main isolate's frame
/// loop is never blocked by a `git status` walk or a multi-megabyte
/// porcelain parse — even on a pathologically large repo with a
/// 4-second timeout. The main isolate only pays for a SendPort hop
/// (microseconds) per refresh.
///
/// The public API matches the pre-isolate version ([start], [stop],
/// [refresh], [current], [dispose]) so callers don't need to know
/// about the isolate plumbing. The widget tree subscribes via
/// [ChangeNotifier] exactly as before.
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

  /// Resolves the directory to query. Invoked on the main isolate
  /// on every refresh / start, and the resulting string is shipped
  /// across the isolate boundary to the git isolate. Closures can't
  /// cross isolate boundaries, so the path is always resolved on the
  /// main isolate where [Directory] and the path provider closure
  /// are available.
  final String Function() _pathProvider;

  final Duration _interval;
  GitStatus _status;
  bool _disposed = false;

  // Isolate plumbing.
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;

  /// Pending `refresh()` calls waiting for a snapshot back from the
  /// git isolate. FIFO. The git isolate sends one `status` message
  /// per `refresh` command (or one per coalesced refresh while a
  /// fetch is in flight), so the main isolate resolves one Completer
  /// per incoming status. A `dispose()` call drains the queue with
  /// the last-known status so awaiting callers don't hang.
  final List<Completer<GitStatus>> _pending = [];

  /// One-shot guard for the `ready` handshake from [_gitIsolateEntry].
  /// Set true the first time the isolate sends `['ready', port]`,
  /// preventing a late duplicate (shouldn't happen but defensive)
  /// from racing with [refresh].
  bool _isolateReady = false;

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
  ///
  /// Lazily spawns the git isolate on first call. Subsequent calls
  /// (and [refresh] calls) reuse the same isolate, so the timer
  /// keeps running across multiple invocations.
  void start({bool refreshImmediately = true}) {
    if (_disposed || _isolate != null) return;
    _spawnIsolate().then((port) {
      port.send([
        'start',
        _interval.inMilliseconds,
        refreshImmediately,
        _pathProvider(),
      ]);
    });
  }

  /// Stop the periodic refresh. Idempotent. Safe to call multiple
  /// times (e.g. from `didUpdateComponent` when the interval
  /// changes). Keeps the isolate alive — only the timer is cancelled.
  void stop() {
    _commands?.send('stop');
  }

  /// Force a refresh right now. Returns the new snapshot, but most
  /// callers should ignore the return value and rely on
  /// [ChangeNotifier] notifications instead.
  ///
  /// If the isolate isn't running yet (no [start] was called), this
  /// lazily spawns it and waits for the handshake before sending the
  /// command — so the very first `refresh()` from `bin/crux.dart`'s
  /// boot path doesn't race the isolate setup.
  Future<GitStatus> refresh() async {
    if (_disposed) return _status;
    final completer = Completer<GitStatus>();
    _pending.add(completer);
    if (_isolate == null) {
      _spawnIsolate().then((port) {
        if (_disposed) return;
        port.send(['refresh', _pathProvider()]);
      });
    } else {
      _commands!.send(['refresh', _pathProvider()]);
    }
    return completer.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Stop the timer first so the isolate isn't doing work while we
    // tear the channel down. Then ask politely for a shutdown; if
    // the ack doesn't arrive within a short window we force-kill.
    _commands?.send('stop');
    _commands?.send('dispose');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _responses?.close();
    _responses = null;
    _commands = null;
    // Drain any in-flight refreshes with the last-known status so
    // awaiting callers don't hang on a disposed service.
    for (final c in _pending) {
      if (!c.isCompleted) c.complete(_status);
    }
    _pending.clear();
    super.dispose();
  }

  /// Spawn the git isolate and wire up its response channel. Resolves
  /// with the isolate's command [SendPort] as soon as the handshake
  /// completes; safe to call multiple times (subsequent calls are
  /// idempotent until the isolate dies).
  Future<SendPort> _spawnIsolate() async {
    if (_isolate != null && _isolateReady) {
      // Re-entry shouldn't normally happen, but if it does (e.g. a
      // double-tap of `start()` after the isolate's already up),
      // resolve immediately rather than spawning a second one.
      return _commands!;
    }
    final completer = Completer<SendPort>();
    final responses = ReceivePort();
    responses.listen((message) {
      // After `dispose()` runs we still drain anything the isolate
      // managed to send before our `kill` reached it. Guard every
      // branch with `_disposed` so we don't touch
      // [ChangeNotifier.notifyListeners] on a disposed service (the
      // base class asserts in debug builds).
      if (message is List && message.length == 2 && message[0] == 'ready') {
        _commands = message[1] as SendPort;
        _isolateReady = true;
        if (!completer.isCompleted) completer.complete(_commands!);
      } else if (message is List &&
          message.length == 2 &&
          message[0] == 'status') {
        if (_disposed) return;
        final newStatus = GitStatus.fromJson(
          (message[1] as Map).cast<String, dynamic>(),
        );
        if (newStatus != _status) {
          _status = newStatus;
          notifyListeners();
        }
        if (_pending.isNotEmpty) {
          final c = _pending.removeAt(0);
          if (!c.isCompleted) c.complete(newStatus);
        }
      } else if (message is List &&
          message.length == 2 &&
          message[0] == 'error') {
        // Swallow git-isolate errors. The previous snapshot stays
        // visible (matches the pre-isolate behaviour: stale data
        // beats a blank panel).
      } else if (message == 'disposed') {
        // Isolate confirmed shutdown. Close the response port and
        // reset state so a future `refresh()` respawns cleanly.
        responses.close();
        if (_isolateReady) {
          _isolateReady = false;
          _commands = null;
        }
      }
    });
    _responses = responses;
    _isolate = await Isolate.spawn(
      _gitIsolateEntry,
      responses.sendPort,
      debugName: 'git-status',
    );
    return completer.future;
  }

  /// Parse the three git outputs into a [GitStatus]. Exposed for
  /// unit tests so we can drive it with synthetic git output
  /// without spawning a real subprocess (and without spinning up
  /// the git isolate). Called from the git isolate too — both
  /// contexts can reach the static method since they share the same
  /// loaded library.
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
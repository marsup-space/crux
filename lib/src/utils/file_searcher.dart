import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'bundled_executable.dart';
import 'fuzzy_match.dart';
import 'gitignore.dart';

/// A single file/directory match returned by [FileSearcher.search].
class FileMatch {
  /// Path relative to the search root (e.g. "lib/main.dart", "src/").
  final String relativePath;

  /// Path type.
  final FileMatchKind kind;

  /// Fuzzy-search score (higher = better match).
  final int score;

  const FileMatch({
    required this.relativePath,
    required this.kind,
    required this.score,
  });

  /// True if this match is a directory. Convenience for callers
  /// that want to handle the two kinds differently (e.g. the
  /// @-mention popover drills into directories on right-arrow).
  bool get isDirectory => kind == FileMatchKind.directory;
}

enum FileMatchKind { file, directory }

/// Recursive, cached, fuzzy file/directory searcher for a single
/// project root.
///
/// Index building and per-keystroke scoring run on a background
/// worker isolate; the main (UI) isolate never walks the tree or
/// scores paths. Performance characteristics for a 50k-file
/// project (the times are worker-isolate costs — the UI thread
/// only waits on the port callback that receives the finished
/// result):
///
/// | Op                              | Time       |
/// |---------------------------------|------------|
/// | First index build (in-process)  | ~200-500ms |
/// | First index build (with `rg`)   | ~30-80ms   |
/// | Per-keystroke search            | ~5-15ms    |
/// | Memory (50k paths)              | ~8MB       |
///
/// Indexing is async — [ready] exposes the in-flight future so the
/// chat input can show a "Searching..." placeholder while the first
/// walk runs. When the worker finishes a build it ships one
/// immutable snapshot back to the main isolate, so the synchronous
/// [search] API (and the empty-query "first N files" path) keep
/// working from a local mirror. Subsequent searches are
/// synchronous once the index is warm; per-keystroke work is
/// purely in-memory.
///
/// Skip list: hidden files/dirs (`.git`, `.build`, etc.),
/// `node_modules`, `target`, `build`, `dist`, `.dart_tool`, plus
/// any common binary/lock file. The same set opencode uses, tuned
/// for the kind of projects a TUI coding agent usually sees.
///
/// No artificial cap. For truly huge trees (kernel source, etc.)
/// the index build may take seconds — the [isIndexing] flag lets
/// the UI show a progress placeholder rather than silently
/// truncating results.
/// One `.gitignore` file encountered during the sweep, with the
/// relative directory it lives in. The matcher consults this
/// when answering "would this path be ignored if it appeared
/// under this directory?" — the directory is the scope inside
/// which the patterns are evaluated.
class FileSearcher {
  /// Absolute path of the project root we're indexing.
  final String rootPath;

  /// Whether to try `rg --files` first. Falls back to the in-process
  /// walker if ripgrep isn't on $PATH. Defaults to true because
  /// ripgrep is the only realistic option for 50k+ file trees.
  final bool preferRipgrep;

  /// All paths indexed, relative to [rootPath], in stable (sorted)
  /// order. Lazily populated by [_buildIndex].
  List<String>? _paths;

  /// Pre-computed lowercase of every path in [_paths], parallel
  /// array. Saves an O(L) `toLowerCase` per path per keystroke.
  List<String>? _lower;

  /// Pre-computed basename of every path in [_paths], parallel
  /// array. Stored lowercased so the case-insensitive basename
  /// comparisons in [_score] are O(L) without an allocation per
  /// keystroke. The original-case form is still available via
  /// [_paths] for display — we only need the lowercased form for
  /// matching, since `@battlemode.cs` should hit `Battlemode.cs`.
  List<String>? _basenames;

  /// Pre-computed isDirectory flag for every path in [_paths].
  /// Paths in the index that end with the platform separator are
  /// directories (see [_walk] and `_ripgrepLinesToPaths`).
  List<bool>? _isDir;

  /// Pre-computed lowercased initials of every path in [_paths],
  /// including all path components (e.g., `lib/src/BattleMode.cs`
  /// → `lsbmc`). Parallel to [_paths] so search can index-lookup
  /// without per-keystroke computation. Powers acronym-style
  /// matching (typing `lsfsd` finds `lib/src/file_searcher.dart`).
  List<String>? _initials;

  /// Pre-computed lowercased initials of just the basename
  /// (e.g., `lib/src/BattleMode.cs` → `bmc`). Parallel to
  /// [_paths]. Used to rank basename-initials matches above
  /// path-initials matches — typing `bm` should put
  /// `lib/BattleMode.cs` above `lib/foo_bar_manager.cs`
  /// (whose path initials start with `lbm` but whose basename
  /// initials are `fbm`).
  List<String>? _basenameInitials;

  /// True while the index build is in flight. The chat input reads
  /// this to show "Searching..." in the popover header.
  bool _isIndexing = false;

  /// The in-flight index build, or null if the index is ready
  /// (or hasn't been kicked off yet). [ready] awaits this so
  /// search callers can synchronize on it. Cleared when the build
  /// finishes so a later failure can be retried.
  Future<void>? _indexingFuture;

  /// Whether the last successful index used ripgrep or the
  /// in-process walker. Useful for diagnostics.
  bool _usedRipgrep = false;

  /// Long-lived worker isolate that owns the index — build *and*
  /// search. Lazily spawned on the first [ensureIndex] /
  /// [searchAsync] and reused for the lifetime of this
  /// [FileSearcher]. The worker walks the tree, sorts it, and
  /// pre-computes the parallel scoring arrays off the UI thread,
  /// then ships one immutable snapshot back to the main isolate so
  /// the synchronous [search] API keeps working from a local copy.
  _FileSearchWorker? _worker;

  /// Future that completes when [_worker]'s isolate is ready
  /// to accept requests. Cached so concurrent callers share the
  /// same await point.
  Future<void>? _workerReady;

  /// Monotonic generation counter, bumped by [invalidate]. A build
  /// started under an old generation discards its result when it
  /// lands, so a `/project` switch mid-build can't populate a
  /// stale index for the previous root.
  int _generation = 0;

  FileSearcher({required this.rootPath, this.preferRipgrep = true});

  /// True while the initial index build (or a rebuild after
  /// [invalidate]) is running. Used by the chat input to render
  /// a "Searching..." placeholder so the user knows the empty
  /// popover isn't the final state.
  bool get isIndexing => _isIndexing;

  /// Future that completes when the current index build finishes.
  /// Returns immediately if no build is in flight. Search
  /// callers `await ready` to make sure the index is warm before
  /// they read results.
  Future<void> get ready => _indexingFuture ?? Future<void>.value();

  /// Number of paths currently cached. Returns 0 if no walk has
  /// happened yet.
  int get indexSize => _paths?.length ?? 0;

  /// True if the last successful index was built by ripgrep.
  bool get usedRipgrep => _usedRipgrep;

  /// Drop the index. The next [search] (or [ensureIndex]) re-walks
  /// the tree. The chat panel calls this when the user switches
  /// the project directory (`/project`).
  void invalidate() {
    _generation++;
    _paths = null;
    _lower = null;
    _basenames = null;
    _isDir = null;
    _initials = null;
    _basenameInitials = null;
    _indexingFuture = null;
    // Drop the worker's copy too. Fire-and-forget: the request is
    // serialized in the worker ahead of any follow-up build, so
    // ordering is safe even if the next [ensureIndex] races us.
    _worker?.invalidate().catchError((_) {});
  }

  /// Stop the background worker isolate, if one was spawned.
  ///
  /// The searcher remains usable after this; a later [searchAsync]
  /// call will lazily create a fresh worker.
  void dispose() {
    _worker?.dispose();
    _worker = null;
    _workerReady = null;
    _generation++;
  }

  /// Kick off indexing if it hasn't started yet (or if [invalidate]
  /// was called). Idempotent — multiple callers `await`ing
  /// [ensureIndex] share the same future. Safe to call from a
  /// microtask: it just creates a Future.value() if there's
  /// nothing to do.
  Future<void> ensureIndex() {
    final inFlight = _indexingFuture;
    if (inFlight != null) return inFlight;
    if (_paths != null) {
      // Already built and not invalidated.
      return Future<void>.value();
    }
    _isIndexing = true;
    final future = _buildIndexRemote();
    _indexingFuture = future;
    // The build swallows errors itself (it resets the worker and
    // lets a later call retry), but guard anyway so a fire-and-
    // forget caller like `_showAtMention` can't produce an
    // unhandled async error.
    unawaited(
      future.catchError((_) {}).whenComplete(() {
        _isIndexing = false;
        if (identical(_indexingFuture, future)) _indexingFuture = null;
      }),
    );
    return future;
  }

  /// Build the index inside the worker isolate, then mirror the
  /// finished snapshot back onto the main isolate.
  ///
  /// Walking the tree (ripgrep or the in-process fallback), the
  /// sort, and every per-path pre-computation run off the UI
  /// thread; the main isolate only receives the immutable result
  /// via the port callback. This is what keeps the first `@` on a
  /// big project from freezing the terminal.
  Future<void> _buildIndexRemote() async {
    final gen = _generation;
    try {
      await _ensureWorker();
      final worker = _worker;
      if (worker == null) return;
      final snapshot = await worker.build(
        rootPath,
        preferRipgrep: preferRipgrep,
      );
      if (gen != _generation) return;
      _applySnapshot(snapshot);
    } catch (_) {
      // Worker died or timed out — drop it so the next call
      // respawns fresh. [ensureIndex] clears [_indexingFuture] on
      // completion, so a later call simply retries the build.
      _worker?.dispose();
      _worker = null;
      _workerReady = null;
    }
  }

  void _applySnapshot(_WorkerIndexSnapshot snapshot) {
    _paths = snapshot.paths;
    _lower = snapshot.lower;
    _basenames = snapshot.basenames;
    _initials = snapshot.initials;
    _basenameInitials = snapshot.basenameInitials;
    _isDir = snapshot.isDir;
    _usedRipgrep = snapshot.usedRipgrep;
  }

  /// Fuzzy-search the indexed tree for [query]. Returns up to
  /// [limit] matches, sorted by descending score.
  ///
  /// This is the synchronous, hot-path variant. The caller is
  /// expected to have `await`-ed [ready] first; if the index
  /// isn't ready, we return an empty list and let the caller's
  /// "Searching..." placeholder do the talking.
  ///
  /// Scoring tiers (highest first), designed so filename matches
  /// always outrank path-only matches:
  ///
  /// | Tier                              | Base score |
  /// |-----------------------------------|------------|
  /// | Exact basename match              | 5000       |
  /// | Filename prefix match             | 4000       |
  /// | Filename substring match          | 3000       |
  /// | Filename initials prefix match    | 2500       |
  /// | Filename initials subseq match    | 2200       |
  /// | Path substring match              | 2000       |
  /// | Path initials prefix match        | 1700       |
  /// | Path initials subseq match        | 1400       |
  /// | Subsequence match                 | 1000       |
  ///
  /// The exact basename tier means typing `@main.dart` ranks
  /// the file `main.dart` above `lib/main.dart` /
  /// `old/main.dart` (which share the basename but aren't
  /// exact). Every filename tier also outranks every path tier,
  /// so a weak basename hit still beats a strong path hit —
  /// matching the @-mention UX where the user is naming a file,
  /// not navigating to a directory.
  ///
  /// The initials tiers catch acronym-style matching: typing
  /// `@bm` finds `BattleMode.cs` because `bm` is a prefix of
  /// the basename initials `bmc`. Initials are computed from
  /// word boundaries (camelCase, snake_case, kebab-case, dot,
  /// path separators), so users can navigate by typing the
  /// first letter of each word in the file or path name. If a
  /// literal file or directory named `bm` exists, it ranks
  /// above `BattleMode.cs` (exact-basename tier outranks the
  /// initials tiers), so exact matches always win.
  List<FileMatch> search(String query, {int limit = 10}) {
    final paths = _paths;
    if (paths == null || paths.isEmpty) return const [];

    final q = query.trim();
    if (q.isEmpty) {
      return _emptyQueryResults(limit);
    }
    return _scoredQueryResults(q, limit);
  }

  /// Async variant of [search] that runs the scoring loop in the
  /// long-lived worker isolate. This keeps the UI isolate responsive
  /// while the user types into the @-mention file browser.
  ///
  /// The synchronous [search] method remains available for tests and
  /// small callers. Both methods score the same snapshot with the
  /// same implementation, so their result order is identical.
  Future<List<FileMatch>> searchAsync(String query, {int limit = 10}) async {
    final paths = _paths;
    if (paths == null || paths.isEmpty) {
      // No local snapshot yet (first mention, or [invalidate] raced
      // us). Make sure a build is running and wait for it — the
      // popover's "Searching..." placeholder covers the wait.
      await ensureIndex();
      if (_paths == null) return const [];
    }

    final q = query.trim();
    if (q.isEmpty) {
      return _emptyQueryResults(limit);
    }

    try {
      await _ensureWorker();
      final worker = _worker;
      if (worker == null) return _scoredQueryResults(q, limit);
      return await worker.search(q, limit: limit);
    } catch (_) {
      // Isolate died or timed out — drop it so the next call
      // respawns fresh, and fall back to the in-isolate scorer.
      _worker?.dispose();
      _worker = null;
      _workerReady = null;
      return _scoredQueryResults(q, limit);
    }
  }

  Future<void> _ensureWorker() {
    if (_worker != null) return Future<void>.value();
    final ready = _workerReady;
    if (ready != null) return ready;
    final completer = Completer<void>();
    _workerReady = completer.future;
    _FileSearchWorker.spawn().then(
      (worker) {
        _worker = worker;
        completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        _workerReady = null;
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  List<FileMatch> _emptyQueryResults(int limit) {
    final paths = _paths!;
    final isDir = _isDir!;
    return List<FileMatch>.generate(
      paths.length < limit ? paths.length : limit,
      (i) => FileMatch(
        relativePath: paths[i],
        kind: isDir[i] ? FileMatchKind.directory : FileMatchKind.file,
        score: 0,
      ),
    );
  }

  List<FileMatch> _scoredQueryResults(String q, int limit) {
    final paths = _paths!;
    final lower = _lower!;
    final basenames = _basenames!;
    final initials = _initials!;
    final basenameInitials = _basenameInitials!;
    final isDir = _isDir!;
    final n = paths.length;
    final ql = q.toLowerCase();

    // Top-K via a fixed-size, sorted-descending list. We avoid a
    // full O(N log N) sort — for N=50k and K=10 that's the
    // difference between ~50k * log(10) ≈ 166k comparisons and
    // ~50k * log(50k) ≈ 780k. The list stays at K entries; when
    // a new match beats the current worst, we do a linear scan
    // from the back to find its slot (K is small enough that
    // this is essentially free).
    final top = <FileMatch>[];

    for (int i = 0; i < n; i++) {
      final s = _score(i, ql, lower, basenames, initials, basenameInitials);
      if (s <= 0) continue;
      final match = FileMatch(
        relativePath: paths[i],
        kind: isDir[i] ? FileMatchKind.directory : FileMatchKind.file,
        score: s,
      );
      if (top.length < limit) {
        // Insert in sorted position. List is tiny (<= 10).
        _insertSortedDesc(top, match);
      } else if (s > top.last.score) {
        // Replace the worst, then re-sort. Since K=10 this is
        // cheaper than a heap. For larger K, switch to a
        // binary heap.
        top[limit - 1] = match;
        // Bubble up. With K=10, 9 compares in the worst case.
        var j = limit - 1;
        while (j > 0 && top[j].score > top[j - 1].score) {
          final tmp = top[j];
          top[j] = top[j - 1];
          top[j - 1] = tmp;
          j--;
        }
      }
    }
    return top;
  }

  static void _insertSortedDesc(List<FileMatch> list, FileMatch m) {
    var i = list.length;
    list.add(m);
    // Bubble up to correct position.
    while (i > 0 && list[i].score > list[i - 1].score) {
      final tmp = list[i];
      list[i] = list[i - 1];
      list[i - 1] = tmp;
      i--;
    }
  }

  // ── Score tiers ─────────────────────────────────────────────────
  //
  // The score encodes the tier in the high bits and a within-tier
  // tiebreaker in the low bits. Tiers are spaced far enough apart
  // that two adjacent tiers can never overlap, regardless of how
  // the tiebreaker saturates. Ordering (highest first):
  //
  //   _tierExactBasename              (5000) — query equals the basename
  //   _tierFilenamePrefix             (4000) — query is a prefix of the basename
  //   _tierFilenameSubstr             (3000) — query appears in the basename
  //   _tierFilenameInitialsPrefix     (2500) — query is a prefix of basename initials
  //   _tierFilenameInitialsSubseq     (2200) — query is a subseq of basename initials
  //   _tierPathSubstr                 (2000) — query appears only in the dir part
  //   _tierPathInitialsPrefix         (1700) — query is a prefix of path initials
  //   _tierPathInitialsSubseq         (1400) — query is a subseq of path initials
  //   _tierSubsequence                (1000) — query chars appear in order in path
  //
  // Initials tiers catch acronym-style queries. They sit BELOW
  // exact/prefix/substring (so typing `main` still wins over
  // typing the file's initials), but well ABOVE the pure
  // subsequence fallback (so a 2-letter acronym like `bm`
  // outranks a full-path subsequence like `btlmo`). Initials
  // are computed from word boundaries — camelCase, snake_case,
  // kebab-case, dot, and path separators — so users can
  // navigate by typing the first letter of each word.
  //
  // Within each tier, the tiebreaker rewards shorter filenames /
  // earlier substring positions (so `@read` ranks `read.dart`
  // above `read_tool.dart`). All scores are positive so the
  // `s <= 0` filter in [_scoredQueryResults] still drops
  // genuine misses without accidentally dropping weak matches.
  static const int _tierExactBasename = 5000;
  static const int _tierFilenamePrefix = 4000;
  static const int _tierFilenameSubstr = 3000;
  static const int _tierFilenameInitialsPrefix = 2500;
  static const int _tierFilenameInitialsSubseq = 2200;
  static const int _tierPathSubstr = 2000;
  static const int _tierPathInitialsPrefix = 1700;
  static const int _tierPathInitialsSubseq = 1400;
  static const int _tierSubsequence = 1000;

  /// Score [path index] for [ql] using the pre-computed
  /// lowercase + basename + initials parallel arrays. All
  /// branches are O(L) in the path length and avoid per-call
  /// allocations.
  ///
  /// Tiers (highest first):
  ///   1. Exact basename match        — query equals the basename
  ///                                    (e.g. `@main.dart` → `main.dart`)
  ///   2. Filename prefix match       — query is a prefix of the basename
  ///   3. Filename substring match    — query appears in the basename
  ///   4. Filename initials prefix    — query is a prefix of the
  ///                                    basename's word-initial initials
  ///                                    (e.g. `bm` → `BattleMode.cs`
  ///                                    whose initials are `bmc`)
  ///   5. Filename initials subseq    — query chars appear in order
  ///                                    in the basename's initials
  ///   6. Path substring match        — query appears only in the dir prefix
  ///   7. Path initials prefix        — query is a prefix of the path's
  ///                                    initials (e.g. `lsfsd` →
  ///                                    `lib/src/file_searcher.dart`)
  ///   8. Path initials subseq        — query chars appear in order in
  ///                                    the path's initials
  ///   9. Subsequence match           — every char of the query appears
  ///                                    in order anywhere in the path
  ///
  /// Filename tiers (1-5) all outrank the path tiers (6-8), so a
  /// weak filename hit always beats a strong path hit. This
  /// matches the @-mention UX: the user is naming a file, and
  /// "the file matches, just buried in a directory" should
  /// surface above "the directory happens to contain these chars".
  ///
  /// Initials tiers (4-5, 7-8) catch acronym-style queries that
  /// neither exact matches nor substring matches would catch
  /// (`bm` → `BattleMode.cs`). They are ranked below exact /
  /// prefix / substring tiers so a file/directory literally
  /// named `bm` still beats `BattleMode.cs` — the user
  /// explicitly asked for this priority order.
  ///
  /// Within the exact-basename tier (1) the tiebreaker prefers
  /// shorter paths, so `main.dart` outranks `lib/main.dart`
  /// when both basenames match exactly.
  static int _score(
    int idx,
    String ql,
    List<String> lower,
    List<String> basenames,
    List<String> initials,
    List<String> basenameInitials,
  ) {
    final nameL = basenames[idx];
    final pathL = lower[idx];

    // 1. Exact basename match. The user typed the full filename
    //    (including extension), so this should outrank every
    //    other match — including files with the same basename
    //    that live in a different directory. "@main.dart" →
    //    "main.dart" beats "lib/main.dart" / "old/main.dart".
    //    Tiebreaker: shorter paths win, so the version closest
    //    to root (`main.dart`) ranks above the buried copy
    //    (`lib/main.dart`) when both basenames match exactly.
    if (nameL == ql) {
      return _tierExactBasename + (1000 - pathL.length).clamp(0, 1000);
    }

    // 2. Filename prefix match — the most common case
    //    ("@read" should rank "read_tool.dart" first).
    if (nameL.startsWith(ql)) {
      return _tierFilenamePrefix + (100 - nameL.length).clamp(0, 100);
    }

    // 3. Filename contains query as a substring. Earlier index
    //    wins (so `@foo` ranks `before_foo.dart` above
    //    `something_foo.dart`). Always strictly above the
    //    initials tiers thanks to the tier gap, so even a
    //    basename match at index 100 outranks an initials
    //    match at index 0.
    final idxInName = nameL.indexOf(ql);
    if (idxInName >= 0) {
      return _tierFilenameSubstr + (100 - idxInName).clamp(0, 100);
    }

    // 4. Filename initials prefix match. The most common
    //    acronym-style query: typing `bm` should find
    //    `BattleMode.cs` because `bm` is a prefix of the
    //    basename's word-initials `bmc`. Tiebreaker prefers
    //    shorter initials (so a 3-letter file outranks a
    //    6-letter file when the user typed just 2 letters).
    final bi = basenameInitials[idx];
    if (bi.startsWith(ql)) {
      return _tierFilenameInitialsPrefix + (100 - bi.length).clamp(0, 100);
    }

    // 5. Filename initials subsequence match. Less common but
    //    still useful: typing `bld` (B-L-D) would not match
    //    `BattleMode.cs` initials `bmc` — but for files
    //    whose initials happen to align with the query chars
    //    in order, this catches them. Always strictly below
    //    the prefix tier above.
    if (isSubsequence(bi, ql)) {
      return _tierFilenameInitialsSubseq;
    }

    // 6. Path contains query as a substring (basename didn't
    //    match). Always strictly below every filename tier, but
    //    still included in results — the user might be drilling
    //    into a directory by name.
    final idxInPath = pathL.indexOf(ql);
    if (idxInPath >= 0) {
      return _tierPathSubstr + (50 - (idxInPath ~/ 4)).clamp(0, 50);
    }

    // 7. Path initials prefix match. Acronym across path
    //    components: `lsfsd` matches `lib/src/file_searcher.dart`
    //    because `lsfsd` is a prefix of the path's initials
    //    `lsfsd`. Sits BELOW path substring because the user
    //    typing a partial directory name is more common than
    //    them typing an acronym of the full path.
    final pi = initials[idx];
    if (pi.startsWith(ql)) {
      return _tierPathInitialsPrefix + (100 - pi.length).clamp(0, 100);
    }

    // 8. Path initials subsequence match. The user typed chars
    //    that line up with the path's word-initials but not
    //    as a prefix. Always strictly below the prefix tier.
    if (isSubsequence(pi, ql)) {
      return _tierPathInitialsSubseq;
    }

    // 9. Subsequence match: every char of `ql` appears in `pathL`
    //    in order, anywhere. The slowest and weakest branch —
    //    catches last-resort matches like `ttlm` for
    //    `BattleMode.cs` when no initials tier applies.
    if (isSubsequence(pathL, ql)) {
      return _tierSubsequence;
    }

    return 0;
  }

  // ── Initials helpers ───────────────────────────────────────────
  //
  // The actual [computeInitials] and [tokenizeForInitials]
  // implementations live in `fuzzy_match.dart` — the per-file
  // scoring table here (the 9-tier file-specific ladder) just
  // composes the shared primitives. See `fuzzy_match.dart`'s
  // library doc for the rules (camelCase, snake_case, kebab-case,
  // dot, path separators) and the full tier table.

  // ── ripgrep backend / in-process walker ───────────────────────
  //
  // Both index-build paths run inside the worker isolate (see the
  // "Worker-side index build" section below); the main isolate
  // never walks the tree or probes for ripgrep.

  // ── In-process walker fallback ────────────────────────────────
  //
  // Moved to the worker-side section below — see [_walkInProcessAt].
}

// ── Worker-side index build ─────────────────────────────────────
//
// Everything below runs inside the file-search worker isolate
// (see [_fileSearchWorkerMain]). The main isolate's [FileSearcher]
// delegates the whole build here — walk, sort, and per-path
// pre-computation — so none of it can ever block the UI thread.

/// Ripgrep path/availability caches. Only touched from the worker
/// isolate, so no locking is needed.
String? _workerRipgrepPath;
bool? _workerRipgrepAvailable;

/// Compute the lowercased initials string for a path from the
/// index. Strips a trailing separator (for directory entries —
/// see [_ripgrepOutputToPaths] / [_walkAt]) so `foo/bar/`
/// tokenizes the same as `foo/bar`. Delegates to the shared
/// [computeInitials] in `fuzzy_match.dart`.
String _initialsForPath(String s) {
  final cleaned = s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  return computeInitials(cleaned);
}

/// Build the full index for [rootPath]: walk the tree (ripgrep
/// first, in-process fallback), sort, and pre-compute the parallel
/// scoring arrays. Runs on the worker isolate, so none of it —
/// including the multi-second in-process walk on huge trees —
/// ever blocks the UI thread.
Future<
  ({
    List<String> paths,
    List<String> lower,
    List<String> basenames,
    List<String> initials,
    List<String> basenameInitials,
    List<bool> isDir,
    bool usedRipgrep,
  })
>
_buildWorkerIndex(String rootPath, bool preferRipgrep) async {
  List<String>? paths;
  var usedRipgrep = false;
  if (preferRipgrep) {
    paths = await _tryRipgrepAt(rootPath);
    usedRipgrep = paths != null;
  }
  paths ??= _walkInProcessAt(rootPath);

  final sorted = List<String>.of(paths)..sort();
  return (
    paths: List<String>.unmodifiable(sorted),
    lower: List<String>.unmodifiable(
      sorted.map((s) => s.toLowerCase()).toList(),
    ),
    // Lowercased once at index time so [FileSearcher._score]
    // doesn't need to re-allocate on every keystroke. We do this
    // for the basename specifically because the @-mention UX
    // expects case-insensitive matching (`@battlemode.cs` should
    // find `Battlemode.cs`), but [p.basename] preserves the
    // original case. Path comparisons are already case-insensitive
    // via `lower` below — this just extends the same property to
    // basename comparisons.
    basenames: List<String>.unmodifiable(
      sorted.map((s) => p.basename(s).toLowerCase()).toList(),
    ),
    // Directories in the index are marked by a trailing `/`
    // (see [_walkAt] and [_ripgrepOutputToPaths] — both store
    // directories with the trailing slash). `p.basename` is
    // separator-agnostic, so the Windows `\` vs POSIX `/`
    // distinction doesn't matter for the basename field.
    isDir: List<bool>.unmodifiable(sorted.map((s) => s.endsWith('/')).toList()),
    // Initials for the basename only. We tokenize from the
    // original-case basename (so camelCase boundaries are
    // detectable) but emit lowercased initials so the per-
    // keystroke comparison in [FileSearcher._score] is
    // case-insensitive without re-allocating.
    basenameInitials: List<String>.unmodifiable(
      sorted.map((s) => _initialsForPath(p.basename(s))).toList(),
    ),
    // Initials for the whole path. Tokenizes across `/`
    // boundaries so e.g. `lib/src/file_searcher.dart` →
    // `lsfsd`. Used by the path-initials tiers in
    // [FileSearcher._score].
    initials: List<String>.unmodifiable(sorted.map(_initialsForPath).toList()),
    usedRipgrep: usedRipgrep,
  );
}

Future<List<String>?> _tryRipgrepAt(String rootPath) async {
  if (!await _isRipgrepAvailableAt()) return null;
  try {
    final result = await Process.run(_workerRipgrepPath!, const [
      '--no-config',
      '--files',
      '--hidden',
      '--glob=!.git/*',
      '--glob=!node_modules/*',
      '--glob=!target/*',
      '--glob=!build/*',
      '--glob=!dist/*',
      '--glob=!out/*',
      '--glob=!.dart_tool/*',
      '--glob=!.idea/*',
      '--glob=!.vscode/*',
      '--glob=!.next/*',
      '--glob=!.nuxt/*',
      '--glob=!__pycache__/*',
      '--glob=!.gradle/*',
      '--glob=!Pods/*',
      '--glob=!*.lock',
      '.',
    ], workingDirectory: rootPath);
    if (result.exitCode != 0) return null;
    return _ripgrepOutputToPaths(result.stdout as String);
  } on ProcessException {
    return null;
  }
}

Future<bool> _isRipgrepAvailableAt() async {
  final cached = _workerRipgrepAvailable;
  if (cached != null) return cached;
  try {
    _workerRipgrepPath ??= await resolveBundledExecutable(
      Platform.isWindows ? 'rg.exe' : 'rg',
    );
    final result = await Process.run(_workerRipgrepPath!, const ['--version']);
    final ok = result.exitCode == 0;
    _workerRipgrepAvailable = ok;
    return ok;
  } on ProcessException {
    _workerRipgrepAvailable = false;
    return false;
  }
}

List<String> _ripgrepOutputToPaths(String output) {
  if (output.isEmpty) return const [];
  // ripgrep always emits `/`-separated paths (POSIX style)
  // regardless of the host platform. We keep that on disk so
  // the index matches the in-process walker output, and only
  // re-translate to native separators at display time.
  const sep = '/';
  // ripgrep prints paths relative to its CWD, one per line.
  // For our use case, we append `/` for directories — but
  // `rg --files` only emits files. We don't get directory
  // entries from ripgrep, so the in-process fallback's
  // directory coverage is *better* than ripgrep's. To
  // compensate, we synthesize directory entries for the
  // path prefixes of every file. This is cheap (one Set
  // build, then a per-file `parent` lookup) and means the
  // directory drill-in still works.
  final fileLines = const LineSplitter().convert(output);
  final dirs = <String>{};
  final result = <String>[];
  for (final line in fileLines) {
    if (line.isEmpty) continue;
    result.add(line);
    // Add every ancestor directory to the dir set.
    var i = line.lastIndexOf(sep);
    while (i > 0) {
      final parent = line.substring(0, i);
      if (dirs.add('$parent$sep')) {
        // Newly added — keep going.
      } else {
        // Already in set; shorter prefixes are guaranteed
        // to be there too, so we can stop.
        break;
      }
      i = line.lastIndexOf(sep, i - 1);
    }
  }
  // If a file is at the root, its parent is empty — that's
  // not a directory entry. Skip empty/root paths.
  final nonEmpty = <String>[];
  for (final d in dirs) {
    if (d.length > sep.length) nonEmpty.add(d);
  }
  result.addAll(nonEmpty);
  return result;
}

List<String> _walkInProcessAt(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) return const [];
  final gitignore = _loadGitignoresAt(root);
  final out = <String>[];
  _walkAt(root, out, '', gitignore);
  return out;
}

/// Walk the project tree and merge every `.gitignore` we find
/// into a single matcher. The matcher's [GitignoreMatcher.matches]
/// check is path-aware, so the walker can pass the in-progress
/// relative path to a directory entry and ask "is this directory
/// ignored before I descend into it?" — short-circuiting whole
/// subtrees like `build/` or `node_modules/` even if the user
/// didn't list them in the static skip set.
///
/// We load *all* .gitignore files up front (in a single sweep
/// with bounded recursion) so the matcher's `directoryIgnores`
/// lookup is O(1) per dir during the main walk. The .gitignore
/// stack is implicit: a pattern without a `/` in it matches
/// at any depth; one with a `/` only matches at the level of
/// its containing file. [GitignoreMatcher.matches] handles the
/// "negation" rule (!foo) and the "anchored-to-root" rule
/// (`/foo` only at the project root) for us.
GitignoreMatcher _loadGitignoresAt(Directory root) {
  final matcher = GitignoreMatcher();
  final out = <GitignoreSource>[];
  _collectGitignoresAt(root, '', out);
  matcher.loadAll(out);
  return matcher;
}

void _collectGitignoresAt(
  Directory dir,
  String relPrefix,
  List<GitignoreSource> out,
) {
  // Same /-normalization as [_walkAt] — keep the relPrefix
  // consistent with the paths the walker will produce so the
  // GitignoreMatcher's `src.dir` lookup matches.
  const sep = '/';
  try {
    final gi = File(p.join(dir.path, '.gitignore'));
    if (gi.existsSync()) {
      try {
        final lines = gi.readAsLinesSync();
        out.add((directory: relPrefix.isEmpty ? '.' : relPrefix, lines: lines));
      } on FileSystemException {
        // Unreadable .gitignore — skip.
      }
    }
    for (final entry in dir.listSync(recursive: false, followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (_shouldSkip(name)) continue;
      final rel = relPrefix.isEmpty ? name : '$relPrefix$sep$name';
      _collectGitignoresAt(entry, rel, out);
    }
  } on FileSystemException {
    // Permission denied / transient errors — skip.
  }
}

void _walkAt(
  Directory dir,
  List<String> out,
  String prefix,
  GitignoreMatcher gitignore,
) {
  // Always use POSIX `/` for the index, even on Windows. The
  // platform's native separator is `\` on Windows; mixing that
  // with the `/` ripgrep emits on every platform would make the
  // in-process walker disagree with the ripgrep backend (and
  // disagree with every gitignore pattern, which is POSIX-style
  // by definition). The user-facing paths we display in the
  // popover get re-rendered with `p.separator` so they look
  // native on Windows.
  const sep = '/';
  try {
    final entries = dir.listSync(recursive: false, followLinks: false);
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (_shouldSkip(name)) continue;
      final rel = prefix.isEmpty ? name : '$prefix$sep$name';
      // Honor .gitignore. A directory is skipped wholesale if
      // it's ignored — no point descending. The check uses
      // the bare path (no trailing separator) so a pattern
      // like `build/` matches the directory `build`.
      if (entry is Directory && gitignore.matches(rel, isDirectory: true)) {
        continue;
      }
      if (entry is Directory) {
        out.add('$rel$sep');
        _walkAt(entry, out, rel, gitignore);
      } else if (entry is File) {
        // Same check for files — a file matching an ignore
        // pattern is dropped.
        if (gitignore.matches(rel, isDirectory: false)) continue;
        out.add(rel);
      }
    }
  } on FileSystemException {
    // Permission denied / transient errors — skip and continue.
  }
}

final Set<String> _skipDirs = {
  '.git',
  '.hg',
  '.svn',
  '.dart_tool',
  '.idea',
  '.vscode',
  'node_modules',
  'target',
  'build',
  'dist',
  'out',
  '.next',
  '.nuxt',
  '__pycache__',
  '.pytest_cache',
  '.mypy_cache',
  '.gradle',
  'Pods',
  '.terraform',
};

const Set<String> _skipFiles = {
  'pubspec.lock',
  'package-lock.json',
  'yarn.lock',
  'Cargo.lock',
  'go.sum',
  'poetry.lock',
  '.DS_Store',
  '.gitignore',
  '.gitattributes',
};

bool _shouldSkip(String name) {
  if (name.isEmpty) return true;
  if (name.startsWith('.')) {
    const keepHidden = {'.env', '.envrc', '.gitignore', '.gitattributes'};
    return !keepHidden.contains(name);
  }
  if (_skipDirs.contains(name)) return true;
  if (_skipFiles.contains(name)) return true;
  return false;
}

/// Immutable mirror of the worker's index snapshot, shipped back
/// to the main isolate when a build completes. The main isolate
/// keeps this so the synchronous [FileSearcher.search] (and the
/// empty-query "first N files" path) work without a round-trip.
class _WorkerIndexSnapshot {
  final bool usedRipgrep;
  final List<String> paths;
  final List<String> lower;
  final List<String> basenames;
  final List<String> initials;
  final List<String> basenameInitials;
  final List<bool> isDir;

  const _WorkerIndexSnapshot({
    required this.usedRipgrep,
    required this.paths,
    required this.lower,
    required this.basenames,
    required this.initials,
    required this.basenameInitials,
    required this.isDir,
  });
}

/// `LineSplitter` from `dart:convert` — re-imported here so the
/// file_searcher doesn't grow another top-level dependency on the
/// whole convert library. (Cheap; just avoids forcing callers of
/// this file to think about it.)
class LineSplitter {
  const LineSplitter();
  List<String> convert(String input) =>
      input.split(RegExp(r'\r\n|\r|\n')).where((l) => l.isNotEmpty).toList();
}

class _FileSearchWorker {
  _FileSearchWorker._(
    this._isolate,
    this._sendPort,
    this._receivePort,
    this._subscription,
  );

  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final StreamSubscription<dynamic> _subscription;

  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

  static Future<_FileSearchWorker> spawn() async {
    final receivePort = ReceivePort();
    final ready = Completer<SendPort>();
    _FileSearchWorker? worker;

    late final StreamSubscription<dynamic> subscription;
    subscription = receivePort.listen((dynamic message) {
      if (!ready.isCompleted) {
        if (message is SendPort) {
          ready.complete(message);
        } else {
          ready.completeError(
            StateError('File search worker did not return a SendPort'),
          );
        }
        return;
      }
      worker?._handleMessage(message);
    });

    final isolate = await Isolate.spawn(
      _fileSearchWorkerMain,
      receivePort.sendPort,
      debugName: 'crux-file-search-worker',
    );

    try {
      final sendPort = await ready.future;
      final startedWorker = _FileSearchWorker._(
        isolate,
        sendPort,
        receivePort,
        subscription,
      );
      worker = startedWorker;
      return startedWorker;
    } catch (_) {
      await subscription.cancel();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  /// Build (or rebuild) the index for [rootPath] inside the worker
  /// and return the finished snapshot. The worker walks the tree,
  /// sorts it, and pre-computes the scoring arrays; the only cost
  /// on the main isolate is receiving the immutable result.
  Future<_WorkerIndexSnapshot> build(
    String rootPath, {
    required bool preferRipgrep,
  }) async {
    final raw = await _sendRequest(
      ['build', rootPath, preferRipgrep],
      // The build covers the tree walk (potentially seconds on a
      // huge project) plus the snapshot ship-back, so give it a
      // generous budget.
      timeout: const Duration(minutes: 2),
    );
    if (raw is! List || raw.length != 7) {
      throw StateError('file search worker: invalid build reply');
    }
    final usedRipgrep = raw[0];
    final paths = raw[1];
    final lower = raw[2];
    final basenames = raw[3];
    final initials = raw[4];
    final basenameInitials = raw[5];
    final isDir = raw[6];
    if (usedRipgrep is! bool ||
        paths is! List ||
        lower is! List ||
        basenames is! List ||
        initials is! List ||
        basenameInitials is! List ||
        isDir is! List) {
      throw StateError('file search worker: malformed build reply');
    }
    return _WorkerIndexSnapshot(
      usedRipgrep: usedRipgrep,
      paths: List<String>.from(paths),
      lower: List<String>.from(lower),
      basenames: List<String>.from(basenames),
      initials: List<String>.from(initials),
      basenameInitials: List<String>.from(basenameInitials),
      isDir: List<bool>.from(isDir),
    );
  }

  /// Tell the worker to drop its index snapshot. The worker
  /// rebuilds on the next [build] request.
  Future<void> invalidate() async {
    await _sendRequest(['invalidate']);
  }

  Future<List<FileMatch>> search(String query, {required int limit}) async {
    final raw = await _sendRequest(['search', query, limit]);
    if (raw is! List) return const [];
    final out = <FileMatch>[];
    for (final item in raw) {
      if (item is! List || item.length != 3) continue;
      final path = item[0];
      final isDir = item[1];
      final score = item[2];
      if (path is! String || isDir is! bool || score is! int) continue;
      out.add(
        FileMatch(
          relativePath: path,
          kind: isDir ? FileMatchKind.directory : FileMatchKind.file,
          score: score,
        ),
      );
    }
    return out;
  }

  Future<Object?> _sendRequest(
    List<Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _sendPort.send([id, ...payload]);
    // Guard against a dead isolate leaving the caller hanging
    // forever: on timeout we drop the pending completer and surface
    // an error so the [FileSearcher] can dispose and respawn.
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw StateError('file search worker timed out');
      },
    );
  }

  void _handleMessage(dynamic message) {
    if (message is! List || message.length < 2) return;
    final id = message[0];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final tag = message[1];
    if (tag == 'ok') {
      completer.complete(message.length > 2 ? message[2] : null);
    } else if (tag == 'error') {
      final error = message.length > 2 ? message[2] : 'worker error';
      completer.completeError(StateError(error.toString()));
    }
  }

  void dispose() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('File search worker disposed'));
      }
    }
    _pending.clear();
    _sendPort.send(const [-1, 'shutdown']);
    _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _fileSearchWorkerMain(SendPort readyPort) {
  final port = ReceivePort();
  readyPort.send(port.sendPort);

  // The index snapshot this worker currently owns. Built in
  // response to a 'build' request, cleared by 'invalidate'.
  List<String> paths = const [];
  List<String> lower = const [];
  List<String> basenames = const [];
  List<String> initials = const [];
  List<String> basenameInitials = const [];
  List<bool> isDir = const [];
  bool built = false;

  // Requests are serialized through this chain so a 'build'
  // (async — it may run ripgrep) can't interleave with a 'search'
  // that would read a half-built snapshot.
  var chain = Future<void>.value();

  Future<void> handle(dynamic message) async {
    final id = message[0] as int;
    final op = message[1] as String;

    if (op == 'shutdown') {
      port.close();
      return;
    }

    try {
      if (op == 'build') {
        final rootPath = message[2] as String;
        final preferRipgrep = message[3] as bool;
        final snapshot = await _buildWorkerIndex(rootPath, preferRipgrep);
        paths = snapshot.paths;
        lower = snapshot.lower;
        basenames = snapshot.basenames;
        initials = snapshot.initials;
        basenameInitials = snapshot.basenameInitials;
        isDir = snapshot.isDir;
        built = true;
        readyPort.send([
          id,
          'ok',
          [
            snapshot.usedRipgrep,
            paths,
            lower,
            basenames,
            initials,
            basenameInitials,
            isDir,
          ],
        ]);
      } else if (op == 'invalidate') {
        paths = const [];
        lower = const [];
        basenames = const [];
        initials = const [];
        basenameInitials = const [];
        isDir = const [];
        built = false;
        readyPort.send([id, 'ok']);
      } else if (op == 'search') {
        if (!built) {
          readyPort.send([id, 'ok', const []]);
          return;
        }
        final q = message[2] as String;
        final limit = message[3] as int;
        final result = _workerSearch(
          q,
          limit,
          paths,
          lower,
          basenames,
          initials,
          basenameInitials,
          isDir,
        );
        readyPort.send([id, 'ok', result]);
      } else {
        throw StateError('unknown file search op: $op');
      }
    } catch (error) {
      readyPort.send([id, 'error', error.toString()]);
    }
  }

  port.listen((dynamic message) {
    if (message is! List || message.length < 2) return;
    if (message[0] is! int || message[1] is! String) return;
    chain = chain.then((_) => handle(message)).catchError((_) {});
  });
}

List<List<Object?>> _workerSearch(
  String query,
  int limit,
  List<String> paths,
  List<String> lower,
  List<String> basenames,
  List<String> initials,
  List<String> basenameInitials,
  List<bool> isDir,
) {
  if (paths.isEmpty || limit <= 0) return const [];
  final ql = query.toLowerCase();
  final top = <List<Object?>>[];

  for (var i = 0; i < paths.length; i++) {
    final score = FileSearcher._score(
      i,
      ql,
      lower,
      basenames,
      initials,
      basenameInitials,
    );
    if (score <= 0) continue;

    final match = <Object?>[paths[i], isDir[i], score];
    if (top.length < limit) {
      _insertWorkerMatchSorted(top, match);
    } else if (score > (top.last[2] as int)) {
      top[limit - 1] = match;
      var j = limit - 1;
      while (j > 0 && (top[j][2] as int) > (top[j - 1][2] as int)) {
        final tmp = top[j];
        top[j] = top[j - 1];
        top[j - 1] = tmp;
        j--;
      }
    }
  }

  return top;
}

void _insertWorkerMatchSorted(List<List<Object?>> list, List<Object?> match) {
  var i = list.length;
  list.add(match);
  while (i > 0 && (list[i][2] as int) > (list[i - 1][2] as int)) {
    final tmp = list[i];
    list[i] = list[i - 1];
    list[i - 1] = tmp;
    i--;
  }
}

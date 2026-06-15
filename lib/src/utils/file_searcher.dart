import 'dart:io';

import 'package:path/path.dart' as p;

import 'bundled_executable.dart';
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
/// Performance characteristics for a 50k-file project:
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
/// walk runs. Subsequent searches are synchronous once the index is
/// warm; per-keystroke work is purely in-memory.
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
  /// array. Saves an O(L) `p.basename` per path per keystroke.
  List<String>? _basenames;

  /// Pre-computed isDirectory flag for every path in [_paths].
  /// Paths in the index that end with the platform separator are
  /// directories (see [_walk] and `_ripgrepLinesToPaths`).
  List<bool>? _isDir;

  /// Composite gitignore matcher built from every `.gitignore`
  /// found in the project tree. Only the in-process walker uses
  /// this; ripgrep honors `.gitignore` natively so when ripgrep
  /// builds the index the matcher stays null. Lazily populated
  /// by [_loadGitignores] on the first in-process walk.
  GitignoreMatcher? _gitignore;

  /// True while [_buildIndex] is in flight. The chat input reads
  /// this to show "Searching..." in the popover header.
  bool _isIndexing = false;

  /// The in-flight index build, or null if the index is ready
  /// (or hasn't been kicked off yet). [ready] awaits this so
  /// search callers can synchronize on it.
  Future<void>? _indexingFuture;

  /// Whether the last successful index used ripgrep or the
  /// in-process walker. Useful for diagnostics.
  bool _usedRipgrep = false;

  /// Whether `rg` was found on $PATH at construction time. Cached
  /// so we don't re-probe on every index rebuild.
  bool? _ripgrepAvailableCache;

  FileSearcher({
    required this.rootPath,
    this.preferRipgrep = true,
  });

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
    _paths = null;
    _lower = null;
    _basenames = null;
    _isDir = null;
    _indexingFuture = null;
  }

  /// Kick off indexing if it hasn't started yet (or if [invalidate]
  /// was called). Idempotent — multiple callers `await`ing
  /// [ensureIndex] share the same future. Safe to call from a
  /// microtask: it just creates a Future.value() if there's
  /// nothing to do.
  Future<void> ensureIndex() {
    if (_indexingFuture != null) return _indexingFuture!;
    if (_paths != null) {
      // Already built and not invalidated.
      return Future<void>.value();
    }
    _isIndexing = true;
    _indexingFuture = _buildIndex();
    _indexingFuture!.whenComplete(() {
      _isIndexing = false;
    });
    return _indexingFuture!;
  }

  /// Build the index. Tries ripgrep first, falls back to the
  /// in-process walker. Both paths produce a sorted, pre-computed
  /// parallel-array representation so search is purely in-memory.
  Future<void> _buildIndex() async {
    List<String>? paths;
    if (preferRipgrep) {
      paths = await _tryRipgrep();
      _usedRipgrep = paths != null;
    }
    paths ??= _walkInProcess();
    _populateIndex(paths);
  }

  void _populateIndex(List<String> paths) {
    paths.sort();
    _paths = List<String>.unmodifiable(paths);
    _lower = List<String>.unmodifiable(
      paths.map((s) => s.toLowerCase()).toList(),
    );
    _basenames = List<String>.unmodifiable(
      paths.map((s) => p.basename(s)).toList(),
    );
    // Directories in the index are marked by a trailing `/`
    // (see [_walk] and `_ripgrepOutputToPaths` — both store
    // directories with the trailing slash). `p.basename` is
    // separator-agnostic, so the Windows `\` vs POSIX `/`
    // distinction doesn't matter for the basename field.
    _isDir = List<bool>.unmodifiable(
      paths.map((s) => s.endsWith('/')).toList(),
    );
  }

  /// Fuzzy-search the indexed tree for [query]. Returns up to
  /// [limit] matches, sorted by descending score.
  ///
  /// This is the synchronous, hot-path variant. The caller is
  /// expected to have `await`-ed [ready] first; if the index
  /// isn't ready, we return an empty list and let the caller's
  /// "Searching..." placeholder do the talking.
  ///
  /// Scoring: filename prefix match (200+) → filename substring
  /// (100-) → path substring (50-) → subsequence match (10).
  /// Files rank above directories at equal score, and shorter
  /// paths rank above longer ones (so the closest match
  /// surfaces first).
  List<FileMatch> search(String query, {int limit = 10}) {
    final paths = _paths;
    if (paths == null || paths.isEmpty) return const [];

    final q = query.trim();
    if (q.isEmpty) {
      return _emptyQueryResults(limit);
    }
    return _scoredQueryResults(q, limit);
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
    final isDir = _isDir!;
    final n = paths.length;
    final ql = q.toLowerCase();
    final qFirst = ql.codeUnitAt(0);

    // Top-K via a fixed-size, sorted-descending list. We avoid a
    // full O(N log N) sort — for N=50k and K=10 that's the
    // difference between ~50k * log(10) ≈ 166k comparisons and
    // ~50k * log(50k) ≈ 780k. The list stays at K entries; when
    // a new match beats the current worst, we do a linear scan
    // from the back to find its slot (K is small enough that
    // this is essentially free).
    final top = <FileMatch>[];

    for (int i = 0; i < n; i++) {
      final s = _score(i, ql, qFirst, lower, basenames);
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

  /// Score [path index] for [ql] / [qFirst] using the pre-computed
  /// lowercase + basename parallel arrays. All branches are O(L)
  /// in the path length and avoid per-call allocations.
  int _score(
    int idx,
    String ql,
    int qFirst,
    List<String> lower,
    List<String> basenames,
  ) {
    final nameL = basenames[idx];
    final pathL = lower[idx];

    // Filename prefix match — by far the most common case
    // ("@read" should rank "read_tool.dart" first).
    if (nameL.startsWith(ql)) {
      return 200 + (100 - nameL.length).clamp(0, 100);
    }

    // Filename contains query as a substring.
    final idxInName = nameL.indexOf(ql);
    if (idxInName >= 0) {
      return 100 - idxInName;
    }

    // Path contains query as a substring.
    final idxInPath = pathL.indexOf(ql);
    if (idxInPath >= 0) {
      return 50 - (idxInPath ~/ 4);
    }

    // Subsequence match: every char of `ql` appears in `pathL`
    // in order, starting with the first char of `ql`. Reward
    // shorter gaps by giving a flat +10 — we don't try to score
    // gap tightness because it's the slowest branch and the
    // common case is already handled by the substring checks.
    if (_isSubsequence(pathL, ql, qFirst)) {
      return 10;
    }

    return 0;
  }

  static bool _isSubsequence(String hay, String ql, int qFirst) {
    if (hay.isEmpty || ql.isEmpty) return false;
    if (hay.codeUnitAt(0) != qFirst) return false;
    var qi = 1;
    for (var i = 1; i < hay.length && qi < ql.length; i++) {
      if (hay.codeUnitAt(i) == ql.codeUnitAt(qi)) qi++;
    }
    return qi == ql.length;
  }

  // ── ripgrep backend ────────────────────────────────────────────

  Future<List<String>?> _tryRipgrep() async {
    if (!await _isRipgrepAvailable()) return null;
    try {
      final result = await Process.run(
        _ripgrepPath!,
        const [
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
        ],
        workingDirectory: rootPath,
      );
      if (result.exitCode != 0) return null;
      return _ripgrepOutputToPaths(result.stdout as String);
    } on ProcessException {
      return null;
    }
  }

  String? _ripgrepPath;

  Future<bool> _isRipgrepAvailable() async {
    final cached = _ripgrepAvailableCache;
    if (cached != null) return cached;
    try {
      _ripgrepPath ??= await resolveBundledExecutable(
        Platform.isWindows ? 'rg.exe' : 'rg',
      );
      final result = await Process.run(
        _ripgrepPath!,
        const ['--version'],
      );
      final ok = result.exitCode == 0;
      _ripgrepAvailableCache = ok;
      return ok;
    } on ProcessException {
      _ripgrepAvailableCache = false;
      return false;
    }
  }

  static List<String> _ripgrepOutputToPaths(String output) {
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

  // ── In-process walker fallback ────────────────────────────────

  List<String> _walkInProcess() {
    final root = Directory(rootPath);
    if (!root.existsSync()) return const [];
    _gitignore ??= _loadGitignores(root);
    final out = <String>[];
    _walk(root, out, '');
    return out;
  }

  /// Walk the project tree and merge every `.gitignore` we find
  /// into a single matcher. The matcher's [matches] check is
  /// path-aware, so the walker can pass the in-progress relative
  /// path to a directory entry and ask "is this directory
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
  GitignoreMatcher _loadGitignores(Directory root) {
    final matcher = GitignoreMatcher();
    final out = <GitignoreSource>[];
    _collectGitignores(root, '', out);
    matcher.loadAll(out);
    return matcher;
  }

  void _collectGitignores(
    Directory dir,
    String relPrefix,
    List<GitignoreSource> out,
  ) {
    // Same /-normalization as [_walk] — keep the relPrefix
    // consistent with the paths the walker will produce so the
    // GitignoreMatcher's `src.dir` lookup matches.
    const sep = '/';
    try {
      final gi = File(p.join(dir.path, '.gitignore'));
      if (gi.existsSync()) {
        try {
          final lines = gi.readAsLinesSync();
          out.add((
            directory: relPrefix.isEmpty ? '.' : relPrefix,
            lines: lines,
          ));
        } on FileSystemException {
          // Unreadable .gitignore — skip.
        }
      }
      for (final entry in dir.listSync(recursive: false, followLinks: false)) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path);
        if (_shouldSkip(name)) continue;
        final rel = relPrefix.isEmpty ? name : '$relPrefix$sep$name';
        _collectGitignores(entry, rel, out);
      }
    } on FileSystemException {
      // Permission denied / transient errors — skip.
    }
  }

  void _walk(Directory dir, List<String> out, String prefix) {
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
        if (_gitignore != null && entry is Directory) {
          if (_gitignore!.matches(rel, isDirectory: true)) continue;
        }
        if (entry is Directory) {
          out.add('$rel$sep');
          _walk(entry, out, rel);
        } else if (entry is File) {
          // Same check for files — a file matching an ignore
          // pattern is dropped.
          if (_gitignore != null &&
              _gitignore!.matches(rel, isDirectory: false)) {
            continue;
          }
          out.add(rel);
        }
      }
    } on FileSystemException {
      // Permission denied / transient errors — skip and continue.
    }
  }

  static final Set<String> _skipDirs = {
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

  static const Set<String> _skipFiles = {
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

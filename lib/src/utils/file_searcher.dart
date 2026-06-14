import 'dart:io';

import 'package:path/path.dart' as p;

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
/// The first [search] call walks the project tree and caches every
/// path it sees (subject to the [maxFiles] cap, default 5000 — enough
/// for a typical project without blowing up memory on a huge monorepo).
/// Subsequent searches run the fuzzy match purely in memory, so the
/// common case (typing in the chat input, where the user may type
/// many characters in a single keystroke burst) is fast even on
/// large trees.
///
/// Skipped by default: hidden files/dirs (`.git`, `.build`, etc.),
/// `node_modules`, `target`, `build`, `dist`, `.dart_tool`, plus
/// any common binary/lock file. This is the same ignore set opencode
/// uses, tuned for the kind of projects a TUI coding agent usually
/// sees (Dart, Rust, Node, Python, Go).
///
/// [invalidate] drops the cache; the next search will re-walk the
/// tree. The chat panel calls this when the user switches the project
/// directory (`/project`) so a different tree gets indexed.
class FileSearcher {
  /// Absolute path of the project root we're indexing.
  final String rootPath;

  /// Hard cap on the number of paths cached. Defends against
  /// runaway memory on huge monorepos.
  final int maxFiles;

  /// All paths we've ever indexed, relative to [rootPath], in
  /// stable (sorted) order. Lazily populated by [_ensureIndex].
  List<String>? _paths;

  /// Re-walk on the next [search] call. Set by [invalidate] and
  /// also after construction when no walk has happened yet.
  bool _dirty = true;

  FileSearcher({required this.rootPath, this.maxFiles = 5000});

  /// Drop the index. The next [search] re-walks the tree.
  void invalidate() {
    _dirty = true;
    _paths = null;
  }

  /// Number of paths currently cached. Returns 0 if no walk has
  /// happened yet.
  int get indexSize => _paths?.length ?? 0;

  /// Fuzzy-search the indexed tree for [query]. Returns up to
  /// [limit] matches, sorted by descending score.
  ///
  /// Scoring is a simple subsequence match with bonuses:
  /// - Filename prefix match (e.g. `@read` → "read_tool.dart"): +100
  /// - Filename contains query as substring: +40
  /// - Path-segment match: +15 per matched segment
  /// - Shorter paths rank higher (so the closest match surfaces first)
  /// - Files rank above directories at equal score
  ///
  /// An empty query returns the first [limit] indexed paths in
  /// alphabetical order, which gives the user something useful to
  /// arrow through the moment they type `@`.
  List<FileMatch> search(String query, {int limit = 10}) {
    _ensureIndex();
    final paths = _paths!;
    if (paths.isEmpty) return const [];

    final q = query.trim();
    if (q.isEmpty) {
      return paths
          .take(limit)
          .map(
            (rel) => FileMatch(
              relativePath: rel,
              kind: rel.endsWith('/') || rel.endsWith(p.separator)
                  ? FileMatchKind.directory
                  : FileMatchKind.file,
              score: 0,
            ),
          )
          .toList();
    }

    final ql = q.toLowerCase();
    final qFirst = ql.codeUnitAt(0);
    final results = <FileMatch>[];

    for (final rel in paths) {
      final score = _score(rel, ql, qFirst);
      if (score > 0) {
        results.add(
          FileMatch(
            relativePath: rel,
            kind: rel.endsWith(p.separator)
                ? FileMatchKind.directory
                : FileMatchKind.file,
            score: score,
          ),
        );
      }
    }

    results.sort((a, b) {
      // Higher score first; ties broken by shorter path (closer
      // match) and files-before-directories.
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byLen = a.relativePath.length.compareTo(b.relativePath.length);
      if (byLen != 0) return byLen;
      return a.kind.index.compareTo(b.kind.index);
    });

    if (results.length > limit) {
      return results.sublist(0, limit);
    }
    return results;
  }

  /// Build a sublist of paths under [dirRelative] (relative to the
  /// search root). Used when the user picks a directory and we want
  /// to drill in. Returns up to [limit] entries.
  List<FileMatch> listDirectory(String dirRelative, {int limit = 10}) {
    _ensureIndex();
    final paths = _paths!;
    if (paths.isEmpty) return const [];

    final prefix = dirRelative.isEmpty || dirRelative == '.'
        ? ''
        : dirRelative.endsWith('/')
            ? dirRelative
            : '$dirRelative/';
    final out = <FileMatch>[];
    for (final rel in paths) {
      if (!rel.startsWith(prefix)) continue;
      // Only direct children — the relative path under the prefix
      // should not contain a separator.
      final rest = rel.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      out.add(
        FileMatch(
          relativePath: rel,
          kind: rel.endsWith('/') ? FileMatchKind.directory : FileMatchKind.file,
          score: 0,
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  }

  int _score(String relPath, String ql, int qFirst) {
    final name = p.basename(relPath);
    final nameL = name.toLowerCase();
    final pathL = relPath.toLowerCase();

    // Filename prefix match — by far the most common case
    // ("@read" should rank "read_tool.dart" first).
    if (nameL.startsWith(ql)) {
      // Earlier start of prefix → higher score; "read" beats
      // "read_tool" only if both start with "read", but we want
      // exact prefix → huge bonus.
      return 200 + (100 - nameL.length).clamp(0, 100);
    }

    // Filename contains query as a substring.
    final idx = nameL.indexOf(ql);
    if (idx >= 0) {
      return 100 - idx;
    }

    // Path contains query as a substring.
    final pidx = pathL.indexOf(ql);
    if (pidx >= 0) {
      return 50 - (pidx ~/ 4);
    }

    // Subsequence match: every char of `ql` appears in `pathL` in
    // order. Reward shorter gaps.
    if (_isSubsequence(pathL, ql, qFirst)) {
      return 10;
    }

    return 0;
  }

  bool _isSubsequence(String hay, String ql, int qFirst) {
    var qi = 0;
    for (var i = 0; i < hay.length && qi < ql.length; i++) {
      if (hay.codeUnitAt(i) == ql.codeUnitAt(qi)) {
        qi++;
        if (qi == 1 && hay.codeUnitAt(i) != qFirst) {
          // First char must match — disqualify.
          return false;
        }
      }
    }
    return qi == ql.length;
  }

  void _ensureIndex() {
    if (!_dirty && _paths != null) return;
    _dirty = false;
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      _paths = const [];
      return;
    }
    final out = <String>[];
    _walk(root, out, '');
    out.sort();
    if (out.length > maxFiles) {
      out.removeRange(maxFiles, out.length);
    }
    _paths = out;
  }

  void _walk(Directory dir, List<String> out, String prefix) {
    if (out.length >= maxFiles) return;
    final sep = p.separator;
    try {
      final entries = dir.listSync(recursive: false, followLinks: false);
      // Sort so the index is deterministic and stable across runs
      // (directories and files interleaved alphabetically). Stability
      // matters for the fuzzy-search "ties broken by index order" rule.
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (out.length >= maxFiles) return;
        final name = p.basename(entry.path);
        if (_shouldSkip(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix$sep$name';
        if (entry is Directory) {
          out.add('$rel$sep');
          _walk(entry, out, rel);
        } else if (entry is File) {
          out.add(rel);
        }
      }
    } on FileSystemException {
      // Permission denied / transient errors — skip this directory
      // and continue walking siblings.
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
    // Hidden files/dirs (dotfiles) — except the common ones users
    // often want to mention.
    if (name.startsWith('.')) {
      const keepHidden = {'.env', '.envrc', '.gitignore', '.gitattributes'};
      return !keepHidden.contains(name);
    }
    if (_skipDirs.contains(name)) return true;
    if (_skipFiles.contains(name)) return true;
    return false;
  }
}

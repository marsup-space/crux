// Minimal `.gitattributes` parser used by the edit/write tools to
// determine the *target* line ending for a file. Git's own
// `.gitattributes` format is broader (it drives merge strategies,
// diff filters, archive exclusions, etc.); this module cares only
// about the subset that affects line endings:
//
//   - `eol=crlf` / `eol=lf`  — explicit target
//   - `text`                 — equivalent to `eol=lf` (the file is
//                              text; git normalizes to LF on commit
//                              and back to whatever the local
//                              config says on checkout; we adopt LF
//                              as the on-disk target)
//   - `text=auto`            — git picks; we treat this as "use
//                              whatever the file currently has"
//                              and return `null` so the caller
//                              falls back to its detected
//                              line ending
//   - `binary` / `-text`     — the file is binary or explicitly
//                              not-text; we do NOT touch line
//                              endings for it (return `null`)
//
// All other attributes are ignored.
//
// The pattern syntax is the same as `.gitignore`, so we reuse the
// gitignore glob→regex conversion (the file_searcher's matcher has
// a battle-tested implementation; we just need a smaller version
// here because gitattributes has no negation in the same way
// gitignore does).
//
// The lookup walks upward from the file's directory until it
// finds a `.gitattributes` (or hits the filesystem root). The
// resolved file is cached on disk, and the parsed rules are
// cached in-process, so the steady-state cost of an edit is one
// `stat()` per directory in the path — and that cost is paid
// once per (file, ancestor) pair.

import 'dart:io';

import 'package:path/path.dart' as p;

/// The effective line-ending directive for a file, after
/// consulting `.gitattributes`. The strings are the same values
/// used by `file_metadata.dart`'s `lineEnding` field so callers
/// can pass the result straight into `normalizeToLineEnding`:
///
///   - `'crlf'` — file should be CRLF on disk.
///   - `'lf'`   — file should be LF on disk.
///   - `null`   — no rule applies; the caller should fall back
///                to the file's detected line ending.
class GitAttributesEol {
  /// The line ending the file should be in, as a string the
  /// `file_metadata` module understands (`'crlf'` / `'lf'`).
  /// `null` means "no rule applies".
  final String? value;

  /// True when the file is declared binary (or explicitly
  /// `text=false` / `-text`). In that case the edit/write
  /// tools should leave the file's bytes alone — no line-ending
  /// normalization.
  final bool isBinary;

  const GitAttributesEol._(this.value, this.isBinary);

  static const GitAttributesEol crlfResult =
      GitAttributesEol._('crlf', false);
  static const GitAttributesEol lfResult =
      GitAttributesEol._('lf', false);
  static const GitAttributesEol binaryResult =
      GitAttributesEol._(null, true);

  /// `true` when no line-ending normalization should happen.
  bool get isPassthrough => isBinary;
}

/// Resolved rules for one `.gitattributes` file. The file is
/// parsed once and the rules are stored as compiled regexes so
/// per-file lookups are cheap.
class _ParsedGitAttributes {
  final String path;
  final List<_Rule> rules;

  _ParsedGitAttributes({required this.path, required this.rules});

  /// Return the effective line-ending directive for [filePath],
  /// or `null` if no rule matches.
  ///
  /// The walk is "last match wins", matching git's own behavior.
  /// `_text`/`-text` toggle the "is this text?" bit; if a file
  /// is declared `binary` (or `-text`) anywhere, we return the
  /// binary sentinel and don't touch the file's bytes.
  GitAttributesEol? eolFor(String filePath) {
    final dir = p.dirname(path);
    final relPath = p.relative(filePath, from: dir);
    if (relPath.startsWith('..')) {
      // filePath is not under the .gitattributes's directory;
      // shouldn't happen since we walk upward to find the
      // .gitattributes, but be defensive.
      return null;
    }
    final rel = relPath.split(Platform.pathSeparator).join('/');

    var text = true; // default: file is text
    String? eol; // null = no explicit eol=
    var sawBinary = false;

    for (final rule in rules) {
      if (!rule.matches(rel)) continue;
      if (rule.binary) {
        // `binary` or `text=false` is sticky — the file is
        // declared not-text and we never re-enable text for it
        // via later rules (this matches git's behavior).
        sawBinary = true;
        text = false;
        eol = null;
        continue;
      }
      if (rule.resetText) {
        text = true;
        eol = null;
      }
      if (!text) continue;
      if (rule.eol != null) eol = rule.eol;
    }

    if (sawBinary || !text) return GitAttributesEol.binaryResult;
    if (eol == 'crlf') return GitAttributesEol.crlfResult;
    if (eol == 'lf') return GitAttributesEol.lfResult;
    return null;
  }
}

class _Rule {
  final String raw;
  final RegExp regex;
  final bool anchored; // true for `/foo` patterns
  final bool containsSlash; // true for `foo/bar` (also anchored)
  final bool isDirOnly; // true for `foo/` patterns
  final String? eol; // 'crlf' or 'lf' if the rule set one
  final bool binary; // true if `binary` or `text=false`/`-text`
  final bool resetText; // true if `text` (without `=false`)

  _Rule({
    required this.raw,
    required this.regex,
    required this.anchored,
    required this.containsSlash,
    required this.isDirOnly,
    required this.eol,
    required this.binary,
    required this.resetText,
  });

  bool matches(String relPath) {
    if (isDirOnly) {
      // The file is only a candidate if the path is a directory
      // (we don't have isDirectory here, so we just skip — this
      // matters only for rules that target whole subtrees; an
      // edit will always be on a concrete file, so the rule is
      // irrelevant). The gitattributes file's `foo/` form is
      // intended for attributes that apply to the contents of a
      // directory tree; for our purposes, a `foo/` rule on a
      // file path is a miss.
      return false;
    }
    return regex.hasMatch(relPath);
  }
}

/// Public, package-visible API.
///
///   final lookup = GitAttributesLookup();
///
///   // On every edit / write:
///   final resolved = resolvePath(filePath, cwd);
///   final eol = lookup.eolFor(resolved);
///   // Use eol or fall back to the file's detected line ending.
class GitAttributesLookup {
  /// Cache of parsed .gitattributes files, keyed by the file's
  /// absolute path. The walk upward to find a .gitattributes
  /// terminates at the first hit, so two files in the same
  /// directory tree share the same parsed rules.
  final Map<String, _ParsedGitAttributes> _parsed = {};

  /// In-process memoization of "what's the .gitattributes for
  /// this file?" — the walk is cheap but not free, and the
  /// edit tool calls this for every operation.
  final Map<String, String?> _resolvedPath = {};

  /// Return the effective line-ending directive for [filePath]
  /// (absolute path), or `null` if no `.gitattributes` rule
  /// applies. Callers should fall back to the file's detected
  /// line ending when this is `null`.
  GitAttributesEol? eolFor(String filePath) {
    final resolved = _resolve(filePath);
    if (resolved == null) return null;
    final parsed = _parsed[resolved];
    if (parsed == null) return null;
    return parsed.eolFor(filePath);
  }

  /// True when the file is declared binary. Convenience wrapper
  /// around [eolFor].
  bool isBinary(String filePath) {
    final e = eolFor(filePath);
    return e?.isBinary ?? false;
  }

  /// Walk upward from [start] until a `.gitattributes` is
  /// found, or the filesystem root is reached. Returns the
  /// .gitattributes's absolute path, or `null`.
  String? _resolve(String start) {
    final cached = _resolvedPath[start];
    if (cached != null || _resolvedPath.containsKey(start)) return cached;

    var dir = p.dirname(start);
    String? hit;
    // Bound the loop defensively: in practice we reach '/' in
    // at most depth-of-tree iterations, but a pathological
    // symlink loop or similar would otherwise wedge the
    // process. 256 ancestor levels is far more than any real
    // project has.
    for (var i = 0; i < 256; i++) {
      final candidate = p.join(dir, '.gitattributes');
      if (File(candidate).existsSync()) {
        hit = candidate;
        break;
      }
      final parent = p.dirname(dir);
      if (parent == dir) break; // reached filesystem root
      dir = parent;
    }
    _resolvedPath[start] = hit;
    if (hit != null) {
      final h = hit;
      _parsed.putIfAbsent(h, () => _parse(File(h)));
    }
    return hit;
  }

  /// Drop the in-process cache. Exposed for tests that mutate
  /// the working tree between assertions.
  void clearCache() {
    _parsed.clear();
    _resolvedPath.clear();
  }

  /// Invalidate the cache entry for a specific .gitattributes
  /// file. Useful when the user just edited one and we want
  /// the next lookup to re-read it.
  void invalidate(String gitAttributesPath) {
    _parsed.remove(gitAttributesPath);
  }
}

_ParsedGitAttributes _parse(File file) {
  final lines = file.readAsLinesSync();
  final rules = <_Rule>[];
  for (final raw in lines) {
    var line = raw;
    // Strip trailing CR (Windows-encoded .gitattributes).
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    if (line.isEmpty) continue;
    if (line.startsWith('#')) continue;

    // Split off the pattern. Gitattributes uses whitespace
    // (space or tab) to separate the pattern from the attr
    // list. The pattern itself can contain spaces inside
    // brackets `[...]`, so we don't try to be clever — a
    // regex pattern with `[a b]` is the only realistic case
    // that contains a space, and even there, the first
    // whitespace is the separator.
    final firstSep = _firstUnquotedSpace(line);
    if (firstSep < 0) continue; // no attrs on this line
    final pattern = line.substring(0, firstSep);
    final attrsRaw = line.substring(firstSep + 1).trim();
    if (attrsRaw.isEmpty) continue;

    final attrs = attrsRaw.split(RegExp(r'\s+'));

    // Trailing `/` in the pattern = directory-only.
    var isDirOnly = false;
    var pat = pattern;
    if (pat.endsWith('/')) {
      isDirOnly = true;
      pat = pat.substring(0, pat.length - 1);
    }

    // Leading `/` = anchored to the .gitattributes's own
    // directory. A `/` in the body also anchors the pattern
    // (so `foo/bar` is treated like `/foo/bar`).
    final anchored = pat.startsWith('/');
    final body = anchored ? pat.substring(1) : pat;
    final containsSlash = body.contains('/');
    final anyDepth = !anchored && !containsSlash;

    String? eol;
    var binary = false;
    var resetText = false;
    for (final a in attrs) {
      if (a == 'binary') {
        binary = true;
      } else if (a == '-text') {
        binary = true; // not-text
      } else if (a == 'text=false') {
        binary = true;
      } else if (a == 'text') {
        resetText = true; // re-enable text
        eol = eol ?? 'lf';
      } else if (a == 'eol=crlf') {
        eol = 'crlf';
      } else if (a == 'eol=lf') {
        eol = 'lf';
      } else if (a == 'text=auto') {
        // Git decides; we treat this as "no rule" so the
        // caller falls back to the file's detected line
        // ending. We do NOT set resetText here, because
        // `text=auto` doesn't re-enable text after a
        // binary attribute on a previous line.
      }
    }

    rules.add(
      _Rule(
        raw: raw,
        regex: _globToRegex(body, anyDepth: anyDepth),
        anchored: anchored,
        containsSlash: containsSlash,
        isDirOnly: isDirOnly,
        eol: eol,
        binary: binary,
        resetText: resetText,
      ),
    );
  }
  return _ParsedGitAttributes(path: file.absolute.path, rules: rules);
}

/// Find the index of the first whitespace char (space or tab)
/// outside of `[...]` brackets. Returns -1 if none.
int _firstUnquotedSpace(String s) {
  var inBrackets = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '[') inBrackets = true;
    if (c == ']') inBrackets = false;
    if (!inBrackets && (c == ' ' || c == '\t')) return i;
  }
  return -1;
}

/// Convert a gitignore glob fragment into a Dart RegExp that
/// matches against the path relative to the .gitattributes's
/// directory. Subset of the full gitignore syntax; sufficient
/// for the common gitattributes cases:
///
///   - `*` matches anything except `/`
///   - `**` matches anything including `/`
///   - `?` matches a single char except `/`
///   - `[abc]` character class
///   - `\` escapes a metachar
///   - Patterns without a `/` (and not starting with `/`) match
///     at any depth, so we implicitly prepend `(?:^|.*/)` to
///     allow matching in any subdirectory.
RegExp _globToRegex(String pattern, {required bool anyDepth}) {
  final buf = StringBuffer();
  if (anyDepth) {
    buf.write('(?:^|.*/)');
  } else {
    buf.write('^');
  }
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        if (i + 2 < pattern.length && pattern[i + 2] == '/') {
          buf.write('.*');
          i += 3;
          continue;
        }
        buf.write('.*');
        i += 2;
      } else {
        buf.write('[^/]*');
        i++;
      }
    } else if (c == '?') {
      buf.write('[^/]');
      i++;
    } else if (c == '[') {
      final end = pattern.indexOf(']', i);
      if (end > i) {
        buf.write(pattern.substring(i, end + 1));
        i = end + 1;
      } else {
        buf.write(RegExp.escape(c));
        i++;
      }
    } else if (c == r'\' && i + 1 < pattern.length) {
      buf.write(RegExp.escape(pattern[i + 1]));
      i += 2;
    } else {
      buf.write(RegExp.escape(c));
      i++;
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

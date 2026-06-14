// SPDX-License-Identifier: MIT
//
// Minimal `.gitignore` parser & matcher for the in-process file
// walker. Doesn't try to be exhaustive — just handles the subset
// that matters for filtering source trees:
//   - `#` comments and blank lines
//   - `!foo` negation
//   - `foo` (matches at any depth)
//   - `/foo` (anchored to the .gitignore's own directory)
//   - `foo/` (directory-only)
//   - `*`, `?`, `[abc]`, `**` glob metacharacters
//
// Patterns are converted to Dart `RegExp` once at load time and
// evaluated in a single pass. Negation is the last pattern that
// matches a path wins, which matches git's behavior.

import 'package:path/path.dart' as p;

class _CompiledPattern {
  /// The original pattern string (for debugging / error messages).
  final String raw;

  /// The pattern body (anchored prefix stripped) used to build
  /// [regex]. For non-anchored patterns this is also the
  /// "implicit" match — a plain `foo` matches at any depth, so
  /// when we evaluate it against `underScope` we test the regex
  /// against either the whole `underScope` (anchored) or a
  /// `.*/` prefix + underScope (unanchored). [containsSlash]
  /// tells us whether the user wrote `/` in the pattern, which
  /// flips the matching semantics: a slash in the body means
  /// "this pattern is anchored to a specific sub-path" even
  /// when there's no leading `/` in the raw.
  final String body;

  final bool containsSlash;
  final RegExp regex;

  /// True if the pattern ended with `/` — only directories match.
  final bool isDirOnly;

  /// True if the pattern was anchored to the .gitignore's
  /// directory (started with `/`).
  final bool anchored;

  /// True for negation patterns (`!foo`).
  final bool negation;

  const _CompiledPattern({
    required this.raw,
    required this.body,
    required this.containsSlash,
    required this.regex,
    required this.isDirOnly,
    required this.anchored,
    required this.negation,
  });
}

/// Holds the merged set of patterns from every `.gitignore` in
/// the project. The matching algorithm:
///
/// 1. For a given path, walk back from the path's parent
///    directory up to the .gitignore's own directory, collecting
///    every pattern whose scope covers the path.
/// 2. The last pattern that matches wins (so a later `!foo`
///    overrides an earlier `foo`).
/// 3. The result is "ignored" or "not ignored".
///
/// For paths under directory `d1/d2` and a pattern in
/// `.gitignore` at `d1/d2/.gitignore`, the pattern scope is
/// `d1/d2` and the path is evaluated relative to it.
///
/// Patterns without a `/` (and not starting with `/`) match at
/// any depth, so they apply to every descendant.
class GitignoreMatcher {
  /// Each entry: a list of patterns from one .gitignore file
  /// (compiled up front) + the directory that file lives in.
  final List<({String dir, List<_CompiledPattern> patterns})> _sources = [];

  void loadAll(List<({String directory, List<String> lines})> sources) {
    for (final src in sources) {
      _sources.add((dir: src.directory, patterns: _compile(src.lines)));
    }
  }

  /// True if [relPath] (relative to the project root, with the
  /// same separator convention the index uses — bare names for
  /// top-level entries, `parent/child` for nested) should be
  /// excluded from the file search.
  ///
  /// [isDirectory] should be true when the caller is asking
  /// about a directory. The matcher's `isDirOnly` filter then
  /// drops file-only patterns. A directory pattern (`foo/`)
  /// matches directories only; a plain pattern matches both
  /// (git's own behavior).
  bool matches(String relPath, {required bool isDirectory}) {
    final sep = p.separator;
    final parts = relPath.split(sep);
    var ignored = false;

    for (final src in _sources) {
      // src.dir is the directory the .gitignore lives in,
      // relative to the project root. '.'' means the project
      // root. The path's first [scopeParts.length] segments must
      // match exactly for any of src's patterns to apply.
      final scopeParts = src.dir == '.'
          ? const <String>[]
          : src.dir.split(sep);

      if (parts.length < scopeParts.length) continue;
      var scopeMatch = true;
      for (var i = 0; i < scopeParts.length; i++) {
        if (parts[i] != scopeParts[i]) {
          scopeMatch = false;
          break;
        }
      }
      if (!scopeMatch) continue;

      // The remaining path under src.dir.
      final underScope = parts.sublist(scopeParts.length).join(sep);

      for (final pat in src.patterns) {
        if (pat.isDirOnly && !isDirectory) continue;
        final matched = _patternMatches(pat, underScope);
        if (matched) {
          ignored = !pat.negation;
        }
      }
    }
    return ignored;
  }

  /// Test a single compiled pattern against a path relative to
  /// the .gitignore's directory. Three cases, mirroring git:
  ///
  /// - Anchored pattern (e.g. `/build`): the body's regex must
  ///   match the *whole* underScope string. (We do this by
  ///   building the regex with `^...\Z` anchors and matching the
  ///   full underScope.)
  ///
  /// - Non-anchored pattern with a `/` in the body (e.g.
  ///   `foo/bar`): same as anchored — the body's segments pin
  ///   it to a specific sub-path.
  ///
  /// - Non-anchored, slash-less pattern (e.g. `foo` or `*.log`):
  ///   matches at any depth. We test the regex against both
  ///   the whole underScope AND each `.*/<segment>` form, by
  ///   prepending `(?:^|.*/)` to the regex at compile time. The
  ///   regex already has `^...\Z` anchors so we just test it.
  bool _patternMatches(_CompiledPattern pat, String underScope) {
    return pat.regex.hasMatch(underScope);
  }

  static List<_CompiledPattern> _compile(List<String> lines) {
    final out = <_CompiledPattern>[];
    for (final raw in lines) {
      var line = raw;
      // Strip trailing CR (Windows line endings).
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      // Skip blanks and comments. `\` at the very start escapes
      // a leading `#` or `!`.
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue;
      var negation = false;
      if (line.startsWith('!')) {
        negation = true;
        line = line.substring(1);
      }
      if (line.startsWith('\\')) {
        // Backslash-escaped leading char — git's behavior is
        // to drop the backslash and treat the next char as
        // literal. This matters for patterns starting with
        // `#` or `!` mid-line.
        line = line.substring(1);
      }
      if (line.isEmpty) continue;
      // Trailing `/` = directory-only.
      var isDirOnly = false;
      if (line.endsWith('/')) {
        isDirOnly = true;
        line = line.substring(0, line.length - 1);
      }
      // Trailing `*` is harmless — ignore.
      final anchored = line.startsWith('/');
      final pattern = anchored ? line.substring(1) : line;
      final containsSlash = pattern.contains('/');
      // "Any depth" = non-anchored and no slash in the body.
      // Examples: `*.log` (any depth), `foo` (any depth),
      // `/build` (NOT any depth), `foo/bar` (NOT any depth).
      final anyDepth = !anchored && !containsSlash;
      final regex = _globToRegex(pattern, anyDepth: anyDepth);
      out.add(
        _CompiledPattern(
          raw: raw,
          body: pattern,
          containsSlash: containsSlash,
          regex: regex,
          isDirOnly: isDirOnly,
          anchored: anchored,
          negation: negation,
        ),
      );
    }
    return out;
  }

  /// Convert a gitignore glob fragment into a Dart RegExp that
  /// matches against the path relative to the .gitignore's
  /// directory.
  ///
  /// Gitignore glob semantics (simplified):
  /// - `*` matches anything except `/`
  /// - `**` matches anything including `/`
  /// - `?` matches a single char except `/`
  /// - `[abc]` character class
  /// - `\` escapes a metacharacter
  /// - Patterns without a `/` match at any depth, so we
  ///   implicitly prepend `(?:^|.*/)` to allow matching in any
  ///   subdirectory. Anchored patterns (originally `/foo`) and
  ///   patterns containing `/` do NOT get this prefix.
  /// - Patterns ending in `/` (now stripped) only match dirs;
  ///   we filter at match time via [isDirOnly].
  static RegExp _globToRegex(String pattern, {required bool anyDepth}) {
    final buf = StringBuffer();
    if (anyDepth) {
      // `(?:^|.*/)` so the pattern can match either at the root
      // of the .gitignore's scope or after any number of path
      // segments.
      buf.write('(?:^|.*/)');
    } else {
      buf.write('^');
    }
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      if (c == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          // `**` — match anything including `/`. If followed by
          // a `/`, consume it too (the classic `**/foo` form).
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
        // Find the closing `]`. Anything inside is treated as
        // a character class — no nested `[!]` negation, no
        // ranges like `a-z`. Git's actual behavior is more
        // forgiving but the simple form covers the common case.
        final end = pattern.indexOf(']', i);
        if (end > i) {
          buf.write(pattern.substring(i, end + 1));
          i = end + 1;
        } else {
          buf.write(RegExp.escape(c));
          i++;
        }
      } else if (c == '\\' && i + 1 < pattern.length) {
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
}

// Re-export the source shape so the file_searcher can build a
// list and pass it in without exposing the internal class.
typedef GitignoreSource = ({String directory, List<String> lines});

/// Lightweight fuzzy matcher used by the slash-command autocomplete,
/// the parameter-suggestion popover, and the read-tool "similar
/// files" suggestion when a path doesn't resolve.
///
/// The matcher accepts several flavors of "fuzzy" match, ordered
/// from strongest to weakest. Every match returns a positive
/// integer score; non-matches return 0. The score encodes the
/// tier in the high bits and a within-tier tiebreaker in the low
/// bits, so a simple descending sort produces the desired
/// display order.
///
/// Tier table (highest first):
///
/// | Tier                            | Base score | Tiebreaker                        |
/// |---------------------------------|------------|-----------------------------------|
/// | Exact match (case-insensitive)  | 5000       | shorter candidate wins            |
/// | Prefix match                    | 4000       | shorter candidate wins            |
/// | Substring match                 | 3000       | earlier match index wins          |
/// | Initials prefix (acronym)       | 2500       | shorter initials win              |
/// | Initials subsequence            | 2200       | shorter initials win              |
/// | Subsequence                     | 1000       | shorter candidate wins            |
///
/// The exact tier means typing `/help` (or even `HELP`) ranks
/// `/help` above every prefix/substring/subsequence match. The
/// initials tiers catch acronym-style queries (`/dsp` →
/// `/d-state` whose initials are `ds`, plus subsequence `p`) and
/// rank a strong acronym hit above a weak pure-subsequence hit
/// on the same target — so `/cmt` still finds `/compact` via
/// subsequence, but `/dst` ranks `/d-state` (initials prefix of
/// `ds` then subseq `t`) above a hypothetical `/catalog_theme`
/// (pure subsequence).
///
/// All comparisons are case-insensitive — the user typing `/HELP`
/// or `/Help` should find `/help`. The query is trimmed of
/// surrounding whitespace; an empty query never matches (callers
/// short-circuit on empty and return the unfiltered list).
///
/// A 1-char query can match at every tier. The strongest match
/// wins, so typing `/d` still ranks `/debug` first (prefix tier)
/// followed by other commands containing `d` (substring /
/// subsequence tiers). This is helpful for discovery — the user
/// typing a single letter gets to see every command that
/// mentions it — and matches the user's mental model of fuzzy
/// search (e.g. fzf, VS Code quick open). The chat input shows
/// the top matches first regardless.
library;

/// Score a single [candidate] string against [query]. Returns 0 if
/// the candidate does not fuzzy-match the query, otherwise a positive
/// integer where higher is better.
///
/// See the library doc for the full tier table.
int scoreStringMatch(String query, String candidate) {
  final q = query.trim();
  if (q.isEmpty) return 0;
  final ql = q.toLowerCase();
  final cl = candidate.toLowerCase();

  // 1. Exact match (case-insensitive). Outranks every other tier
  //    so the candidate the user typed verbatim wins, regardless
  //    of length. Tiebreaker rewards shorter candidates — only
  //    relevant when two candidates both equal the query, which
  //    is impossible by construction unless the candidate is the
  //    same string in different cases, but we keep the tiebreaker
  //    for symmetry with the other tiers.
  if (cl == ql) {
    return _tierExact + (1000 - cl.length).clamp(0, 1000);
  }

  // 2. Prefix match — the most common case. Typing `/help` is
  //    a prefix of `/help`, `/help <topic>`, etc. Tiebreaker
  //    rewards shorter candidates so `/help` outranks
  //    `/help-extended` when both are valid matches.
  if (cl.startsWith(ql)) {
    return _tierPrefix + (100 - cl.length).clamp(0, 100);
  }

  // 3. Substring match — query appears anywhere in the candidate.
  //    Earlier index wins, so `/tin` ranks `/continue` (t at 5)
  //    above `/think` (t at 1) only when both tie, but the real
  //    value is that `/new_session` outranks `/_old_new_session`
  //    when both contain the query.
  final idx = cl.indexOf(ql);
  if (idx >= 0) {
    return _tierSubstring + (100 - idx).clamp(0, 100);
  }

  // 4. Initials prefix — query is a prefix of the candidate's
  //    word-initials (e.g., `ds` for `d-state`). Catches the
  //    common "acronym of a hyphenated name" case for debug
  //    commands. Tiebreaker: shorter initials win, so a 2-letter
  //    initials string outranks a 6-letter one when the query
  //    is just 2 chars.
  final initials = computeInitials(candidate);
  final initialsLower = initials.toLowerCase();
  if (initialsLower.startsWith(ql)) {
    return _tierInitialsPrefix + (100 - initialsLower.length).clamp(0, 100);
  }

  // 5. Initials subsequence — query chars appear in order in
  //    the initials, but not as a prefix. Sits below the prefix
  //    tier so a query that is a clean prefix of the initials
  //    still wins.
  if (isSubsequence(initialsLower, ql)) {
    return _tierInitialsSubseq + (100 - initialsLower.length).clamp(0, 100);
  }

  // 6. Subsequence — every char of `ql` appears in `cl` in
  //    order, anywhere. The slowest and weakest branch. Catches
  //    last-resort matches like `cmt` for `compact` when no
  //    higher tier applies.
  if (isSubsequence(cl, ql)) {
    return _tierSubsequence + (100 - cl.length).clamp(0, 100);
  }

  return 0;
}

/// True if every character of [needle] appears in [hay] in order
/// (not necessarily consecutively). Empty strings return false.
/// Case-sensitive — callers pre-lowercase both sides when needed.
bool isSubsequence(String hay, String needle) {
  if (hay.isEmpty || needle.isEmpty) return false;
  var qi = 0;
  for (var i = 0; i < hay.length && qi < needle.length; i++) {
    if (hay.codeUnitAt(i) == needle.codeUnitAt(qi)) qi++;
  }
  return qi == needle.length;
}

/// Compute the lowercased word-initials string for [s]. Word
/// boundaries are camelCase transitions, separators (`/`, `\`, `_`,
/// `-`, `.`, space), and runs of consecutive uppercase letters
/// (`XMLParser` → ['XML', 'Parser']). The first character of each
/// token is emitted in lowercase ASCII form when it falls in
/// `[A-Z]`; non-ASCII first characters pass through unchanged so
/// CJK characters (e.g. `/继续` → `继`) are preserved verbatim.
String computeInitials(String s) {
  final tokens = tokenizeForInitials(s);
  final buf = StringBuffer();
  for (final t in tokens) {
    if (t.isEmpty) continue;
    final c = t.codeUnitAt(0);
    buf.writeCharCode(isAsciiUpper(c) ? c + 0x20 : c);
  }
  return buf.toString();
}

/// Split [s] into word components for initials extraction. The
/// rules are the same as the corresponding helper in
/// [FileSearcher] — camelCase boundaries, separator characters,
/// and consecutive-caps transitions all flush a token. Exposed
/// here so callers (and tests) can inspect the tokenization
/// without re-implementing it.
List<String> tokenizeForInitials(String s) {
  final tokens = <String>[];
  final buf = StringBuffer();

  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);

    // Separator: flush the current buffer as a completed word.
    if (c == 0x2F || // /
        c == 0x5C || // \
        c == 0x5F || // _
        c == 0x2D || // -
        c == 0x2E || // .
        c == 0x20) {
      // space
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
      continue;
    }

    // camelCase boundary: previous was lowercase, current is
    // uppercase → the previous char ended one word, this char
    // starts the next. Flush the buffer.
    if (i > 0 && isAsciiLower(s.codeUnitAt(i - 1)) && isAsciiUpper(c)) {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    }
    // Consecutive-caps boundary: current is lowercase, the two
    // previous chars are uppercase (e.g., `XMLP|arser` →
    // buffer held `XMLP`; we move the `P` to start the new
    // word). Handles `XMLParser` → ['XML', 'Parser'].
    else if (i >= 2 &&
        isAsciiLower(c) &&
        isAsciiUpper(s.codeUnitAt(i - 1)) &&
        isAsciiUpper(s.codeUnitAt(i - 2))) {
      if (buf.isNotEmpty) {
        final prev = buf.toString();
        buf.clear();
        if (prev.length > 1) {
          tokens.add(prev.substring(0, prev.length - 1));
          buf.write(prev.substring(prev.length - 1));
        }
      }
    }

    buf.writeCharCode(c);
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

/// True if [c] is an ASCII lowercase letter (`a`-`z`). Used by
/// the initials tokenizer to detect camelCase boundaries.
bool isAsciiLower(int c) => c >= 0x61 && c <= 0x7A; // a-z

/// True if [c] is an ASCII uppercase letter (`A`-`Z`). Used by
/// the initials tokenizer to detect camelCase boundaries and to
/// lowercase the leading character of each token.
bool isAsciiUpper(int c) => c >= 0x41 && c <= 0x5A; // A-Z

const int _tierExact = 5000;
const int _tierPrefix = 4000;
const int _tierSubstring = 3000;
const int _tierInitialsPrefix = 2500;
const int _tierInitialsSubseq = 2200;
const int _tierSubsequence = 1000;

/// Filter and rank [items] by fuzzy match against [query].
///
/// [keyOf] returns the string used for matching each item. Items
/// whose key does not match the query are dropped. Surviving
/// items are returned in descending score order, so the first
/// element is the best match.
///
/// An empty or whitespace-only [query] returns [items] unchanged
/// (preserves the caller's ordering — typically registry /
/// definition order). Case-insensitive: the user typing
/// `Continue` matches `/continue`.
List<T> fuzzyRank<T>(List<T> items, String Function(T) keyOf, String query) {
  final q = query.trim();
  if (q.isEmpty) return List<T>.unmodifiable(items);

  final results = <_Ranked<T>>[];
  for (final item in items) {
    final s = scoreStringMatch(q, keyOf(item));
    if (s > 0) results.add(_Ranked(item, s));
  }
  results.sort((a, b) => b.score.compareTo(a.score));
  return List<T>.unmodifiable(results.map((r) => r.item));
}

/// Filter and rank [items] where each item exposes multiple
/// candidate strings via [keysOf]. The best score across all
/// keys for a given item is used. Useful for slash commands
/// that have aliases — typing the alias reveals the primary
/// command.
///
/// Same empty-query and case-insensitive behavior as [fuzzyRank].
List<T> fuzzyRankMulti<T>(
  List<T> items,
  Iterable<String> Function(T) keysOf,
  String query,
) {
  final q = query.trim();
  if (q.isEmpty) return List<T>.unmodifiable(items);

  final results = <_Ranked<T>>[];
  for (final item in items) {
    var best = 0;
    for (final key in keysOf(item)) {
      final s = scoreStringMatch(q, key);
      if (s > best) best = s;
    }
    if (best > 0) results.add(_Ranked(item, best));
  }
  results.sort((a, b) => b.score.compareTo(a.score));
  return List<T>.unmodifiable(results.map((r) => r.item));
}

class _Ranked<T> {
  final T item;
  final int score;
  const _Ranked(this.item, this.score);
}

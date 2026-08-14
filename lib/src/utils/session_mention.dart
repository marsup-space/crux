/// Session-mention support for the chat input.
///
/// The `#` trigger mirrors the `@` file-mention and `$` skill-chip
/// affordances: typing `#` opens a session-search popover. The user
/// searches sessions (workspace sessions + global chats) by title or
/// id; archived sessions are included but rank below non-archived
/// matches. Picking a session inserts the user-facing `#<id>:<title>`
/// token, which the submit pipeline rewrites to the LLM-facing
/// `ses://<id>` reference (see [rewriteSessionMentionsFromChips]) so
/// the agent sees the same clickable scheme it is taught to write in
/// its own replies.
library;

import '../models/session.dart';
import 'fuzzy_match.dart';

/// Position of an in-progress `#` session mention in text being
/// edited. Returned by [findActiveSessionMention] when [text]
/// contains a `#` at or before the cursor with no hard terminator
/// between it and the cursor.
class SessionMentionPosition {
  /// Offset of the `#` in [text].
  final int hashOffset;

  /// Offset where the query begins (== hashOffset + 1).
  final int queryStart;

  /// Cursor position (== end of query).
  final int cursor;

  /// Text between the `#` and the cursor.
  final String query;

  const SessionMentionPosition({
    required this.hashOffset,
    required this.queryStart,
    required this.cursor,
    required this.query,
  });
}

/// True if [c] is an "identifier" character — A–Z, a–z, 0–9, `_`,
/// `-`. Used to reject `foo#123`-style tokens (the `#` is part of a
/// longer word, not a mention trigger).
bool _isIdentifierChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x41 && cc <= 0x5A) || // A-Z
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x5F || // _
      cc == 0x2D; // -
}

/// True if [c] is a space or tab.
bool isSessionMentionSpace(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return cc == 0x20 || cc == 0x09;
}

/// True if [c] is a hard terminator for a session-mention query —
/// newline, carriage return, or the punctuation set that a user
/// typically types when they have moved on from the mention to prose.
bool isSessionMentionTerminator(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return cc == 0x0A || // \n
      cc == 0x0D || // \r
      cc == 0x28 || // (
      cc == 0x29 || // )
      cc == 0x5B || // [
      cc == 0x5D || // ]
      cc == 0x7B || // {
      cc == 0x7D || // }
      cc == 0x2C || // ,
      cc == 0x3B; // ;
}

/// Find an in-progress `#` session mention in [text] ending at
/// [cursor]. Returns `null` if there is no mention the user is
/// currently editing.
///
/// "Active" means: there's a `#` at or before the cursor, no hard
/// terminator (newline / punctuation) between it and the cursor, the
/// char immediately before the `#` is not an identifier char, and the
/// char immediately after the `#` is not a space/tab. The last rule is
/// the key one: `# ` (a bare `#` followed by a space) is a plain-text
/// hash, not a mention — so the popover closes and the `#` is not
/// treated as a session reference. Spaces *inside* the query (e.g.
/// `#my session title`) are allowed, since session titles contain
/// spaces.
SessionMentionPosition? findActiveSessionMention(String text, int cursor) {
  final clamped = cursor.clamp(0, text.length);

  var hashOffset = -1;
  for (var i = clamped - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '#') {
      hashOffset = i;
      break;
    }
    if (isSessionMentionTerminator(ch)) return null;
    // Spaces/tabs are allowed mid-query (titles have spaces); the
    // "space directly after `#`" case is rejected below once we
    // know where the `#` is.
  }
  if (hashOffset < 0) return null;

  // Reject `foo#123`: the char before `#` is an identifier char.
  if (hashOffset > 0 && _isIdentifierChar(text[hashOffset - 1])) {
    return null;
  }

  // Reject `# ` / `#\t`: a space directly after the `#` means the
  // user typed a literal hash, not a mention.
  final queryStart = hashOffset + 1;
  if (queryStart < clamped && isSessionMentionSpace(text[queryStart])) {
    return null;
  }

  final query = text.substring(queryStart, clamped);
  return SessionMentionPosition(
    hashOffset: hashOffset,
    queryStart: queryStart,
    cursor: clamped,
    query: query,
  );
}

/// A session surfaced by the `#` mention search, with its fuzzy-match
/// score already adjusted for archived status.
class SessionMention {
  final Session session;

  /// Match score (higher = better). Archived sessions have already
  /// had the [archivedPenalty] subtracted, so they rank below a
  /// non-archived session with an equivalent match.
  final int score;

  const SessionMention({required this.session, required this.score});

  bool get isArchived => session.archivedAt != null;
}

/// A mention chip the user completed via the picker (`#`, `@`, or
/// `$`). [start] is the absolute offset of the trigger char in the
/// input text; [content] is the full chip text including the trigger
/// (e.g. `#123:Title`, `@lib/main.dart`, `$pr-review`).
///
/// Recording the exact span (rather than re-deriving it from the raw
/// text) is what lets the chip renderer draw a precise boundary — so
/// a multi-word title or path stays one chip while prose the user
/// types after the mention is never swallowed into it.
class MentionChip {
  final int start;
  final String content;

  const MentionChip({required this.start, required this.content});
}

/// Penalty applied to archived sessions' match scores. Chosen so an
/// archived session ranks roughly one fuzzy tier below its
/// non-archived equivalent: an archived exact title match (5000-500)
/// still beats a non-archived prefix match (4000), but an archived
/// prefix match (3500) falls below a non-archived prefix (4000).
const int archivedPenalty = 500;

/// Rank [sessions] against [query], matching by title and id. Returns
/// matches in descending order of relevance; archived sessions are
/// demoted by [archivedPenalty]. An empty/whitespace [query] returns
/// every session (recency order, archived below non-archived).
List<SessionMention> rankSessionMentions(
  List<Session> sessions,
  String query, {
  int limit = 50,
}) {
  final q = query.trim();

  final mentions = <SessionMention>[];
  for (final session in sessions) {
    var score = 0;
    if (q.isEmpty) {
      score = 1;
    } else {
      final titleScore = session.title.isEmpty
          ? 0
          : scoreStringMatch(q, session.title);
      final idScore = scoreStringMatch(q, session.id.toString());
      score = titleScore > idScore ? titleScore : idScore;
      if (score <= 0) continue;
      if (session.archivedAt != null) {
        score -= archivedPenalty;
        if (score < 1) score = 1;
      }
    }
    mentions.add(SessionMention(session: session, score: score));
  }

  mentions.sort((a, b) {
    final sa = a.score;
    final sb = b.score;
    if (sa != sb) return sb.compareTo(sa);
    // Tie-break: non-archived first, then most-recently-active first.
    final aArchived = a.isArchived;
    final bArchived = b.isArchived;
    if (aArchived != bArchived) return aArchived ? 1 : -1;
    return b.session.updatedAt.compareTo(a.session.updatedAt);
  });

  return mentions.length <= limit
      ? mentions
      : mentions.sublist(0, limit);
}

/// Rewrite completed session-mention chips into the LLM-facing
/// `ses://<id>` reference the agent is taught to use.
///
/// Unlike a raw-text scan (which can't tell a mention from a prose
/// `issue #123`, and can't know where a multi-word title ends), this
/// rewrites only the exact spans recorded by the picker. A chip whose
/// content is `#<id>` or `#<id>:<title>` becomes `ses://<id>`; the
/// title is dropped because it exists purely for the user's display.
String rewriteSessionMentionsFromChips(
  String input,
  List<MentionChip> chips,
) {
  if (input.isEmpty || chips.isEmpty) return input;

  final sorted = List<MentionChip>.of(chips)
    ..sort((a, b) => a.start.compareTo(b.start));

  final out = StringBuffer();
  var cursor = 0;
  for (final chip in sorted) {
    final end = chip.start + chip.content.length;
    if (chip.start < cursor || chip.start < 0 || end > input.length) {
      continue;
    }
    if (input.substring(chip.start, end) != chip.content) continue;
    final id = _sessionIdFromChipContent(chip.content);
    if (id == null) continue;

    out.write(input.substring(cursor, chip.start));
    out.write('ses://$id');
    cursor = end;
  }
  out.write(input.substring(cursor));
  return out.toString();
}

/// Extract the integer session id from a chip's [content], e.g.
/// `#123:Title` → 123, `#123` → 123. Returns null when the content
/// isn't a `#<digits>…` session chip.
int? _sessionIdFromChipContent(String content) {
  if (content.isEmpty || content[0] != '#') return null;
  var j = 1;
  while (j < content.length && _isDigit(content[j])) {
    j++;
  }
  if (j == 1) return null;
  return int.tryParse(content.substring(1, j));
}

bool _isDigit(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return cc >= 0x30 && cc <= 0x39;
}

/// Human-readable "how long ago" string for the popover metadata, e.g.
/// `just now`, `5m ago`, `3h ago`, `3d ago`, `2w ago`, `4mo ago`.
String describeRelativeTime(DateTime when, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(when);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
  return '${(diff.inDays / 365).floor()}y ago';
}

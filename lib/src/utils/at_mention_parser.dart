/// Shared logic for finding an in-progress @-mention inside the
/// chat input's text buffer.
///
/// Two places need to walk the text and locate the active `@`:
///
///   1. `ChatInputState._findActiveMention`, which decides whether
///      to show the file browser popover and which fragment the
///      user is currently typing.
///   2. `OverlayController.insertAtMention` (mouse-tap path), which
///      falls back to "the last `@` at or before the cursor" when
///      the caller didn't pre-compute the offset.
///
/// Both used to live inline and disagreed slightly on edge cases
/// (e.g. the email check). Consolidating them here keeps the two
/// call sites in sync and makes the rules unit-testable in
/// isolation from the UI.
library;

/// Position of an active @-mention in text being edited.
///
/// Returned by [findActiveMentionInText] when [text] contains an
/// in-progress mention — i.e., there's an `@` somewhere at or
/// before [cursor] with no terminator between it and the cursor.
class AtMentionPosition {
  /// Offset of the `@` in [text].
  final int atOffset;

  /// Offset where the query begins (== atOffset + 1). Convenience
  /// field — callers use either this or [atOffset] depending on
  /// whether they want to replace the `@` itself.
  final int queryStart;

  /// Cursor position (== end of query).
  final int cursor;

  /// Text between the `@` and the cursor.
  final String query;

  const AtMentionPosition({
    required this.atOffset,
    required this.queryStart,
    required this.cursor,
    required this.query,
  });
}

/// Find an active @-mention in [text] ending at [cursor]. Returns
/// `null` if there is no mention the user is currently editing.
///
/// "Active" means: there's an `@` at or before the cursor, no
/// terminator between it and the cursor, and the char immediately
/// before the `@` is not an identifier char (so `foo@bar` doesn't
/// trigger when the user types an email address).
///
/// ### Terminators
///
/// The following characters end the mention:
///
///   * Whitespace — UNLESS the whitespace is inside a multi-word
///     path component (e.g. `My Documents` or trailing `My `), in
///     which case it is part of the path. This is what lets the
///     user @-mention files inside directories whose names contain
///     spaces.
///   * Commas, semicolons, parens, brackets, braces — always
///     end the mention, even when surrounded by path chars. These
///     are the punctuation marks a user typically types when they
///     have moved on from the mention to prose.
AtMentionPosition? findActiveMentionInText(String text, int cursor) {
  final clamped = cursor.clamp(0, text.length);

  // Walk backwards from the cursor looking for an `@` that
  // opens an in-progress mention. Stop at any terminator.
  var atOffset = -1;
  for (var i = clamped - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '@') {
      atOffset = i;
      break;
    }
    final cc = ch.codeUnitAt(0);
    if (cc == 0x20 || cc == 0x09 || cc == 0x0A) {
      // Whitespace. End the mention UNLESS the whitespace is
      // inside a multi-word path component.
      //
      // Two sub-cases keep the mention alive:
      //   1. The char on the cursor side of the space is a
      //      path-name char (e.g. `My Documents` — the `s` of
      //      "Documents" is on the cursor side of the space).
      //   2. The cursor is right after the space (trailing
      //      space, e.g. `My `) AND the char on the far side
      //      of the space is a path-name char.
      //
      // We walk backwards, so we have access to the cursor
      // side (text[i+1]) immediately and the far side (text[i-1])
      // requires a second look at the next iteration. The
      // check below only uses the cursor side; the far side
      // is implicitly correct because if the cursor-side char
      // is a path-name char, the space is in the middle of a
      // name (case 1). For the trailing case the cursor is
      // immediately past the space — we have no cursor-side
      // char to inspect, so we look at the far side instead.
      final nextChar = i + 1 < clamped ? text[i + 1] : '';
      if (isPathNameChar(nextChar)) continue;
      if (nextChar.isEmpty && i - 1 >= 0 && isPathNameChar(text[i - 1])) {
        continue;
      }
      return null;
    }
    // Punctuation that always ends the mention — comma,
    // semicolon, and the various bracket pairs.
    if (cc == 0x28 ||
        cc == 0x29 || // ( )
        cc == 0x5B ||
        cc == 0x5D || // [ ]
        cc == 0x7B ||
        cc == 0x7D || // { }
        cc == 0x2C ||
        cc == 0x3B) {
      // , ;
      return null;
    }
  }
  if (atOffset < 0) return null;

  // Reject email-style mentions: the char immediately before
  // the `@` must not be an identifier char (A–Z, a–z, 0–9, _, -).
  // Without this, `user@example.com` would parse as a mention
  // for `example.com`.
  if (atOffset > 0) {
    final prev = text[atOffset - 1];
    if (_isMentionChar(prev)) return null;
  }

  final query = text.substring(atOffset + 1, clamped);
  return AtMentionPosition(
    atOffset: atOffset,
    queryStart: atOffset + 1,
    cursor: clamped,
    query: query,
  );
}

/// True if [c] is a letter / digit / underscore / hyphen / period
/// — i.e., a character that is allowed inside a single file or
/// directory name. The period is included so file extensions
/// (`main.dart`) are recognized as part of the name.
///
/// Used by [findActiveMentionInText] to decide whether a space
/// is "inside a multi-word path component" (surrounded by path
/// chars) or "ending the mention" (surrounded by punctuation or
/// the buffer boundary).
bool isPathNameChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x41 && cc <= 0x5A) || // A-Z
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x5F || // _
      cc == 0x2D || // -
      cc == 0x2E; // .
}

/// True if [c] is an "identifier" character — A–Z, a–z, 0–9, `_`,
/// `-`. Used to reject email-style `@` mentions: a `@` is only
/// the start of a mention if the char immediately before it is
/// not an identifier char.
///
/// Period is intentionally excluded here (vs. [isPathNameChar]):
/// `foo.@bar` reads as "the email `foo.` is at `bar`" only
/// loosely, but `.` as a "word break" matches typical prose
/// expectations and prevents awkward false positives.
bool _isMentionChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x41 && cc <= 0x5A) || // A-Z
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x5F || // _
      cc == 0x2D; // -
}

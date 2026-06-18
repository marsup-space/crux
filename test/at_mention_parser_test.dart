import 'package:crux/src/utils/at_mention_parser.dart';
import 'package:test/test.dart';

/// Tests for the @-mention parser. The parser is the single source
/// of truth for "is the user currently editing an @-mention?" and
/// is used by both the chat input (to decide whether to show the
/// file browser popover) and the overlay controller (as the
/// fallback for the mouse-tap path of `insertAtMention`).
void main() {
  group('findActiveMentionInText — basic shape', () {
    test('just `@` at the cursor is an active mention with empty query',
        () {
      final pos = findActiveMentionInText('@', 1);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 0);
      expect(pos.queryStart, 1);
      expect(pos.cursor, 1);
      expect(pos.query, '');
    });

    test('`@foo` after the `o` is an active mention', () {
      final pos = findActiveMentionInText('@foo', 4);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 0);
      expect(pos.query, 'foo');
    });

    test('no `@` in the text → null', () {
      expect(findActiveMentionInText('hello world', 11), isNull);
    });

    test('empty text → null', () {
      expect(findActiveMentionInText('', 0), isNull);
    });

    test('cursor at 0 → null', () {
      // Nothing to the left of the cursor to inspect.
      expect(findActiveMentionInText('@foo', 0), isNull);
    });
  });

  group('findActiveMentionInText — email rejection', () {
    test('`user@example.com` is not a mention (alnum before @)', () {
      expect(findActiveMentionInText('user@example.com', 15), isNull);
    });

    test('`email me at user@example.com please` is not a mention', () {
      // The `@` is preceded by a space, so the @-parser would
      // normally find it. The email check stops it: the char
      // before `@` is `r`, an identifier char.
      expect(
        findActiveMentionInText('email me at user@example.com please', 25),
        isNull,
      );
    });

    test('`_foo@bar` is not a mention (underscore before @)', () {
      expect(findActiveMentionInText('_foo@bar', 8), isNull);
    });

    test('`foo-bar@baz` is not a mention (hyphen before @)', () {
      expect(findActiveMentionInText('foo-bar@baz', 11), isNull);
    });

    test('` @foo` *is* a mention (space before @, not identifier)',
        () {
      // The space before `@` is not an identifier char, so the
      // email-style rejection doesn't apply. The mention is
      // active with query `foo`.
      final pos = findActiveMentionInText(' @foo', 5);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 1);
      expect(pos.query, 'foo');
    });
  });

  group('findActiveMentionInText — punctuation terminators', () {
    test('comma after the @ ends the mention', () {
      expect(findActiveMentionInText('@foo,', 5), isNull);
    });

    test('semicolon after the @ ends the mention', () {
      expect(findActiveMentionInText('@foo;', 5), isNull);
    });

    test('paren after the @ ends the mention', () {
      expect(findActiveMentionInText('@foo)', 5), isNull);
    });

    test('bracket after the @ ends the mention', () {
      expect(findActiveMentionInText('@foo]', 5), isNull);
    });

    test('brace after the @ ends the mention', () {
      expect(findActiveMentionInText('@foo}', 5), isNull);
    });

    test('mention only activates for the latest `@`', () {
      // Two `@` in the text; the cursor is right after the second.
      // The parser should find the *last* `@` at or before the
      // cursor. (`hello @a then @b` has length 17: `hello ` is 6,
      // then `@a` is 2, then ` then ` is 6, then `@b` is 2; the
      // second `@` is at index 14 and `b` is at index 15.)
      final pos = findActiveMentionInText('hello @a then @b', 16);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 14);
      expect(pos.query, 'b');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // Paths containing spaces — the case this file exists to lock in.
  // ─────────────────────────────────────────────────────────────────
  group('findActiveMentionInText — paths with spaces', () {
    test('space inside a multi-word path component keeps the mention', () {
      // `@My Documents/note.txt` — the space between `My` and
      // `Documents` is inside a path component, so the mention
      // stays active. (This is the bug the parser was failing on
      // before the fix: the old code treated any space as a
      // terminator and returned null here.)
      final pos = findActiveMentionInText('@My Documents/note.txt', 22);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 0);
      expect(pos.query, 'My Documents/note.txt');
    });

    test('trailing space after a path component keeps the mention', () {
      // The user just typed `@My Documents ` (trailing space) and
      // the cursor is sitting just after the space. The space is
      // at the very end of the query and is preceded by a
      // path-name char (`s`), so the mention is still active —
      // the user is about to type the next path component.
      // (`@My Documents ` has length 14, so the cursor at 14 is
      // immediately past the trailing space.)
      final pos = findActiveMentionInText('@My Documents ', 14);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 0);
      expect(pos.query, 'My Documents ');
    });

    test('multi-word name with no slash keeps the mention', () {
      // `@My Document` — there's no slash, but the space is
      // still inside a path component. The user might be typing
      // a file name that has a space in it.
      final pos = findActiveMentionInText('@My Document', 12);
      expect(pos, isNotNull);
      expect(pos!.query, 'My Document');
    });

    test('nested path with spaces in every component', () {
      // `my project/src/notes file.md` — every component has a
      // space, and the parser must walk past every one of them
      // to find the `@`.
      final pos = findActiveMentionInText(
        '@my project/src/notes file.md',
        30,
      );
      expect(pos, isNotNull);
      expect(pos!.atOffset, 0);
      expect(pos.query, 'my project/src/notes file.md');
    });

    test('mid-sentence mention with a space inside', () {
      // `look at @My Documents/foo` — the mention starts at
      // index 8, the space inside the path component does not
      // end the mention, and the prose on the left of the `@`
      // is ignored. (The string has length 25 — `look at ` is 8,
      // then `@My Documents/foo` is 17 — so the cursor at 25 is
      // immediately past the trailing `o`.)
      final pos = findActiveMentionInText('look at @My Documents/foo', 25);
      expect(pos, isNotNull);
      expect(pos!.atOffset, 8);
      expect(pos.query, 'My Documents/foo');
    });

    test('mention followed by a punctuation terminator', () {
      // `@My Documents, please` — the comma after the path
      // ends the mention, but the space *inside* the path does
      // not. The parser walks past the trailing space, hits the
      // comma, and returns null.
      expect(
        findActiveMentionInText('@My Documents, please', 20),
        isNull,
      );
    });
  });

  group('findActiveMentionInText — whitespace that IS a terminator', () {
    test('lone `@` followed by a space (empty query) ends the mention',
        () {
      // `@ ` — the user typed `@` and then a space, with nothing
      // in between. The cursor is on the space. The char to the
      // left (`@`) is not a path-name char, so the space ends
      // the mention.
      expect(findActiveMentionInText('@ ', 2), isNull);
    });

    test('space adjacent to punctuation ends the mention', () {
      // `@( foo` — the `(` is a punctuation terminator. Walking
      // back from the cursor, the parser hits `(` and returns
      // null. The space inside ` foo` is never reached.
      expect(findActiveMentionInText('@( foo', 6), isNull);
    });

    test('space preceded by a punctuation block on the far side ends the mention',
        () {
      // `@foo, bar` — the comma is a terminator. Walking back
      // from the cursor, the parser hits the space at index 5,
      // and text[i+1] is `b` (a path-name char) — so the space
      // passes. Then it hits the comma at index 4, which is a
      // terminator, and returns null.
      expect(findActiveMentionInText('@foo, bar', 9), isNull);
    });
  });

  group('isPathNameChar', () {
    test('letters, digits, underscore, hyphen, and period are path chars',
        () {
      for (final c in [
        'a', 'Z', '0', '9',
        '_', '-', '.',
      ]) {
        expect(isPathNameChar(c), isTrue, reason: 'expected `$c` to be a path char');
      }
    });

    test('whitespace, punctuation, and other chars are not path chars',
        () {
      for (final c in [
        ' ', '\t', '\n',
        '(', ')', '[', ']', '{', '}',
        ',', ';', '@', '!', '?',
        '/', '\\',
        '~', '*', '`', '\'',
      ]) {
        expect(isPathNameChar(c), isFalse, reason: 'expected `$c` to not be a path char');
      }
    });

    test('empty string is not a path char', () {
      expect(isPathNameChar(''), isFalse);
    });
  });
}

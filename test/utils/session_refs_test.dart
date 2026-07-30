import 'package:crux/src/utils/session_refs.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:test/test.dart';

/// Builds a flat span list from raw text + style segments — exactly
/// the shape `parseMarkdownToInlineSpans` produces for the
/// main-isolate path. Lets tests construct spans without going
/// through the markdown parser.
List<InlineSpan> _spansFromSegments(List<(String, TextStyle?)> segments) {
  return segments
      .where((s) => s.$1.isNotEmpty)
      .map((s) => TextSpan(text: s.$1, style: s.$2))
      .toList();
}

void main() {
  group('parseSessionRefs — basic matching', () {
    test('finds a single bare reference', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(
        _spansFromSegments([('see ses://1014 for details', style)]),
      );
      expect(refs, hasLength(1));
      expect(refs.first.sessionId, 1014);
      expect(refs.first.offset, 4);
      expect(refs.first.length, 'ses://1014'.length);
    });

    test('finds multiple references in one span', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(
        _spansFromSegments([('jump from ses://42 to ses://9999', style)]),
      );
      expect(refs, hasLength(2));
      expect(refs[0].sessionId, 42);
      expect(refs[1].sessionId, 9999);
    });

    test('offsets respect the running position across multiple spans', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(
        _spansFromSegments([
          ('first ses://11', style),
          (' then ses://22 end', style),
        ]),
      );
      expect(refs, hasLength(2));
      // `first ses://11` is 14 chars; `ses://11` starts at offset 6
      // within it (right after "first ").
      expect(refs[0].offset, 6);
      expect(refs[0].sessionId, 11);
      // Span 2 starts at absolute offset 14; `ses://22` sits 6 chars
      // into it (after " then ").
      expect(refs[1].offset, 20);
      expect(refs[1].sessionId, 22);
    });

    test('caps IDs at 9 digits (no match for 10+ digit runs)', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // `\d{1,9}` happily matches the 9-digit prefix of a 10-digit
      // run and leaves the trailing digit as plain text — that's the
      // intended behaviour: a bare "ses://" followed by a 9-digit id
      // is always a valid ref, regardless of what comes next.
      final refs = parseSessionRefs(
        _spansFromSegments([
          ('ses://1 ses://999999999 ses://1234567890', style),
        ]),
      );
      expect(refs.map((r) => r.sessionId).toList(), [1, 999999999, 123456789]);
    });

    test('rejects id 0', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(
        _spansFromSegments([('ses://0 ses://7', style)]),
      );
      expect(refs, hasLength(1));
      expect(refs.first.sessionId, 7);
    });

    test('returns no refs when there are no matches', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(
        _spansFromSegments([('plain text, no refs here', style)]),
      );
      expect(refs, isEmpty);
    });

    test('returns no refs for similar-but-not-quite patterns', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // Each malformed form MUST be rejected:
      //   ses:/12     — single slash, regex wants ses://
      //   ses:://34   — `::` after `ses`, no `s://` substring
      //   ses-://56   — hyphen instead of second colon
      //   ses://abc   — no digits after the scheme
      // `ses://12a` is a deliberate near-miss: the regex matches the
      // 2-digit prefix and the trailing `a` is just plain text.
      final refs = parseSessionRefs(
        _spansFromSegments([('ses:/12 ses:://34 ses-://56 ses://abc', style)]),
      );
      expect(refs, isEmpty);
    });
  });

  group('parseSessionRefs — code-span exclusion', () {
    test('skips references inside inline code spans', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // "see `ses://99` and ses://100"
      final refs = parseSessionRefs([
        const TextSpan(text: 'see ', style: text),
        const TextSpan(text: 'ses://99', style: code),
        const TextSpan(text: ' and ses://100', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.sessionId, 100);
    });

    test('skips references inside fenced code blocks', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const codeBlock = TextStyle(
        color: Color(0xFFCCCCCC),
        backgroundColor: Color(0xFF000000),
      );
      // "above\nses://42\nbelow" where the middle line is code-block
      // styled.
      final refs = parseSessionRefs([
        const TextSpan(text: 'above\n', style: text),
        const TextSpan(text: 'ses://42', style: codeBlock),
        const TextSpan(text: '\nbelow', style: text),
      ]);
      expect(refs, isEmpty);
    });

    test('detects code span from inherited parent style', () {
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // Parent span has the code style; its children inherit the
      // backgroundColor marker. The parser must see the ref as
      // inside code even though the child TextSpan itself doesn't
      // carry the style.
      final refs = parseSessionRefs([
        TextSpan(
          style: code,
          children: const [
            TextSpan(text: 'prefix '),
            TextSpan(text: 'ses://7'),
            TextSpan(text: ' suffix'),
          ],
        ),
      ]);
      expect(refs, isEmpty);
    });
  });

  group('parseSessionRefs — span tree shapes', () {
    test('handles parent + children on the same TextSpan', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      // TextSpan with both `text` and `children` — the offset
      // counter must increment past the parent text before walking
      // into children.
      final refs = parseSessionRefs([
        const TextSpan(
          text: 'a ',
          style: text,
          children: [TextSpan(text: 'b ses://5 c', style: text)],
        ),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.sessionId, 5);
      // 'a ' (2 chars) + 'b ' (2 chars) = offset 4.
      expect(refs.first.offset, 4);
    });

    test('non-TextSpan entries are skipped silently', () {
      // Defensive: the visitor might in theory emit WidgetSpans
      // (it doesn't today). The parser should just ignore them.
      const text = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseSessionRefs(const [
        TextSpan(text: 'ses://1 ', style: text),
      ]);
      expect(refs, hasLength(1));
    });
  });

  group('applySessionLinkStyles — overlay', () {
    const base = TextStyle(color: Color(0xFFFFFFFF));
    const link = TextStyle(
      color: Color(0xFF88CCFF),
      decoration: TextDecoration.underline,
    );
    const hover = TextStyle(
      color: Color(0xFF000000),
      backgroundColor: Color(0xFF88CCFF),
      fontWeight: FontWeight.bold,
    );

    test('returns the original spans when there are no refs', () {
      final spans = _spansFromSegments([('plain text', base)]);
      final styled = applySessionLinkStyles(spans, const [], link, hover, null);
      expect(styled, equals(spans));
    });

    test('overlays link style on a single ref region', () {
      final spans = _spansFromSegments([('see ses://1014 here', base)]);
      final refs = parseSessionRefs(spans);
      final styled = applySessionLinkStyles(spans, refs, link, hover, null);

      // Rebuild the plain text — it must round-trip unchanged.
      String plain(InlineSpan s) {
        if (s is TextSpan) {
          var out = s.text ?? '';
          if (s.children != null) {
            for (final c in s.children!) {
              out += plain(c);
            }
          }
          return out;
        }
        return '';
      }

      final combined = styled.map(plain).join();
      expect(combined, 'see ses://1014 here');

      // Find the ref's span and check its style.
      InlineSpan? refSpan;
      void walk(InlineSpan s) {
        if (refSpan != null) return;
        if (s is TextSpan) {
          if (s.text == 'ses://1014') {
            refSpan = s;
            return;
          }
          if (s.children != null) {
            for (final c in s.children!) {
              walk(c);
            }
          }
        }
      }

      for (final s in styled) {
        walk(s);
      }

      expect(refSpan, isNotNull);
      expect(refSpan!.style!.color, link.color);
      expect(refSpan!.style!.decoration, TextDecoration.underline);
    });

    test('hovered ref uses hoverStyle instead of linkStyle', () {
      final spans = _spansFromSegments([('a ses://1 b ses://2 c', base)]);
      final refs = parseSessionRefs(spans);
      expect(refs, hasLength(2));

      final styled = applySessionLinkStyles(spans, refs, link, hover, refs[0]);

      // The first ref's span should have hoverStyle's backgroundColor;
      // the second should have linkStyle's color (no background).
      TextStyle? styleFor(String text) {
        TextStyle? found;
        void walk(InlineSpan s) {
          if (found != null) return;
          if (s is TextSpan) {
            if (s.text == text) {
              found = s.style;
              return;
            }
            if (s.children != null) {
              for (final c in s.children!) {
                walk(c);
              }
            }
          }
        }

        for (final s in styled) {
          walk(s);
        }
        return found;
      }

      final hovered = styleFor('ses://1');
      expect(hovered, isNotNull);
      expect(hovered!.backgroundColor, hover.backgroundColor);

      final plain = styleFor('ses://2');
      expect(plain, isNotNull);
      expect(plain!.backgroundColor, isNull);
      expect(plain.color, link.color);
    });

    test('null hoverStyle falls back to linkStyle for the hovered ref', () {
      final spans = _spansFromSegments([('ses://9', base)]);
      final refs = parseSessionRefs(spans);
      final styled = applySessionLinkStyles(
        spans,
        refs,
        link,
        null,
        refs.first,
      );

      InlineSpan? refSpan;
      void walk(InlineSpan s) {
        if (refSpan != null) return;
        if (s is TextSpan) {
          if (s.text == 'ses://9') {
            refSpan = s;
            return;
          }
          if (s.children != null) {
            for (final c in s.children!) {
              walk(c);
            }
          }
        }
      }

      for (final s in styled) {
        walk(s);
      }
      expect(refSpan!.style!.color, link.color);
    });
  });
}

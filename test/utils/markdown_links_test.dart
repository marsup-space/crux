import 'package:nocterm/nocterm.dart';
import 'package:crux/src/utils/markdown_links.dart';
import 'package:test/test.dart';

void main() {
  group('applyMarkdownLinkStyles — overlay', () {
    test('returns the original spans when there are no links', () {
      final spans = [const TextSpan(text: 'plain text')];
      final styled = applyMarkdownLinkStyles(
        spans,
        const [],
        const TextStyle(color: Colors.blue),
        null,
        null,
      );
      // No allocations needed — the input list is returned verbatim.
      expect(identical(styled, spans), isTrue);
    });

    test('overlays link style on a single link region', () {
      // "Visit Google" — Google is at offset 6 with length 6.
      final spans = [const TextSpan(text: 'Visit Google')];
      const link = MarkdownLink(
        label: 'Google',
        url: 'https://google.com',
        offset: 6,
        length: 6,
      );
      const linkStyle = TextStyle(color: Colors.blue);
      final styled = applyMarkdownLinkStyles(
        spans,
        const [link],
        linkStyle,
        null,
        null,
      );

      // The flat text is preserved.
      final flatText = styled.map((s) => (s as TextSpan).text).join();
      expect(flatText, 'Visit Google');

      // The "Google" span carries the link style.
      final linkSpan = styled.firstWhere(
        (s) => (s as TextSpan).text == 'Google',
      );
      expect((linkSpan as TextSpan).style?.color, Colors.blue);

      // The "Visit " span carries the original (null) style.
      final beforeSpan = styled.firstWhere(
        (s) => (s as TextSpan).text == 'Visit ',
      );
      expect((beforeSpan as TextSpan).style, isNull);
    });

    test('hovered link uses hoverStyle instead of linkStyle', () {
      final spans = [const TextSpan(text: 'Visit Google')];
      const link = MarkdownLink(
        label: 'Google',
        url: 'https://google.com',
        offset: 6,
        length: 6,
      );
      const linkStyle = TextStyle(color: Colors.blue);
      const hoverStyle = TextStyle(
        color: Colors.white,
        backgroundColor: Colors.blue,
        fontWeight: FontWeight.bold,
      );
      final styled = applyMarkdownLinkStyles(
        spans,
        const [link],
        linkStyle,
        hoverStyle,
        link,
      );

      final linkSpan = styled.firstWhere(
        (s) => (s as TextSpan).text == 'Google',
      );
      final s = linkSpan as TextSpan;
      expect(s.style?.color, Colors.white);
      expect(s.style?.backgroundColor, Colors.blue);
      expect(s.style?.fontWeight, FontWeight.bold);
    });

    test('null hoverStyle falls back to linkStyle for hovered link', () {
      final spans = [const TextSpan(text: 'Visit Google')];
      const link = MarkdownLink(
        label: 'Google',
        url: 'https://google.com',
        offset: 6,
        length: 6,
      );
      const linkStyle = TextStyle(color: Colors.blue);
      final styled = applyMarkdownLinkStyles(
        spans,
        const [link],
        linkStyle,
        null,
        link,
      );

      final linkSpan = styled.firstWhere(
        (s) => (s as TextSpan).text == 'Google',
      );
      expect((linkSpan as TextSpan).style?.color, Colors.blue);
    });

    test('handles multiple non-adjacent links in the same paragraph', () {
      // "Read docs and blog" — positions:
      //   R(0) e(1) a(2) d(3) ' '(4) d(5) o(6) c(7) s(8)
      //   ' '(9) a(10) n(11) d(12) ' '(13) b(14) l(15) o(16) g(17)
      // docs at offset 5..9 (length 4), blog at offset 14..18 (length 4).
      final spans = [const TextSpan(text: 'Read docs and blog')];
      const docs = MarkdownLink(
        label: 'docs',
        url: 'https://docs.example.com',
        offset: 5,
        length: 4,
      );
      const blog = MarkdownLink(
        label: 'blog',
        url: 'https://blog.example.com',
        offset: 14,
        length: 4,
      );
      const linkStyle = TextStyle(color: Colors.blue);
      final styled = applyMarkdownLinkStyles(
        spans,
        const [docs, blog],
        linkStyle,
        null,
        null,
      );

      final flatText = styled.map((s) => (s as TextSpan).text).join();
      expect(flatText, 'Read docs and blog');

      final docsSpan = styled.firstWhere((s) => (s as TextSpan).text == 'docs');
      final blogSpan = styled.firstWhere((s) => (s as TextSpan).text == 'blog');
      expect((docsSpan as TextSpan).style?.color, Colors.blue);
      expect((blogSpan as TextSpan).style?.color, Colors.blue);

      // The " and " between them stays plain (offset 9..14 in the
      // input, since docs ends at 9 and blog starts at 14).
      final betweenSpan = styled.firstWhere(
        (s) => (s as TextSpan).text == ' and ',
      );
      expect((betweenSpan as TextSpan).style, isNull);
    });

    test('preserves inner formatting on link spans', () {
      // Simulate a markdown link with bold label: the visitor emits
      // a parent TextSpan (link style) wrapping a bold child. The
      // overlay merges linkStyle onto the span's existing style so
      // bold survives. The flat input is the WHOLE tree flattened:
      //   "See " (offset 0..4, no style)
      //   "important" (offset 4..13, bold)
      final spans = [
        TextSpan(
          text: 'See ',
          children: [
            const TextSpan(
              text: 'important',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ];
      const link = MarkdownLink(
        label: 'important',
        url: 'https://example.com',
        offset: 4,
        length: 9,
      );
      const linkStyle = TextStyle(color: Colors.blue);
      final styled = applyMarkdownLinkStyles(
        spans,
        const [link],
        linkStyle,
        null,
        null,
      );

      // Find the span that contains "important" — the overlay
      // flattens the tree, so it'll be a top-level TextSpan.
      final important = styled.firstWhere(
        (s) => (s as TextSpan).text?.contains('important') ?? false,
      );
      final s = important as TextSpan;
      // Bold is preserved from the original style, color comes from
      // the link style overlay.
      expect(s.style?.fontWeight, FontWeight.bold);
      expect(s.style?.color, Colors.blue);
    });
  });
}

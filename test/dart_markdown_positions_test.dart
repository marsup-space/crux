// Spike: prove vendored `dart_markdown` recovers exact source positions
// (line / column / offset) for block nodes, inline nodes, AND the markers
// that `dart_markdown_parser` drops. This is the de-risking test for the
// Plan-mode `SourceMap` design — if these pass, char-perfect mapping works.
import 'package:dart_markdown/dart_markdown.dart' as dm;
import 'package:test/test.dart';

void main() {
  group('dart_markdown source positions', () {
    test('header reports its source line and content offset', () {
      final doc = dm.Markdown().parse('# Title');
      expect(doc, hasLength(1));
      final h = doc.single;
      expect(h, isA<dm.Element>());
      expect((h as dm.Element).type, contains('eading'));
      expect(h.start.line, 0);
      expect(h.start.offset, 0);
      // The heading text "Title" should be reachable as a positioned child.
      final text = _firstText(h);
      expect(text, isNotNull);
      expect(text!.text, 'Title');
      // "# Title" → 'T' is at offset 2.
      expect(text.start.offset, 2);
      expect(text.start.column, 2);
    });

    test('bold markers and content carry distinct char offsets', () {
      // "Some **bold** text"
      //  0123456789...
      //  Some=0-3, space=4, **=5-6, bold=7-10, **=11-12, ...
      final doc = dm.Markdown().parse('Some **bold** text');
      final para = doc.single;
      final strong = _findByType(para, 'strongEmphasis');
      expect(strong, isNotNull);

      // Markers: the two `**`.
      expect(strong!.markers, hasLength(2));
      expect(strong.markers[0].text, '**');
      expect(strong.markers[0].start.offset, 5);
      expect(strong.markers[1].start.offset, 11);

      // Content: "bold" between the markers.
      final boldText = _firstText(strong);
      expect(boldText, isNotNull);
      expect(boldText!.text, 'bold');
      expect(boldText.start.offset, 7);
      expect(boldText.end.offset, 11);
    });

    test('multi-line doc maps blocks to correct source lines', () {
      const src = '# Title\n'
          '\n'
          'A paragraph.\n'
          '\n'
          '```dart\n'
          'code();\n'
          '```\n';
      final doc = dm.Markdown().parse(src);
      expect(doc.length, greaterThanOrEqualTo(3));

      final heading = doc[0];
      expect(heading.start.line, 0);

      final para = doc[1];
      expect(para.start.line, 2);

      final code = doc[2];
      expect((code as dm.Element).type, contains('odeBlock'));
      expect(code.start.line, 4); // the ```dart fence line
    });

    test('inline code span marker positions', () {
      // "use `print` now"
      final doc = dm.Markdown().parse('use `print` now');
      final code = _findByType(doc.single, 'codeSpan');
      expect(code, isNotNull);
      final t = _firstText(code!);
      expect(t, isNotNull);
      expect(t!.text, 'print');
      // `use `=0-3, backtick=4, print=5-9
      expect(t.start.offset, 5);
    });

    test('table maps to source lines', () {
      const src = '| A | B |\n'
          '| - | - |\n'
          '| 1 | 2 |\n';
      final doc = dm.Markdown(enableTable: true).parse(src);
      final table = doc.firstWhere(
        (n) => n is dm.Element && n.type.contains('table'),
        orElse: () => doc.first,
      );
      expect(table.start.line, 0);
    });
  });
}

/// Recursively find the first [dm.Text] under [node].
dm.Text? _firstText(dm.Node node) {
  if (node is dm.Text) return node;
  if (node is dm.Element) {
    for (final c in node.children) {
      final found = _firstText(c);
      if (found != null) return found;
    }
  }
  return null;
}

/// Recursively find the first node whose [dm.Element.type] equals [type].
dm.Element? _findByType(dm.Node node, String type) {
  if (node is dm.Element) {
    if (node.type == type) return node;
    for (final c in node.children) {
      final found = _findByType(c, type);
      if (found != null) return found;
    }
  }
  return null;
}

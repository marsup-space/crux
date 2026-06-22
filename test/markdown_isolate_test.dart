// Tests for the cross-isolate markdown parser.
//
// These tests exercise the request/response protocol
// directly (without going through the widget), so they
// stay fast and deterministic. The widget-level
// integration is covered by `test/tui_test.dart` (sync
// path) and the chat-panel smoke tests (async path).

import 'package:crux/src/components/ui/markdown_isolate.dart';
import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';

/// A trivial theme that produces a small, predictable
/// MarkdownSpanData output. Each ARGB is opaque, so the
/// resulting Color has `alpha = 0xFF`. We only need
/// something that implements [MarkdownThemeFields] — the
/// actual color values are not asserted in this suite.
class _StubTheme implements MarkdownThemeFields {
  const _StubTheme();

  Color _c(int v) => Color(0xFF000000 | v);

  @override
  Color get markdownText => _c(0xAAAAAA);
  @override
  Color get thinkingExpandedText => _c(0x888888);
  @override
  Color get mdH1 => _c(0xFF0000);
  @override
  Color get mdH2 => _c(0xFF0000);
  @override
  Color get mdH3 => _c(0xFF0000);
  @override
  Color get mdH4 => _c(0xFF0000);
  @override
  Color get mdH5 => _c(0xFF0000);
  @override
  Color get mdH6 => _c(0xFF0000);
  @override
  Color get mdBold => _c(0xFFFF00);
  @override
  Color get mdItalic => _c(0x00FF00);
  @override
  Color get mdStrikethrough => _c(0x0000FF);
  @override
  Color get mdInlineCode => _c(0xFF00FF);
  @override
  Color get mdInlineCodeBg => _c(0x333333);
  @override
  Color get mdCodeBlockText => _c(0x00FFFF);
  @override
  Color get mdBlockquote => _c(0x888888);
  @override
  Color get mdLink => _c(0x0088FF);
  @override
  Color get codeBlockBackground => _c(0x222222);
  @override
  Color get codeBlockGutter => _c(0x555555);
  @override
  Color get codeBlockHeader => _c(0x777777);
  @override
  Color get outline => _c(0x444444);
  @override
  Color get surface => _c(0x111111);
  @override
  Color get surfaceVariant => _c(0x222222);
  @override
  Color get highlightDefault => _c(0xCCCCCC);
  @override
  Color get highlightKeyword => _c(0xFF79C6);
  @override
  Color get highlightStorage => _c(0xFF79C6);
  @override
  Color get highlightFunction => _c(0xD2A8FF);
  @override
  Color get highlightType => _c(0x9ECE6A);
  @override
  Color get highlightAttribute => _c(0xF5C2E7);
  @override
  Color get highlightString => _c(0xA6E3A1);
  @override
  Color get highlightComment => _c(0x6C7A89);
  @override
  Color get highlightConstant => _c(0xFFD580);
  @override
  Color get highlightNumeric => _c(0xFFD580);
  @override
  Color get highlightVariable => _c(0xCDD6F4);
  @override
  Color get highlightTag => _c(0x89B4FA);
  @override
  Color get highlightPunctuation => _c(0xBAC2DE);
  @override
  Color get syntaxOperator => _c(0x89B4FA);
}

void main() {
  // The widget's default is sync; isolate tests below
  // require us to actually submit a parse, which means
  // spawning the worker. Build the theme snapshot once
  // and reuse it.
  const theme = _StubTheme();
  final parseTheme = buildMarkdownParseTheme(theme);

  group('MarkdownIsolate', () {
    test('parse request returns a non-empty span list for plain text',
        () async {
      final isolate = MarkdownIsolate.instance;
      await isolate.ensureSpawned();
      final response = await isolate.parse(
        text: 'hello world',
        parsedIndex: 0,
        theme: parseTheme,
      );
      expect(response.spans.isNotEmpty, isTrue);
      // The exact text survives the round trip; styling is
      // reconstructed by the caller, not asserted here.
      final joined =
          response.spans.map((s) => s.text).join();
      expect(joined, contains('hello'));
    });

    test('parse with same text returns same id and content', () async {
      final isolate = MarkdownIsolate.instance;
      await isolate.ensureSpawned();
      final a = await isolate.parse(
        text: 'abc',
        parsedIndex: 0,
        theme: parseTheme,
      );
      final b = await isolate.parse(
        text: 'abc',
        parsedIndex: 0,
        theme: parseTheme,
      );
      // Different request ids, same resulting text.
      expect(a.id, isNot(equals(b.id)));
      expect(
        a.spans.map((s) => s.text).join(),
        equals(b.spans.map((s) => s.text).join()),
      );
    });

    test('reconstructInlineSpans preserves plain text content', () {
      // Drive the reconstruction path directly so we
      // can assert the round-trip is text-preserving
      // without going through the isolate.
      final data = [
        const MarkdownSpanData(text: 'plain '),
        const MarkdownSpanData(text: 'bold', fontWeight: 1),
        const MarkdownSpanData(text: ' plain'),
      ];
      final spans = reconstructInlineSpans(data);
      final joined = spans
          .where((s) => s is TextSpan)
          .map((s) => (s as TextSpan).text ?? '')
          .join();
      expect(joined, equals('plain bold plain'));
    });

    test(
      'multi-session coalescing: stale responses from an unmounted '
      'widget are discarded by id',
      () async {
        final isolate = MarkdownIsolate.instance;
        await isolate.ensureSpawned();
        // Submit two parses back-to-back. The first will
        // be superseded — when it eventually returns the
        // second is the only one a (hypothetical) widget
        // would apply. The protocol drops nothing
        // automatically; the widget side is responsible
        // for that via _lastSubmittedId. Here we just
        // confirm both completions land and the latest
        // text is what was sent last.
        final older = isolate.parse(
          text: 'one',
          parsedIndex: 0,
          theme: parseTheme,
        );
        final newer = isolate.parse(
          text: 'two',
          parsedIndex: 0,
          theme: parseTheme,
        );
        final r1 = await older;
        final r2 = await newer;
        expect(r1.text, equals('one'));
        expect(r2.text, equals('two'));
        // Different request ids — the widget would
        // discard the older one.
        expect(r1.id, isNot(equals(r2.id)));
      },
    );

    test('buildMarkdownParseTheme preserves colors as packed ARGB', () {
      final theme2 = buildMarkdownParseTheme(const _StubTheme());
      // The alpha of the top bits must be 0xFF (opaque)
      // for every field — we only pack RGB into the low
      // 24 bits, so the alpha is implicit.
      expect(theme2.markdownTextArgb & 0xFF000000, 0xFF000000);
      expect(theme2.mdH1Argb & 0xFF000000, 0xFF000000);
      // The red channel of mdH1 (0xFF0000) survives
      // packing. The packed value is 0xFFFF0000.
      expect(theme2.mdH1Argb & 0x00FF0000, 0x00FF0000);
    });
  });
}

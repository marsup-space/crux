import 'package:crux/src/utils/quick_reply_parser.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:test/test.dart';

/// Builds a flat span list from raw text + style segments — exactly
/// the shape `parseMarkdownToInlineSpans` produces for the main-isolate
/// path. Lets tests construct spans without going through the markdown
/// parser.
List<InlineSpan> _spansFromSegments(List<(String, TextStyle?)> segments) {
  return segments
      .where((s) => s.$1.isNotEmpty)
      .map((s) => TextSpan(text: s.$1, style: s.$2))
      .toList();
}

void main() {
  group('parseQuickReplies — basic matching (explicit form)', () {
    test('finds a single explicit-form token', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('try ask://Continue{yes, please continue} now', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Continue');
      expect(refs.first.answer, 'yes, please continue');
      expect(refs.first.sourceStart, 4);
      // Source length covers the full `ask://Continue{yes, please continue}`.
      expect(refs.first.sourceLength, 'ask://Continue{yes, please continue}'.length);
    });

    test('trims whitespace inside label and answer', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://  Spaced label  {  spaced answer  }', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Spaced label');
      expect(refs.first.answer, 'spaced answer');
    });

    test('finds multiple tokens in one span', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://A{a} or ask://B{b}', style),
      ]));
      expect(refs, hasLength(2));
      expect(refs[0].label, 'A');
      expect(refs[0].answer, 'a');
      expect(refs[1].label, 'B');
      expect(refs[1].answer, 'b');
    });

    test('offsets respect the running position across multiple spans', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('first ask://A{a}', style),
        (' then ask://B{b} end', style),
      ]));
      expect(refs, hasLength(2));
      // `first ask://A{a}` is 16 chars; `ask://A{a}` starts at 6.
      expect(refs[0].sourceStart, 6);
      expect(refs[0].label, 'A');
      // Span 2 starts at absolute offset 16; `ask://B{b}` sits 6 chars
      // into it (after " then ").
      expect(refs[1].sourceStart, 22);
      expect(refs[1].label, 'B');
    });

    test('allows punctuation and special chars in answer', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Run{`npm install foo@1.2.3`}', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Run');
      expect(refs.first.answer, '`npm install foo@1.2.3`');
    });

    test('first } terminates the answer (no nesting)', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // The closing brace is the FIRST `}`, so `}`-inside-answer is
      // not supported — this is by design (see docs §"Reserved
      // characters"). Anything after the first `}` is dropped.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Bad{a} rest', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.answer, 'a');
      // Source length covers only `ask://Bad{a}`, not the trailing
      // ' rest' — that's deliberate: the matched token's end is the
      // first `}`.
      expect(refs.first.sourceLength, 'ask://Bad{a}'.length);
    });

    test('does not match across newlines (multi-line answer is invalid)', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // `{` is opened but `}` is on a different line. Regex requires
      // `}` on same line so this fails the explicit form. Falls
      // through to shorthand which terminates at `\n`. Either way,
      // there's no well-formed token here.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Bad{a\nb}', style),
      ]));
      expect(refs, isEmpty);
    });

    test('returns no tokens when there are no matches', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('plain text, no quick replies here', style),
      ]));
      expect(refs, isEmpty);
    });

    test('returns no tokens for near-misses', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // Each malformed form MUST be rejected:
      //   ask:/A        — single slash, regex wants ask://
      //   ask::/B{c}    — `::` after `ask`
      //   ask-://C{d}   — hyphen instead of second slash
      //   ask://        — empty label
      //   ask://{e}     — empty label (explicit form too)
      //   ask://F       — followed by `}` on same line — wait, no,
      //     shorthand `ask://F` followed by `{...}` would parse
      //     `F` as shorthand label, then `{...}` would be orphan
      //     text. Let's instead test `ask:// ` (just whitespace
      //     after) which trims to empty and is dropped.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask:/A ask::/B ask-://C ask:// ask://{e} ask:// ', style),
      ]));
      expect(refs, isEmpty);
    });
  });

  group('parseQuickReplies — shorthand form', () {
    test('shorthand sets answer = label', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('choose ask://Yes ask://No', style),
      ]));
      expect(refs, hasLength(2));
      expect(refs[0].label, 'Yes');
      expect(refs[0].answer, 'Yes');
      expect(refs[1].label, 'No');
      expect(refs[1].answer, 'No');
    });

    test('shorthand label can span multiple words until end of input', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // Whitespace is NOT a shorthand boundary — multi-word labels
      // are valid. `ask://Use cache` (no second `ask://` to stop at)
      // runs all the way to end-of-input.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Use cache', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Use cache');
      expect(refs.first.answer, 'Use cache');
    });

    test('shorthand label terminates at next ask:// token', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Use cache ask://Disable', style),
      ]));
      expect(refs, hasLength(2));
      expect(refs[0].label, 'Use cache');
      expect(refs[1].label, 'Disable');
    });

    test('shorthand label terminates at end of line', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Continue\nNext line', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Continue');
      expect(refs.first.sourceLength, 'ask://Continue'.length);
    });

    test('shorthand label terminates at end of input', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Final', style),
      ]));
      expect(refs, hasLength(1));
      expect(refs.first.label, 'Final');
      expect(refs.first.answer, 'Final');
    });

    // Regression: the shorthand regex used to capture the trailing
    // space between two adjacent `ask://` tokens as part of the
    // first token's source range. The display label was correctly
    // trimmed to "Yes", but `sourceLength` still included the space
    // — so the renderer (which uses `sourceLength` to decide what
    // to delete from the source) ate the separator and produced
    // "YesNo" with no visible gap between the two buttons. The
    // fix trims the source range to match the trimmed label, so
    // the renderer keeps the space as ordinary "before text" for
    // the next token. The label itself is unchanged.
    test('shorthand source range excludes the separator before next token', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://Yes ask://No', style),
      ]));
      expect(refs, hasLength(2));
      // First token's range covers "ask://Yes" only — the trailing
      // space stays outside so the renderer preserves it.
      expect(refs[0].sourceStart, 0);
      expect(refs[0].sourceLength, 'ask://Yes'.length);
      expect(refs[0].label, 'Yes');
      // Second token's range is the normal "ask://No".
      expect(refs[1].sourceStart, 'ask://Yes '.length);
      expect(refs[1].sourceLength, 'ask://No'.length);
      expect(refs[1].label, 'No');
    });
  });

  group('parseQuickReplies — mixed forms', () {
    test('explicit and shorthand tokens on separate lines', () {
      // The realistic agent pattern: one option per line, mixing
      // explicit `{answer}` and shorthand forms freely. Each line
      // terminates independently (boundary = `\n`), so the regex
      // matches each cleanly.
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('请选择:\nask://A{do A}\nask://B\nask://Continue{yes}', style),
      ]));
      expect(refs, hasLength(3));
      expect(refs[0].label, 'A');
      expect(refs[0].answer, 'do A');
      expect(refs[1].label, 'B');
      expect(refs[1].answer, 'B');
      expect(refs[2].label, 'Continue');
      expect(refs[2].answer, 'yes');
    });

    test('explicit and shorthand tokens with `{...}` on each', () {
      // All-explicit inline form: each `ask://X{Y}` is unambiguous
      // because the regex matches each token's `{...}` exactly.
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://A{do A} ask://B{B} ask://Continue{yes}', style),
      ]));
      expect(refs, hasLength(3));
      expect(refs[0].label, 'A');
      expect(refs[0].answer, 'do A');
      expect(refs[1].label, 'B');
      expect(refs[1].answer, 'B');
      expect(refs[2].label, 'Continue');
      expect(refs[2].answer, 'yes');
    });
  });

  group('parseQuickReplies — code-span exclusion', () {
    test('skips tokens inside inline code spans', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // "see `ask://A{a}` and ask://B{b}"
      final refs = parseQuickReplies([
        const TextSpan(text: 'see ', style: text),
        const TextSpan(text: 'ask://A{a}', style: code),
        const TextSpan(text: ' and ask://B{b}', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'B');
      expect(refs.first.answer, 'b');
    });

    test('skips tokens inside fenced code blocks', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const codeBlock = TextStyle(
        color: Color(0xFFCCCCCC),
        backgroundColor: Color(0xFF000000),
      );
      // "above\nask://A{a}\nbelow" with middle line code-block styled.
      final refs = parseQuickReplies([
        const TextSpan(text: 'above\n', style: text),
        const TextSpan(text: 'ask://A{a}', style: codeBlock),
        const TextSpan(text: '\nbelow', style: text),
      ]);
      expect(refs, isEmpty);
    });

    test('detects code span from inherited parent style', () {
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      final refs = parseQuickReplies([
        TextSpan(
          style: code,
          children: const [
            TextSpan(text: 'prefix '),
            TextSpan(text: 'ask://A{a}'),
            TextSpan(text: ' suffix'),
          ],
        ),
      ]);
      expect(refs, isEmpty);
    });
  });

  // Regression for the bug observed in ses://1508 / message 63862:
  // the agent wrote `ask://A: 在 ~/.zshrc 加 CRUX_THIRD_PARTY_BIN{在
  // ~/.zshrc 加 \`export CRUX_THIRD_PARTY_BIN=...\`,最干净}` — the
  // backticks inside the answer caused the markdown parser to split
  // the token across multiple InlineSpans, and the old per-span
  // regex pass failed to match. The new flatten-then-regex pass
  // handles these correctly.
  group('parseQuickReplies — token crosses inline code boundary', () {
    test('explicit token with backticks in the middle of the answer', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // Markdown source would be: ask://A{run `npm install`}
      // → three spans: regular, code (backticks), regular
      final refs = parseQuickReplies([
        const TextSpan(text: 'ask://A{run ', style: text),
        const TextSpan(text: '`npm install`', style: code),
        const TextSpan(text: '}', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'A');
      expect(refs.first.answer, 'run `npm install`');
      // The whole source `ask://A{run \`npm install\`}` is 25 chars
      // and starts at offset 0 of the flat text.
      expect(refs.first.sourceStart, 0);
      expect(
        refs.first.sourceLength,
        'ask://A{run `npm install`}'.length,
      );
    });

    test('explicit token with backticks at the start of the answer', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // Source: ask://B{`cmd` is the way}
      final refs = parseQuickReplies([
        const TextSpan(text: 'ask://B{', style: text),
        const TextSpan(text: '`cmd`', style: code),
        const TextSpan(text: ' is the way}', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'B');
      expect(refs.first.answer, '`cmd` is the way');
    });

    test('explicit token with backticks at the end of the answer', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // Source: ask://C{see `tail`}
      final refs = parseQuickReplies([
        const TextSpan(text: 'ask://C{see ', style: text),
        const TextSpan(text: '`tail`', style: code),
        const TextSpan(text: '}', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'C');
      expect(refs.first.answer, 'see `tail`');
    });

    test('multiple tokens: one crosses code, one is plain', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      // Source: ask://A{a} then ask://B{run `cmd`}
      final refs = parseQuickReplies([
        const TextSpan(text: 'ask://A{a} then ', style: text),
        const TextSpan(text: 'ask://B{run ', style: text),
        const TextSpan(text: '`cmd`', style: code),
        const TextSpan(text: '}', style: text),
      ]);
      expect(refs, hasLength(2));
      expect(refs[0].label, 'A');
      expect(refs[0].answer, 'a');
      expect(refs[0].sourceStart, 0);
      expect(refs[1].label, 'B');
      expect(refs[1].answer, 'run `cmd`');
      // "ask://A{a} then " is 16 chars → B starts at offset 16.
      expect(refs[1].sourceStart, 16);
    });

    test('token entirely inside code is still dropped', () {
      // Negative case: even with the new flatten approach, tokens
      // whose START position is inside a code region must be
      // rejected (agent's own prompt doc).
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );
      final refs = parseQuickReplies([
        const TextSpan(text: 'see ', style: text),
        const TextSpan(text: 'ask://A{a}', style: code),
        const TextSpan(text: ' and ask://B{b}', style: text),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'B');
    });

    test('reproduces the ses://1508 / message 63862 case', () {
      // Real-world failing case from the agent's reply about
      // CRUX_THIRD_PARTY_BIN: four tokens whose answers each
      // contain a backticked shell command. The old parser
      // returned ZERO matches for these; the new parser returns
      // all four with intact answers.
      const text = TextStyle(color: Color(0xFFFFFFFF));
      const code = TextStyle(
        color: Color(0xFF00FF00),
        backgroundColor: Color(0xFF333333),
      );

      // We build the four token source lines in spans so the
      // backticked commands end up as code-styled sub-spans —
      // mirroring what `parseMarkdownToInlineSpans` would produce.
      //
      // ask://A: 在 ~/.zshrc 加 CRUX_THIRD_PARTY_BIN{在 ~/.zshrc 加 `export CRUX_THIRD_PARTY_BIN=...`,最干净}
      // ask://B: 软链到 ~/.crux/bin/third_party/bin/{`ln -sf ...`,跟着 install 走}
      // ask://C: 把 venv bin 加进 PATH{`export PATH=...:$PATH` 加到 ~/.zshrc,全局生效}
      // ask://release.sh 加个检查{在 release.sh 里加一段:装完检查 `semble` 是否可达,缺了给提示并问怎么处理}

      final spans = <InlineSpan>[
        const TextSpan(text: 'ask://A: 在 ~/.zshrc 加 CRUX_THIRD_PARTY_BIN{在 ~/.zshrc 加 ', style: text),
        const TextSpan(text: '`export CRUX_THIRD_PARTY_BIN=/Users/developer/Projects/crux/.research/.venv-semble/bin`', style: code),
        const TextSpan(text: ',最干净}\n', style: text),
        const TextSpan(text: 'ask://B: 软链到 ~/.crux/bin/third_party/bin/{', style: text),
        const TextSpan(text: '`ln -sf .../venv-semble/bin/semble ~/.crux/bin/third_party/bin/semble`', style: code),
        const TextSpan(text: ',跟着 install 走}\n', style: text),
        const TextSpan(text: 'ask://C: 把 venv bin 加进 PATH{', style: text),
        const TextSpan(text: '`export PATH=...:\$PATH`', style: code),
        const TextSpan(text: ' 加到 ~/.zshrc,全局生效}\n', style: text),
        const TextSpan(text: 'ask://release.sh 加个检查{在 release.sh 里加一段:装完检查 ', style: text),
        const TextSpan(text: '`semble`', style: code),
        const TextSpan(text: ' 是否可达,缺了给提示并问怎么处理}', style: text),
      ];

      final refs = parseQuickReplies(spans);
      expect(refs, hasLength(4));

      expect(refs[0].label, 'A: 在 ~/.zshrc 加 CRUX_THIRD_PARTY_BIN');
      expect(refs[0].answer,
          '在 ~/.zshrc 加 `export CRUX_THIRD_PARTY_BIN=/Users/developer/Projects/crux/.research/.venv-semble/bin`,最干净');

      expect(refs[1].label, 'B: 软链到 ~/.crux/bin/third_party/bin/');
      expect(refs[1].answer,
          '`ln -sf .../venv-semble/bin/semble ~/.crux/bin/third_party/bin/semble`,跟着 install 走');

      expect(refs[2].label, 'C: 把 venv bin 加进 PATH');
      expect(refs[2].answer,
          '`export PATH=...:\$PATH` 加到 ~/.zshrc,全局生效');

      expect(refs[3].label, 'release.sh 加个检查');
      expect(refs[3].answer,
          '在 release.sh 里加一段:装完检查 `semble` 是否可达,缺了给提示并问怎么处理');
    });
  });

  group('parseQuickReplies — span tree shapes', () {
    test('handles parent + children on the same TextSpan', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      // TextSpan with both `text` and `children` — the offset counter
      // must increment past the parent text before walking into
      // children.
      final refs = parseQuickReplies([
        const TextSpan(text: 'a ', style: text, children: [
          TextSpan(text: 'b ask://A{a} c', style: text),
        ]),
      ]);
      expect(refs, hasLength(1));
      expect(refs.first.label, 'A');
      // 'a ' (2 chars) + 'b ' (2 chars) = offset 4.
      expect(refs.first.sourceStart, 4);
    });

    test('non-TextSpan entries are skipped silently', () {
      const text = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(const [
        TextSpan(text: 'ask://A{a} ', style: text),
      ]);
      expect(refs, hasLength(1));
    });
  });

  group('parseQuickReplies — validation', () {
    test('drops tokens with empty label after trim', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // Explicit form: `ask://{a}` — label trims to empty.
      // Shorthand: `ask://  ` — label trims to empty.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://{a} ask://  ', style),
      ]));
      expect(refs, isEmpty);
    });

    test('drops tokens with empty answer (explicit form)', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      // `ask://A{}` — explicit form, empty answer.
      final refs = parseQuickReplies(_spansFromSegments([
        ('ask://A{}', style),
      ]));
      expect(refs, isEmpty);
    });

    test('containsIndex is correct', () {
      const style = TextStyle(color: Color(0xFFFFFFFF));
      final refs = parseQuickReplies(_spansFromSegments([
        ('hi ask://A{a} bye', style),
      ]));
      expect(refs, hasLength(1));
      final r = refs.first;
      expect(r.sourceStart, 3);
      expect(r.sourceEnd, 3 + 'ask://A{a}'.length);
      expect(r.containsIndex(3), isTrue);     // start
      expect(r.containsIndex(3 + 'ask://A{a}'.length - 1), isTrue); // last
      expect(r.containsIndex(2), isFalse);    // before
      expect(r.containsIndex(3 + 'ask://A{a}'.length), isFalse); // after
    });
  });

  group('applyQuickReplyTokens — overlay', () {
    const base = TextStyle(color: Color(0xFFFFFFFF));
    const button = TextStyle(
      color: Color(0xFF000000),
      backgroundColor: Color(0xFF88CCFF),
      fontWeight: FontWeight.bold,
    );
    const hover = TextStyle(
      color: Color(0xFFFFFFFF),
      backgroundColor: Color(0xFFFF8800),
      fontWeight: FontWeight.bold,
      decoration: TextDecoration.underline,
    );

    /// Walks the resulting InlineSpan tree and concatenates every
    /// leaf text segment. Used to assert what the rendered output
    /// WOULD display (ignoring styling).
    String plainText(List<InlineSpan> spans) {
      final buf = StringBuffer();
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null) buf.write(s.text);
          if (s.children != null) {
            for (final c in s.children!) {
              walk(c);
            }
          }
        }
      }
      for (final s in spans) {
        walk(s);
      }
      return buf.toString();
    }

    /// Finds the first leaf span whose text equals [text].
    InlineSpan? findSpan(List<InlineSpan> spans, String text) {
      InlineSpan? found;
      void walk(InlineSpan s) {
        if (found != null) return;
        if (s is TextSpan) {
          if (s.text == text) {
            found = s;
            return;
          }
          if (s.children != null) {
            for (final c in s.children!) {
              walk(c);
            }
          }
        }
      }

      for (final s in spans) {
        walk(s);
      }
      return found;
    }

    test('returns the original spans when there are no replies', () {
      final spans = _spansFromSegments([('plain text', base)]);
      final styled = applyQuickReplyTokens(spans, const [], buttonStyle: button);
      expect(styled, equals(spans));
    });

    test('substitutes source text with label in button mode', () {
      // Source: `try ask://Continue{yes} now`
      // After:  `try Continue now` (label only, never the raw source)
      final spans = _spansFromSegments([
        ('try ask://Continue{yes} now', base),
      ]);
      final replies = parseQuickReplies(spans);
      expect(replies, hasLength(1));

      final styled = applyQuickReplyTokens(
        spans,
        replies,
        buttonStyle: button,
      );

      // Raw source text must NOT appear anywhere in the rendered
      // output — neither as visible text nor as part of a label.
      expect(plainText(styled), 'try Continue now');
      expect(findSpan(styled, 'ask://Continue{yes}'), isNull);

      // The label is rendered with the button style overlaid on the
      // surrounding baseStyle.
      final labelSpan = findSpan(styled, 'Continue');
      expect(labelSpan, isNotNull);
      expect(labelSpan!.style!.backgroundColor, button.backgroundColor);
      expect(labelSpan.style!.fontWeight, button.fontWeight);
    });

    test('substitutes source text with label in label-only mode (stale)', () {
      // Same input, but buttonStyle is null — stale-turn rendering.
      // The label is emitted with the surrounding baseStyle
      // unchanged, so the output is indistinguishable from ordinary
      // prose.
      final spans = _spansFromSegments([
        ('try ask://Continue{yes} now', base),
      ]);
      final replies = parseQuickReplies(spans);
      final styled = applyQuickReplyTokens(spans, replies);

      expect(plainText(styled), 'try Continue now');

      final labelSpan = findSpan(styled, 'Continue');
      expect(labelSpan, isNotNull);
      // Stale-mode label inherits baseStyle — no button bg, no bold.
      expect(labelSpan!.style!.backgroundColor, isNull);
      expect(labelSpan.style!.fontWeight, isNull);
    });

    test('multi-word label substitution preserves surrounding text', () {
      // Use the explicit form so the label is bounded by `{…}` rather
      // than running to end-of-line. (Shorthand `ask://Use cache`
      // alone would label everything from "Use" to end-of-input.)
      final spans = _spansFromSegments([
        ('I recommend ask://Use cache{today} friend', base),
      ]);
      final replies = parseQuickReplies(spans);
      expect(replies.first.label, 'Use cache');
      expect(replies.first.answer, 'today');

      final styled = applyQuickReplyTokens(spans, replies);

      expect(plainText(styled), 'I recommend Use cache friend');
      final labelSpan = findSpan(styled, 'Use cache');
      expect(labelSpan, isNotNull);
    });

    test('substitutes multiple tokens in order', () {
      final spans = _spansFromSegments([
        ('pick ask://A{a} or ask://B{b}', base),
      ]);
      final replies = parseQuickReplies(spans);
      expect(replies, hasLength(2));

      final styled = applyQuickReplyTokens(spans, replies);

      expect(plainText(styled), 'pick A or B');
      expect(findSpan(styled, 'A'), isNotNull);
      expect(findSpan(styled, 'B'), isNotNull);
    });

    test('hovered reply uses hoverStyle instead of buttonStyle', () {
      final spans = _spansFromSegments([
        ('a ask://X{x} b ask://Y{y} c', base),
      ]);
      final replies = parseQuickReplies(spans);

      final styled = applyQuickReplyTokens(
        spans,
        replies,
        buttonStyle: button,
        hoverStyle: hover,
        hoveredReply: replies[0],
      );

      final hovered = findSpan(styled, 'X');
      expect(hovered, isNotNull);
      expect(hovered!.style!.backgroundColor, hover.backgroundColor);
      expect(hovered.style!.decoration, hover.decoration);

      final plain = findSpan(styled, 'Y');
      expect(plain, isNotNull);
      expect(plain!.style!.backgroundColor, button.backgroundColor);
    });

    test('null hoverStyle falls back to buttonStyle for the hovered reply', () {
      final spans = _spansFromSegments([
        ('ask://X{x}', base),
      ]);
      final replies = parseQuickReplies(spans);
      final styled = applyQuickReplyTokens(
        spans,
        replies,
        buttonStyle: button,
        hoveredReply: replies.first,
      );

      final span = findSpan(styled, 'X');
      expect(span, isNotNull);
      expect(span!.style!.backgroundColor, button.backgroundColor);
    });

    test('adjacent text inherits baseStyle (not buttonStyle) in button mode', () {
      final spans = _spansFromSegments([
        ('before ask://X{x} after', base),
      ]);
      final replies = parseQuickReplies(spans);
      final styled = applyQuickReplyTokens(
        spans,
        replies,
        buttonStyle: button,
      );

      final before = findSpan(styled, 'before ');
      expect(before, isNotNull);
      expect(before!.style!.backgroundColor, isNull);

      final after = findSpan(styled, ' after');
      expect(after, isNotNull);
      expect(after!.style!.backgroundColor, isNull);

      final label = findSpan(styled, 'X');
      expect(label, isNotNull);
      expect(label!.style!.backgroundColor, button.backgroundColor);
    });

    group('rendered offsets for hit-testing', () {
      test('records renderedStart and renderedLength on each reply', () {
        // Source: `try ask://Continue{yes} now`
        // Rendered: `try Continue now` (length 16)
        // Position of 'C' in rendered text = 4 (start of "Continue")
        final spans = _spansFromSegments([
          ('try ask://Continue{yes} now', base),
        ]);
        final replies = parseQuickReplies(spans);
        applyQuickReplyTokens(spans, replies, buttonStyle: button);

        expect(replies, hasLength(1));
        final r = replies.first;
        expect(r.renderedStart, 4);
        expect(r.renderedLength, 'Continue'.length);
      });

      test('containsRenderedIndex works for substituted text', () {
        final spans = _spansFromSegments([
          ('hi ask://A{a} bye', base),
        ]);
        final replies = parseQuickReplies(spans);
        applyQuickReplyTokens(spans, replies, buttonStyle: button);

        final r = replies.first;
        // After substitution, "A" sits at position 3 (after "hi "),
        // length 1.
        expect(r.renderedStart, 3);
        expect(r.renderedLength, 1);
        expect(r.containsRenderedIndex(3), isTrue);
        expect(r.containsRenderedIndex(4), isFalse); // past end
        expect(r.containsRenderedIndex(2), isFalse); // before

        // The SOURCE position is no longer relevant for hit-testing
        // after substitution — but it's preserved on the reply for
        // debugging / telemetry. containsIndex against source still
        // works as before (uses sourceStart/sourceEnd).
        expect(r.containsIndex(3 + 'ask://A{a}'.length ~/ 2), isTrue);
      });

      test('tracks cumulative position across multiple replies', () {
        // Source: `ask://A{a} ask://B{b}` (positions 0..10, 11..21)
        // Rendered: `A B` (length 3)
        // Position of 'A' = 0, position of 'B' = 2.
        final spans = _spansFromSegments([
          ('ask://A{a} ask://B{b}', base),
        ]);
        final replies = parseQuickReplies(spans);
        applyQuickReplyTokens(spans, replies);

        expect(replies, hasLength(2));
        expect(replies[0].renderedStart, 0);
        expect(replies[0].renderedLength, 1);
        expect(replies[1].renderedStart, 2);
        expect(replies[1].renderedLength, 1);
      });

      test('null renderedStart (parser-only, no renderer pass) disables hit-test', () {
        // QuickReply created by parser but never fed to the
        // renderer — renderedStart is null, containsRenderedIndex
        // returns false.
        final spans = _spansFromSegments([
          ('ask://A{a}', base),
        ]);
        final replies = parseQuickReplies(spans);
        expect(replies.first.renderedStart, isNull);
        expect(replies.first.containsRenderedIndex(0), isFalse);
      });
    });
  });
}

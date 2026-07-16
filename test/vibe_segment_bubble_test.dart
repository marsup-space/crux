// Regression tests for two rendering bugs in vibe-mode consolidated
// segments.
//
// Bug 1 — think box effort label was rendering the raw internal
// value (e.g. `normal`) instead of the provider's display label
// (e.g. `adaptive` for MiniMax). The streaming bubble next to it
// already mapped through `reasoningPresets`, so the live and
// consolidated bubbles showed the same effort two different ways.
// `VibeSegmentBubble` now accepts a `reasoningPresets` argument
// and applies the same internal→display mapping as the streaming
// bubble and the verbose `MessageBubble`.
//
// Bug 2 — the user bubble was a flat `Text(' you: $userText')`,
// so long user messages soft-wrapped flush-left under the bubble
// and the lowercase `you:` prefix didn't match the verbose
// `MessageBubble`'s `' You: '` styling. The bubble now uses the
// same `Row` + `Text(' You: ')` + `Expanded(Text(content))`
// pattern as the verbose bubble, so soft-wrap alignment is
// preserved and the prefix matches verbose mode exactly.
//
// The tests below pin both: the column positions of `You:` /
// `Crux:` and the first character of user / crux text, plus the
// think-box display label mapping.

import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/components/vibe_segment_bubble.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

Message _userMsg(String content, {int id = 1}) => Message(
      id: id,
      sessionId: 1,
      role: 'user',
      content: content,
    );

Message _aiMsg(String content, {int id = 2}) => Message(
      id: id,
      sessionId: 1,
      role: 'ai',
      content: content,
    );

VibeSegment _segmentWithThink({
  String userContent = 'do something',
  String? effort,
  String aiContent = 'Done.',
}) {
  return VibeSegment(
    userMessage: _userMsg(userContent, id: 1),
    think: ThinkBoxData(
      duration: const Duration(milliseconds: 8200),
      tokens: 1234,
      effort: effort,
    ),
    prose: _aiMsg(aiContent, id: 2),
  );
}

VibeSegment _segmentWithoutThink({
  String userContent = 'do something',
  String aiContent = 'Done.',
}) {
  return VibeSegment(
    userMessage: _userMsg(userContent, id: 1),
    prose: _aiMsg(aiContent, id: 2),
  );
}

void main() {
  group('VibeSegmentBubble think box effort label', () {
    test(
        'maps internal effort through reasoningPresets '
        '(`normal` → `adaptive` for MiniMax)', () async {
      await testNocterm('think box maps effort', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 80,
              height: 8,
              child: VibeSegmentBubble(
                segment: _segmentWithThink(effort: 'normal'),
                reasoningPresets: const [
                  ReasoningPreset(
                    internalValue: 'normal',
                    displayLabel: 'adaptive',
                  ),
                ],
              ),
            ),
          ),
        );
        // The display label `adaptive` must appear inside the
        // think box; the raw internal value `normal` must NOT
        // appear there. Before the fix, `normal` was rendered
        // as-is and the streaming bubble showed `adaptive` for
        // the same effort — two different labels for the same
        // round in the same view.
        expect(tester.terminalState.findText('adaptive'), isNotEmpty);
        expect(tester.terminalState.findText('normal'), isEmpty);
      });
    });

    test('falls back to raw internal value when no preset matches',
        () async {
      await testNocterm('think box falls back', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 80,
              height: 8,
              child: VibeSegmentBubble(
                segment: _segmentWithThink(effort: 'high'),
                // Preset list that does not include `high` →
                // bubble falls back to the raw internal value.
                reasoningPresets: const [
                  ReasoningPreset(
                    internalValue: 'normal',
                    displayLabel: 'adaptive',
                  ),
                ],
              ),
            ),
          ),
        );
        expect(tester.terminalState.findText('high'), isNotEmpty);
      });
    });

    test('falls back to raw value when reasoningPresets is empty',
        () async {
      // No presets at all — this is what callers get for models
      // that don't override the display mapping. The bubble
      // should show the raw internal value (`normal`) verbatim
      // rather than skipping the row entirely.
      await testNocterm('think box empty presets', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 80,
              height: 8,
              child: VibeSegmentBubble(
                segment: _segmentWithThink(effort: 'normal'),
                reasoningPresets: const [],
              ),
            ),
          ),
        );
        expect(tester.terminalState.findText('normal'), isNotEmpty);
      });
    });
  });

  group('VibeSegmentBubble user bubble indentation', () {
    test('user prefix is uppercase `You:` matching verbose mode',
        () async {
      // The lowercase `you:` was a vibe-mode leftover; the
      // verbose `MessageBubble` and `Crux:` itself both render
      // `You:` (uppercase Y). Without this normalization the
      // same role rendered two different labels in the two
      // display modes.
      await testNocterm('user prefix is uppercase You:', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 80,
              height: 8,
              child: VibeSegmentBubble(
                segment: _segmentWithoutThink(
                  userContent: 'hello',
                  aiContent: 'world',
                ),
              ),
            ),
          ),
        );
        expect(tester.terminalState.findText('You:'), isNotEmpty,
            reason: 'vibe mode user prefix must be uppercase '
                '`You:` to match verbose mode');
        // The lowercase form was the old bug — make sure it
        // doesn't sneak back in.
        expect(tester.terminalState.findText('you:'), isEmpty);
      });
    });

    test('user text starts at the same column as crux text', () async {
      // Both prefixes are wrapped in `Padding(horizontal: 1)`,
      // then a `Row` puts the prefix Text at the Row's left
      // edge followed by `Expanded` for the body. The leading
      // space in `' You: '` / `' Crux: '` is part of the prefix
      // string itself, so the visible prefix labels land on
      // these columns:
      //   * `Y` (start of `You:`) is at column 2 — 1 padding
      //     cell + 1 leading-space cell inside the prefix.
      //   * `C` (start of `Crux:`) is at column 2 — same.
      // The body text starts after the trailing space in each
      // prefix, so:
      //   * User text starts at column 7 (1 padding + the
      //     6-char `' You: '` prefix).
      //   * Crux text starts at column 8 (1 padding + the
      //     7-char `' Crux: '` prefix).
      // Crux is one column to the right of user because "Crux"
      // has one more letter than "You" — that pair of columns
      // matches verbose mode exactly, so the two display modes
      // line up. The regression this test pins is the
      // structural one: before the fix, `VibeSegmentBubble` was
      // a flat `Text(' you: $userText')` with no `Row` and no
      // `Expanded`, so the user text position was an artefact
      // of string concatenation. Now it's deterministic.
      await testNocterm('user + crux column alignment', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 80,
              height: 8,
              child: VibeSegmentBubble(
                segment: _segmentWithoutThink(
                  userContent: 'hello',
                  aiContent: 'world',
                ),
              ),
            ),
          ),
        );

        // Prefix labels.
        final youLabel = tester.terminalState.findText('You:').firstOrNull;
        final cruxLabel = tester.terminalState.findText('Crux:').firstOrNull;
        expect(youLabel, isNotNull,
            reason: '`You:` label must render on the user line');
        expect(cruxLabel, isNotNull,
            reason: '`Crux:` label must render on the prose line');

        // Both prefixes start at column 2 — they line up
        // vertically, with the body text indented to match
        // verbose mode.
        expect(youLabel!.x, 2,
            reason: '`You:` prefix must start at column 2');
        expect(cruxLabel!.x, 2,
            reason: '`Crux:` prefix must start at column 2');
        // `You:` is on a different row from `Crux:` — the user
        // line is rendered first, then the prose line below.
        expect(youLabel.y, isNot(equals(cruxLabel.y)),
            reason: 'user line and crux line must be on separate rows');

        // First character of each text body. We pick unique
        // strings (`hello`, `world`) so `findText` resolves to
        // the right occurrence without ambiguity.
        final userH = tester.terminalState.findText('hello').firstOrNull;
        final cruxW = tester.terminalState.findText('world').firstOrNull;
        expect(userH, isNotNull);
        expect(cruxW, isNotNull);
        expect(userH!.x, 7,
            reason: 'user text must start at column 7 '
                '(1 padding + 6-char `You:` prefix)');
        expect(cruxW!.x, 8,
            reason: 'crux text must start at column 8 '
                '(1 padding + 7-char `Crux:` prefix)');
      });
    });

    test('long user message wraps inside Expanded (no flush-left)',
        () async {
      // The real bug the user reported: a long user message
      // overflowed the bubble width and the wrapped
      // continuation landed at column 1 (flush-left) because
      // the old `Text(' you: $userText')` had no width
      // constraint. After the fix, `Expanded(Text(content))`
      // constrains the user text width to the panel width
      // minus the prefix, so any wrapped continuation lands at
      // column 7 — the same column the first line starts on.
      //
      // We pick a message long enough to force a wrap, then
      // verify a word that ONLY appears on the wrapped
      // continuation lands at column 7. We don't pin a
      // specific wrap point because nocterm's word-wrap
      // behavior is implementation-defined — what we pin is
      // the structural rule: any wrapped continuation starts
      // at the same column as the prefix body.
      const userContent =
          'this is a long user message that must wrap across '
          'multiple lines inside the vibe bubble';

      await testNocterm('long user wraps inside Expanded', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              // Narrow enough to force the user message to
              // wrap. The Container's width here also serves
              // as the upper bound on the Expanded's width
              // once VibeSegmentBubble lays out its child.
              width: 30,
              height: 10,
              child: VibeSegmentBubble(
                segment: _segmentWithoutThink(
                  userContent: userContent,
                  aiContent: 'ok',
                ),
              ),
            ),
          ),
        );

        // The last three words ("the vibe bubble") live on the
        // wrapped continuation line in a 30-column panel. The
        // first word of the continuation is `the`, which is
        // unique to the wrapped row in this message. Its
        // first character must land at column 7 — the same
        // column the first line's body starts on. Before the
        // fix (flat `Text(' you: $userText')`), the wrap
        // overflowed flush-left and `the` would land at
        // column 1 instead.
        final the = tester.terminalState.findText('the').firstOrNull;
        expect(the, isNotNull,
            reason: 'expected `the` to be present on the '
                'wrapped continuation line (sanity check)');
        expect(the!.x, 7,
            reason: 'wrapped continuation lines must align to '
                'column 7 — without `Expanded`, the wrap '
                'overflowed flush-left and landed at column 1');
        // And the wrapped word is on a different row from the
        // first line's body, confirming a wrap actually
        // happened (otherwise the test would be vacuous).
        final thisWord = tester.terminalState.findText('this').firstOrNull;
        expect(thisWord, isNotNull);
        expect(the.y, isNot(equals(thisWord!.y)),
            reason: '`the` must appear on a wrapped '
                'continuation line, not the first line');
      });
    });
  });
}
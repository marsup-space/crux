import 'package:crux/src/components/lsp_state_glyph.dart';
import 'package:crux/src/components/vibe_box.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/utils/tool_meta.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm.dart' as nocterm show isNotEmpty;
import 'package:test/test.dart';

void main() {
  group('LSP glyph rendering in VibeBox', () {
    test('clean state paints the ⎇ glyph in success green', () async {
      await testNocterm('lsp glyph green', (tester) async {
        final theme = CruxThemeData.draculaFallback;
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 40,
              height: 6,
              child: VibeBox(
                title: 'tools',
                bodyRowSpans: [
                  TextSpan(
                    children: [
                      const TextSpan(text: 'write x1: 120 tokens'),
                      lspStateGlyphSpan(LspState.clean, theme)!,
                    ],
                  ),
                ],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(0, 255, 255),
              ),
            ),
          ),
        );

        // The label and the glyph both render.
        expect(tester.terminalState, containsText('write x1: 120 tokens'));
        expect(tester.terminalState, containsText(kLspGlyph));
        // The glyph itself is painted in the theme's success green.
        expect(
          tester.terminalState,
          hasStyledText(kLspGlyph, TextStyle(color: theme.success)),
        );
      });
    });

    test('errors state paints the glyph in error red', () async {
      await testNocterm('lsp glyph red', (tester) async {
        final theme = CruxThemeData.draculaFallback;
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 40,
              height: 6,
              child: VibeBox(
                title: 'tools',
                bodyRowSpans: [
                  TextSpan(
                    children: [
                      const TextSpan(text: 'edit x2: 8 tokens'),
                      lspStateGlyphSpan(LspState.errors, theme)!,
                    ],
                  ),
                ],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(0, 255, 255),
              ),
            ),
          ),
        );

        expect(
          tester.terminalState,
          hasStyledText(kLspGlyph, TextStyle(color: theme.error)),
        );
      });
    });

    test('failed state paints the glyph in warning yellow', () async {
      await testNocterm('lsp glyph yellow', (tester) async {
        final theme = CruxThemeData.draculaFallback;
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 40,
              height: 6,
              child: VibeBox(
                title: 'tools',
                bodyRowSpans: [
                  TextSpan(
                    children: [
                      const TextSpan(text: 'write x1: 5 tokens'),
                      lspStateGlyphSpan(LspState.failed, theme)!,
                    ],
                  ),
                ],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(0, 255, 255),
              ),
            ),
          ),
        );

        expect(
          tester.terminalState,
          hasStyledText(kLspGlyph, TextStyle(color: theme.warning)),
        );
      });
    });

    test('none state renders no glyph at all', () async {
      await testNocterm('lsp glyph none', (tester) async {
        final theme = CruxThemeData.draculaFallback;
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 40,
              height: 6,
              child: VibeBox(
                title: 'tools',
                bodyRowSpans: [
                  TextSpan(
                    children: [
                      const TextSpan(text: 'read x1: 40 tokens'),
                      // lspStateGlyphSpan returns null for none — mimic
                      // the vibe_segment_bubble guard.
                      ?lspStateGlyphSpan(LspState.none, theme),
                    ],
                  ),
                ],
                mutedColor: const Color.fromRGB(128, 128, 128),
                activeColor: const Color.fromRGB(0, 255, 255),
              ),
            ),
          ),
        );

        expect(tester.terminalState, containsText('read x1: 40 tokens'));
        expect(tester.terminalState, isNot(containsText(kLspGlyph)));
      });
    });
  });
}

import 'package:crux/src/theme/terminal_brightness.dart';
import 'package:test/test.dart';

void main() {
  group('detectTerminalBrightness — COLORFGBG', () {
    test('missing COLORFGBG is unknown', () {
      expect(detectTerminalBrightness(const {}), TerminalBrightness.unknown);
    });

    group('dark backgrounds', () {
      for (final bg in ['0', '1', '2', '3', '4', '5', '6', '8']) {
        test('bg index $bg is dark', () {
          expect(
            detectTerminalBrightness({'COLORFGBG': '15;$bg'}),
            TerminalBrightness.dark,
          );
        });
      }

      test('common dark value 15;0 is dark', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': '15;0'}),
          TerminalBrightness.dark,
        );
      });
    });

    group('light backgrounds', () {
      for (final bg in ['7', '9', '10', '11', '12', '13', '14', '15']) {
        test('bg index $bg is light', () {
          expect(
            detectTerminalBrightness({'COLORFGBG': '0;$bg'}),
            TerminalBrightness.light,
          );
        });
      }

      test('common light value 0;15 is light', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': '0;15'}),
          TerminalBrightness.light,
        );
      });

      test('common light value 0;7 is light', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': '0;7'}),
          TerminalBrightness.light,
        );
      });
    });

    group('extended format', () {
      test('three-part value fg;bg;extra still reads the bg field', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': '15;0;256'}),
          TerminalBrightness.dark,
        );
        expect(
          detectTerminalBrightness({'COLORFGBG': '0;15;256'}),
          TerminalBrightness.light,
        );
      });

      test('whitespace around the bg field is tolerated', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': '15; 0'}),
          TerminalBrightness.dark,
        );
      });
    });

    group('malformed values', () {
      for (final value in [
        '',
        '15',
        'abc',
        '15;',
        ';',
        'x;y',
        '15;-1',
        '15;16',
        '15;999',
      ]) {
        test('COLORFGBG="$value" is unknown', () {
          expect(
            detectTerminalBrightness({'COLORFGBG': value}),
            TerminalBrightness.unknown,
          );
        });
      }

      test('empty fg with a valid bg still reads the bg field', () {
        expect(
          detectTerminalBrightness({'COLORFGBG': ';0'}),
          TerminalBrightness.dark,
        );
      });
    });
  });

  group('detectTerminalBrightness — ITERM_PROFILE fallback', () {
    test('profile containing "light" is light when COLORFGBG is absent', () {
      expect(
        detectTerminalBrightness({'ITERM_PROFILE': 'Solarized Light'}),
        TerminalBrightness.light,
      );
    });

    test('profile containing "dark" is dark when COLORFGBG is absent', () {
      expect(
        detectTerminalBrightness({'ITERM_PROFILE': 'my dark profile'}),
        TerminalBrightness.dark,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        detectTerminalBrightness({'ITERM_PROFILE': 'LIGHT'}),
        TerminalBrightness.light,
      );
    });

    test('COLORFGBG wins over ITERM_PROFILE', () {
      expect(
        detectTerminalBrightness({
          'COLORFGBG': '15;0',
          'ITERM_PROFILE': 'Solarized Light',
        }),
        TerminalBrightness.dark,
      );
    });

    test('malformed COLORFGBG falls through to ITERM_PROFILE', () {
      expect(
        detectTerminalBrightness({
          'COLORFGBG': 'garbage',
          'ITERM_PROFILE': 'light-bg',
        }),
        TerminalBrightness.light,
      );
    });

    test('unhelpful profile name is unknown', () {
      expect(
        detectTerminalBrightness({'ITERM_PROFILE': 'Default'}),
        TerminalBrightness.unknown,
      );
    });
  });

  group('defaultThemeIdForEnvironment', () {
    test('dark terminal defaults to dracula', () {
      expect(
        defaultThemeIdForEnvironment({'COLORFGBG': '15;0'}),
        kDefaultDarkThemeId,
      );
    });

    test('light terminal defaults to github', () {
      expect(
        defaultThemeIdForEnvironment({'COLORFGBG': '0;15'}),
        kDefaultLightThemeId,
      );
    });

    test('inconclusive detection falls back to dracula', () {
      expect(defaultThemeIdForEnvironment(const {}), kDefaultDarkThemeId);
      expect(
        defaultThemeIdForEnvironment({'COLORFGBG': 'bogus'}),
        kDefaultDarkThemeId,
      );
    });

    test('bundled default ids are the expected theme ids', () {
      expect(kDefaultDarkThemeId, 'dracula');
      expect(kDefaultLightThemeId, 'github');
    });
  });
}

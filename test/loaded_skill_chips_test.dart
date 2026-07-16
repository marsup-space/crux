// Tests for [LoadedSkillChips] — the inline chip row in the chat
// toolbar that surfaces the skills currently loaded into the session.
//
// The widget reads from a `Set<String>` and renders one chip per
// name using the same verbose-mode `$<skill-name>` chip styling.
// Two responsibilities under test:
//
//   * Width budget — `widthBudget` returns the exact cell count the
//     row will occupy, so the toolbar's `LayoutBuilder` can reserve
//     the right amount of space.
//   * Visual layout — alphabetical sort, `$` triggers disappear
//     visually, names render with the chip background color from
//     the theme.

import 'package:crux/src/components/loaded_skill_chips.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('LoadedSkillChips.widthBudget', () {
    test('returns 0 for an empty set (no row reservation)', () {
      expect(LoadedSkillChips.widthBudget(const {}), 0);
    });

    test(r'one chip: 1 cell `$` + name length, no separator', () {
      expect(LoadedSkillChips.widthBudget({'alpha'}), 1 + 5);
    });

    test('two chips: each chip width + 1 separator cell between them', () {
      // '$alpha' + ' ' + '$beta' = 6 + 1 + 5 = 12
      expect(LoadedSkillChips.widthBudget({'alpha', 'beta'}), 12);
    });

    test('separator width is configurable', () {
      // 3 chips × (1 + name len) + 2 × 4 separator cells
      // = (1+1) + (1+5) + (1+4) + 8 = 2 + 6 + 5 + 8 = 21
      final w = LoadedSkillChips.widthBudget(
        const {'a', 'bbbbb', 'cccc'},
        separatorWidth: 4,
      );
      expect(w, 21);
    });
  });

  group('LoadedSkillChips rendering', () {
    test('renders nothing for an empty set', () async {
      await testNocterm('chips empty', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: const LoadedSkillChips(names: <String>{}),
          ),
        );
        // SizedBox.shrink → zero-width, zero-height. An unset cell
        // (null) or a space (' ') both indicate the widget did not
        // draw anything visible — accept either.
        final cell = tester.terminalState.getCellAt(0, 0);
        if (cell != null) {
          expect(cell.char, anyOf(' ', ''));
        }
      }, size: const Size(40, 5));
    });

    test('alphabetical order regardless of insertion order', () async {
      await testNocterm('chips sort', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: const LoadedSkillChips(names: {'zeta', 'alpha', 'mu'}),
          ),
        );
        // The 3 names take positions in the row: `$alpha`, gap,
        // `$mu`, gap, `$zeta`. The `$` triggers are styled
        // invisible so the visible sequence is just the names
        // with a single space between them. Verify the names
        // appear in alphabetical order by comparing their X
        // coordinates.
        final aMatch = tester.terminalState.findText('alpha').single;
        final mMatch = tester.terminalState.findText('mu').single;
        final zMatch = tester.terminalState.findText('zeta').single;
        expect(aMatch.x, lessThan(mMatch.x),
            reason: 'alpha must come before mu in the chip row');
        expect(mMatch.x, lessThan(zMatch.x),
            reason: 'mu must come before zeta in the chip row');
      }, size: const Size(40, 5));
    });

    test('chip name cells have the chip background color', () async {
      await testNocterm('chips background', (tester) async {
        final theme = CruxThemeData.draculaFallback;
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: const LoadedSkillChips(names: {'alpha'}),
          ),
        );
        // Walk row 0 until we find a cell whose background is the
        // theme's chipBackground color. The chip's name cells all
        // share this background, so at least one cell must match.
        final w = tester.terminalState.size.width.toInt();
        var foundChipBg = false;
        for (var x = 0; x < w; x++) {
          final cell = tester.terminalState.getCellAt(x, 0);
          if (cell == null) continue;
          if (cell.style.backgroundColor == theme.chipBackground) {
            foundChipBg = true;
            break;
          }
        }
        expect(foundChipBg, isTrue,
            reason: 'at least one cell must be styled with the '
                'chip background color');
      }, size: const Size(40, 5));
    });
  });
}
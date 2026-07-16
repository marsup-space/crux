// Inline chip row showing the skills currently loaded into the
// session's active context. Designed to live in the chat toolbar
// (between the thinking readout and the context bar) as a
// "what's in my context" indicator that doesn't depend on hover.
//
// Visual style matches the `$<skill-name>` chips used in verbose
// mode's user-message bubble and chat input: the `$` trigger is
// rendered with the chip-background color so it visually
// disappears (still takes up a cell so the chip width matches
// the input form), and the name sits inside a colored block with
// the on-color foreground.
//
// Sort: alphabetical, not insertion order. The chip row should
// not visually reshuffle when a mid-stream skill lands at the
// bottom of an unsorted set.
//
// Width budget: `1 + name.length` cells per chip (the `$` plus
// the name), plus one separator cell between chips. Callers
// compute this before mounting so the chip row doesn't get
// clipped — `softWrap: false` + `TextOverflow.visible` together
// refuse to wrap or ellipsize, which would break the visual
// contract that each chip is one contiguous colored block.
//
// Hidden entirely when [names] is empty: returns a zero-sized
// placeholder. The toolbar's pre-mount width check still skips
// the row when no skills are loaded, but keeping a no-op
// fallback here makes the widget safe to use directly in tests.

import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';

class LoadedSkillChips extends StatelessComponent {
  const LoadedSkillChips({super.key, required this.names});

  /// Skill names to render as chips. Sorted alphabetically on
  /// render so the row is stable across mid-stream additions.
  final Set<String> names;

  @override
  Component build(BuildContext context) {
    if (names.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = CruxTheme.of(context);
    final sorted = names.toList()..sort();

    final chipStyle = TextStyle(
      color: theme.onColor(theme.chipBackground),
      backgroundColor: theme.chipBackground,
    );
    // Using the chip background as both fg and bg makes the `$`
    // cell visually indistinguishable from the surrounding chip
    // cells — the chip reads as a colored block holding just the
    // name. Preserves the `1 + name.length` cell width so the
    // visible chip matches what the user typed in the input.
    final invisibleTrigger = TextStyle(
      color: theme.chipBackground,
      backgroundColor: theme.chipBackground,
    );

    final spans = <InlineSpan>[];
    for (var i = 0; i < sorted.length; i++) {
      if (i > 0) {
        // Default foreground so the separator doesn't pick up the
        // chip style from a flush — a space inside the chip span
        // would otherwise show up as a colored gap, not a clean
        // separator.
        spans.add(TextSpan(text: ' ', style: TextStyle(color: theme.foreground)));
      }
      spans.add(TextSpan(text: r'$', style: invisibleTrigger));
      spans.add(TextSpan(text: sorted[i], style: chipStyle));
    }

    return RichText(
      text: TextSpan(children: spans),
      // Never wrap a chip — a wrapped `$skill-name` would break
      // the visual contract that each chip is one colored block.
      // Callers must reserve enough width via `width` budget
      // checks before mounting this widget, otherwise the row
      // would overflow into adjacent cells.
      softWrap: false,
      overflow: TextOverflow.visible,
    );
  }

  /// Width budget in terminal cells for a chip row with these
  /// [names] plus [separatorWidth] inter-chip padding cells.
  /// Static so the toolbar's `LayoutBuilder` can reserve room
  /// without instantiating the widget.
  ///
  /// `1 + name.length` per chip (the `$` and the name) plus one
  /// separator cell between chips. Returns 0 for an empty set so
  /// the toolbar's `if (skillChipsW > 0)` guard works directly.
  static int widthBudget(Set<String> names, {int separatorWidth = 1}) {
    if (names.isEmpty) return 0;
    final namesLength = names.fold<int>(
      0,
      (sum, name) => sum + name.length,
    );
    // N chips × (1 cell `$` + name length) + (N-1) × separator.
    return names.length + namesLength +
        (names.length - 1) * separatorWidth;
  }
}
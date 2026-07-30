/// Skill picker overlay shown when the user types `$` in the
/// chat input.
///
/// Mirrors the structure of the file browser overlay (one row
/// per match, selected row highlighted) but with skills instead
/// of files. Skills are static for the lifetime of the picker
/// (no async index, no spinner), so the layout is simpler — no
/// "Searching..." placeholder, no segmented path rendering.
library;

import 'package:nocterm/nocterm.dart';

import '../services/skills/skill.dart';
import '../theme/crux_theme.dart';

class SkillPickerOverlay extends StatelessComponent {
  /// The list of skills to show, in display order. The picker
  /// does NOT filter the list itself — the chat input filters
  /// by query before passing the result here.
  final List<SkillInfo> skills;

  /// The currently selected index in [skills] (0-based). The
  /// row at this index is highlighted.
  final int selectedIndex;

  /// The first row visible in the scroll window. The picker
  /// shows up to [maxVisible] rows starting at [scrollOffset].
  final int scrollOffset;
  final int maxVisible;

  /// The query text the user has typed after the `$`. Shown in
  /// the header so the user can see what they're filtering by.
  final String query;

  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const SkillPickerOverlay({
    super.key,
    required this.skills,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    required this.query,
    this.onHover,
    this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final visible = skills.skip(scrollOffset).take(maxVisible).toList();

    final rows = <Component>[];

    // Header
    rows.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Skills',
              style: TextStyle(
                color: theme.wizardTitle,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              '(${skills.length})',
              style: TextStyle(color: theme.wizardTextDim),
            ),
            if (query.isNotEmpty) ...[
              const SizedBox(width: 2),
              Text('— $query', style: TextStyle(color: theme.wizardTextDim)),
            ],
          ],
        ),
      ),
    );

    rows.add(Divider(color: theme.outline, height: 1));

    if (visible.isEmpty) {
      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Text(
            'No matching skills. Press Esc to dismiss.',
            style: TextStyle(color: theme.wizardTextDim),
          ),
        ),
      );
    } else {
      for (var i = 0; i < visible.length; i++) {
        final skill = visible[i];
        final actualIndex = scrollOffset + i;
        final isSelected = actualIndex == selectedIndex;
        rows.add(
          MouseRegion(
            onEnter: (_) => onHover?.call(actualIndex),
            opaque: false,
            child: GestureDetector(
              onTap: () => onTap?.call(actualIndex),
              behavior: HitTestBehavior.opaque,
              child: _buildSkillRow(skill, isSelected, theme),
            ),
          ),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.wizardOverlayBg,
        // Contained floating panel — rounded border, same idiom as
        // the wizard overlay / toast.
        border: BoxBorder.all(
          color: theme.outline,
          style: BoxBorderStyle.rounded,
        ),
        borderRadius: BorderRadius.circular(1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildSkillRow(
    SkillInfo skill,
    bool isSelected,
    CruxThemeData theme,
  ) {
    final name = skill.name;
    // Truncate long descriptions so the row stays one line tall.
    final desc = skill.description.length > 60
        ? '${skill.description.substring(0, 57)}...'
        : skill.description;
    final fg = isSelected
        ? theme.wizardTextSelected
        : theme.wizardTextUnselected;
    final chipFg = isSelected ? fg : theme.onColor(theme.chipBackground);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            '\$$name',
            style: TextStyle(
              color: chipFg,
              backgroundColor: theme.chipBackground,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(width: 2),
          if (desc.isNotEmpty)
            Text('— $desc', style: TextStyle(color: theme.wizardTextDim)),
        ],
      ),
    );
  }
}

import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/slash_command.dart';

class SuggestionOverlay extends StatelessComponent {
  final List<CommandSuggestion> suggestions;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final String headerLabel;
  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const SuggestionOverlay({
    required this.suggestions,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    required this.headerLabel,
    this.onHover,
    this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final visibleSuggestions = suggestions
        .skip(scrollOffset)
        .take(maxVisible)
        .toList();

    final rows = <Component>[];

    // Header row with param label
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              headerLabel,
              style: TextStyle(
                color: CruxTheme.of(context).wizardTitle,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
    rows.add(Divider(color: CruxTheme.of(context).outline, height: 1));

    // Suggestion rows
    for (int i = 0; i < visibleSuggestions.length; i++) {
      final suggestion = visibleSuggestions[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;

      rows.add(
        MouseRegion(
          onEnter: (_) => onHover?.call(actualIndex),
          opaque: false,
          child: GestureDetector(
            onTap: () => onTap?.call(actualIndex),
            behavior: HitTestBehavior.opaque,
            child: _buildSuggestionRow(suggestion, isSelected, theme),
          ),
        ),
      );
    }

    rows.insert(0, Divider(color: CruxTheme.of(context).outline, height: 1));
    rows.add(Divider(color: CruxTheme.of(context).outline, height: 1));

    return Container(
      decoration: BoxDecoration(color: CruxTheme.of(context).wizardOverlayBg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildSuggestionRow(
    CommandSuggestion suggestion,
    bool isSelected,
    CruxThemeData theme,
  ) {
    return Container(
      decoration: isSelected
          ? BoxDecoration(color: theme.wizardRowBgSelected)
          : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            isSelected ? '> ' : '  ',
            style: TextStyle(
              color: isSelected
                  ? theme.wizardMarkerSelected
                  : theme.wizardMarkerUnselected,
            ),
          ),
          Text(
            suggestion.value,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextUnselected,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          SizedBox(width: 1),
          Expanded(
            child: Text(
              suggestion.description ?? '',
              style: TextStyle(
                color: isSelected
                    ? theme.wizardTextUnselected
                    : theme.wizardTextDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

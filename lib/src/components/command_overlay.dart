import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/slash_command.dart';

class CommandOverlay extends StatelessComponent {
  final List<SlashCommand> commands;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const CommandOverlay({
    required this.commands,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    this.onHover,
    this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final visibleCommands = commands
        .skip(scrollOffset)
        .take(maxVisible)
        .toList();

    final rows = <Component>[];

    rows.add(Divider(color: CruxTheme.of(context).outline, height: 1));

    // Header row
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Commands',
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

    // Command rows
    for (int i = 0; i < visibleCommands.length; i++) {
      final cmd = visibleCommands[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;

      rows.add(
        MouseRegion(
          onEnter: (_) => onHover?.call(actualIndex),
          opaque: false,
          child: GestureDetector(
            onTap: () => onTap?.call(actualIndex),
            behavior: HitTestBehavior.opaque,
            child: _buildCommandRow(cmd, isSelected, theme),
          ),
        ),
      );
    }

    rows.add(Divider(color: CruxTheme.of(context).outline, height: 1));

    return Container(
      decoration: BoxDecoration(color: CruxTheme.of(context).wizardOverlayBg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildCommandRow(
    SlashCommand cmd,
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
            cmd.displayName,
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
              cmd.description,
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

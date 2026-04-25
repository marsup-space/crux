import 'package:nocterm/nocterm.dart';
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
    final visibleCommands =
        commands.skip(scrollOffset).take(maxVisible).toList();

    final rows = <Component>[];

    rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // Header row
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Commands',
              style: TextStyle(
                color: Colors.brightMagenta,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
    rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

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
              child: _buildCommandRow(cmd, isSelected),
            ),
          ),
        );
      }

      rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

      return Container(
        decoration: BoxDecoration(
          color: Color.fromRGB(20, 15, 40),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildCommandRow(SlashCommand cmd, bool isSelected) {
    return Container(
      decoration: isSelected
          ? BoxDecoration(color: Color.fromRGB(40, 30, 80))
          : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            isSelected ? '> ' : '  ',
            style: TextStyle(
              color: isSelected ? Colors.brightYellow : Colors.gray,
            ),
          ),
          Text(
            cmd.displayName,
            style: TextStyle(
              color: isSelected ? Colors.brightCyan : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          SizedBox(width: 1),
          Expanded(
            child: Text(
              cmd.description,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.gray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

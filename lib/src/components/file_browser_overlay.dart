import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/file_searcher.dart';

/// File browser popover shown when the user types `@` in the chat
/// input. Mirrors [SuggestionOverlay] but renders file/directory
/// paths with a small icon column and segments the path into
/// "directory/prefix" (dim) + "filename" (highlighted) so the user
/// can scan visually. Layout matches the command palette.
class FileBrowserOverlay extends StatelessComponent {
  final List<FileMatch> files;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final String query;
  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const FileBrowserOverlay({
    required this.files,
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
    final visible = files.skip(scrollOffset).take(maxVisible).toList();
    final rows = <Component>[];

    rows.add(Divider(color: theme.outline, height: 1));
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Files',
              style: TextStyle(
                color: theme.wizardTitle,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: 1),
            Text(
              query.isEmpty
                  ? '(@-mention a file)'
                  : '(@$query)',
              style: TextStyle(color: theme.wizardTextDim),
            ),
            if (files.isEmpty) ...[
              SizedBox(width: 1),
              Text(
                '  no matches',
                style: TextStyle(color: theme.wizardTextDim),
              ),
            ],
          ],
        ),
      ),
    );
    rows.add(Divider(color: theme.outline, height: 1));

    for (int i = 0; i < visible.length; i++) {
      final file = visible[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;
      rows.add(
        MouseRegion(
          onEnter: (_) => onHover?.call(actualIndex),
          opaque: false,
          child: GestureDetector(
            onTap: () => onTap?.call(actualIndex),
            behavior: HitTestBehavior.opaque,
            child: _buildFileRow(file, isSelected, theme),
          ),
        ),
      );
    }

    rows.add(Divider(color: theme.outline, height: 1));

    return Container(
      decoration: BoxDecoration(color: theme.wizardOverlayBg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildFileRow(
    FileMatch file,
    bool isSelected,
    CruxThemeData theme,
  ) {
    final isDir = file.kind == FileMatchKind.directory;
    final icon = isDir ? '▸ ' : '  ';
    // Split path into directory and filename for a Claude-Code-like
    // "files/" (dim) + "name.dart" (highlighted) split.
    final path = file.relativePath;
    final lastSlash = path.lastIndexOf('/');
    final dirPart = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '';
    final namePart = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;

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
            icon,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextDim,
            ),
          ),
          if (dirPart.isNotEmpty)
            Text(
              dirPart,
              style: TextStyle(
                color: isSelected
                    ? theme.wizardTextUnselected
                    : theme.wizardTextDim,
              ),
            ),
          Text(
            namePart,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextUnselected,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          // Pad with trailing spaces to fill the row so the selected
          // background stretches to the right edge.
          Expanded(
            child: Text(
              '',
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

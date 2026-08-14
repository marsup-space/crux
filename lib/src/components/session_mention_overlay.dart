/// Session-mention popover shown when the user types `#` in the chat
/// input.
///
/// Mirrors the skill picker / file browser overlays: one row per
/// match, selected row highlighted, header with a count + the active
/// query. Each row shows the session id (`#123`), its title, an
/// `[archived]` tag for archived sessions, and the "last active"
/// relative time.
library;

import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../utils/session_mention.dart';

class SessionMentionOverlay extends StatelessComponent {
  /// The sessions to show, in display order. The overlay does NOT
  /// filter or rank — the chat input does that before passing the
  /// result here.
  final List<SessionMention> mentions;

  /// The currently selected index in [mentions] (0-based).
  final int selectedIndex;

  /// The first row visible in the scroll window.
  final int scrollOffset;

  final int maxVisible;

  /// The query text the user has typed after the `#`.
  final String query;

  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const SessionMentionOverlay({
    super.key,
    required this.mentions,
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
    final visible = mentions.skip(scrollOffset).take(maxVisible).toList();
    final rows = <Component>[];

    rows.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Sessions',
              style: TextStyle(
                color: theme.wizardTitle,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              '(${mentions.length})',
              style: TextStyle(color: theme.wizardTextDim),
            ),
            if (query.isNotEmpty) ...[
              const SizedBox(width: 2),
              Text(
                '(#$query)',
                style: TextStyle(color: theme.wizardTextDim),
              ),
            ] else ...[
              const SizedBox(width: 2),
              Text(
                '(#-mention a session)',
                style: TextStyle(color: theme.wizardTextDim),
              ),
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
            'No matching sessions. Press Esc to dismiss.',
            style: TextStyle(color: theme.wizardTextDim),
          ),
        ),
      );
    } else {
      for (var i = 0; i < visible.length; i++) {
        final mention = visible[i];
        final actualIndex = scrollOffset + i;
        final isSelected = actualIndex == selectedIndex;
        rows.add(
          MouseRegion(
            onEnter: (_) => onHover?.call(actualIndex),
            opaque: false,
            child: GestureDetector(
              onTap: () => onTap?.call(actualIndex),
              behavior: HitTestBehavior.opaque,
              child: _buildRow(mention, isSelected, theme),
            ),
          ),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.wizardOverlayBg,
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

  Component _buildRow(
    SessionMention mention,
    bool isSelected,
    CruxThemeData theme,
  ) {
    final idText = mention.session.displayId; // e.g. "#123"
    final title = mention.session.title.isEmpty
        ? 'Untitled'
        : mention.session.title;
    final meta = describeRelativeTime(mention.session.updatedAt);

    return Container(
      decoration: isSelected
          ? BoxDecoration(color: theme.wizardRowBgSelected)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 1),
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
            idText,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextUnselected,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(width: 1),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected
                    ? theme.wizardTextUnselected
                    : theme.wizardTextDim,
              ),
            ),
          ),
          if (mention.isArchived) ...[
            Text(
              ' archived ',
              style: TextStyle(color: theme.wizardTextDim),
            ),
          ],
          Text(
            meta,
            style: TextStyle(color: theme.wizardTextDim),
          ),
        ],
      ),
    );
  }
}

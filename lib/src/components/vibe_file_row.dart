import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';

/// One interactive row in the vibe files box — the per-file multibutton.
///
/// Shows the file's name and its segment `+N -M` counts. Hovering the row
/// swaps that row's content **in place** for two action buttons, `open`
/// and `diff` (the inline-swap interaction — no overlay, no box resize).
/// Moving the mouse away restores the file label.
///
/// The label row is laid out so its width matches the action row's, which
/// keeps the box from reflowing when the swap happens: the action row is
/// the wider of the two, and the label row right-aligns its counts into
/// the same trailing space via the [Spacer].
class VibeFileRow extends StatefulComponent {
  /// The file's display name (basename).
  final String name;

  /// Segment line counts for this file.
  final int linesAdded;
  final int linesRemoved;

  /// Fired when the user activates `open` (reveal in the file manager).
  final VoidCallback? onOpen;

  /// Fired when the user activates `diff` (open the diff fullpane).
  final VoidCallback? onDiff;

  const VibeFileRow({
    required this.name,
    required this.linesAdded,
    required this.linesRemoved,
    this.onOpen,
    this.onDiff,
    super.key,
  });

  @override
  State<VibeFileRow> createState() => _VibeFileRowState();
}

class _VibeFileRowState extends State<VibeFileRow> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: _hovered ? _actionRow(theme) : _labelRow(theme),
    );
  }

  /// The resting state: file name plus its `+N -M` counts on one line.
  ///
  /// Rendered as a single [Text] (not a [Row] with a [Spacer]) because
  /// the files box sits inside an unbounded-width [Row] in the segment
  /// bubble — a `Spacer` there is a flex child and throws
  /// "non-zero flex but incoming width constraints are unbounded",
  /// which nocterm surfaces as an empty box. A single text run carries
  /// no flex, so the row shrink-wraps like every other box row.
  Component _labelRow(CruxThemeData theme) {
    final c = component;
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(text: c.name, style: TextStyle(color: theme.text)),
          TextSpan(
            text: ' +${c.linesAdded}',
            style: TextStyle(color: theme.diffAdded),
          ),
          TextSpan(
            text: ' -${c.linesRemoved}',
            style: TextStyle(color: theme.diffRemoved),
          ),
        ],
      ),
    );
  }

  /// The hover state: the row's content is replaced by the two action
  /// buttons. A button is omitted when its callback is null.
  Component _actionRow(CruxThemeData theme) {
    final c = component;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.onOpen != null) _action('open', c.onOpen!, theme),
        if (c.onOpen != null && c.onDiff != null)
          Text(' · ', style: TextStyle(color: theme.onSurfaceDim)),
        if (c.onDiff != null) _action('diff', c.onDiff!, theme),
      ],
    );
  }

  Component _action(String label, VoidCallback onTap, CruxThemeData theme) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(color: theme.buttonBackgroundHover),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(
          label,
          style: TextStyle(color: theme.success, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

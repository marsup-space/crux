import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import 'ui/multi_button.dart';

/// One interactive row in the vibe files box — the per-file multibutton.
///
/// A thin wrapper over [MultiButton]: the idle state shows the file's
/// name and its segment `+N -M` counts, and hovering morphs the row into
/// the two action segments `open │ diff` (size-stable, no box reflow).
/// `open` reveals the file in the system file manager; `diff` opens the
/// diff fullpane focused on it.
///
/// Delegating to [MultiButton] keeps the hover morph, the per-segment
/// highlight, the even segment distribution, and the size-pinning logic
/// in one tested component instead of re-implementing them here.
class VibeFileRow extends StatelessComponent {
  /// The file's display name (basename).
  final String name;

  /// Segment line counts for this file.
  final int linesAdded;
  final int linesRemoved;

  /// Fired when the user activates `open` (reveal in the file manager).
  final VoidCallback? onOpen;

  /// Fired when the user activates `diff` (open the diff fullpane).
  /// Null when the segment's persisted calls can't reconstruct this
  /// file's diff — the `diff` segment renders dim and ignores taps
  /// rather than opening the fullpane's "(no reconstructable
  /// changes)" placeholder.
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
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    // The idle label carries the name and counts as a single-line string.
    // MultiButton renders it as one Text run, so the colored `+N -M`
    // split the old implementation had is flattened to a single color —
    // acceptable, since the counts are secondary metadata and the hover
    // segments (the actual affordance) are what the user interacts with.
    return MultiButton(
      label: '$name +$linesAdded -$linesRemoved',
      segments: [
        MultiButtonSegment(label: 'open', onPressed: onOpen),
        MultiButtonSegment(label: 'diff', onPressed: onDiff),
      ],
      color: theme.text,
      hoverColor: theme.success,
      dimHoverColor: theme.onSurfaceDim,
      disabledColor: theme.onSurfaceDim,
      separatorColor: theme.onSurfaceDim,
      // Transparent idle background so the row blends into the files box;
      // the hover/hover-segment backgrounds give the interactive feedback.
      bgColor: null,
      hoverBgColor: null,
      hoverSegmentBgColor: theme.buttonBackgroundHover,
      padding: EdgeInsets.zero,
    );
  }
}

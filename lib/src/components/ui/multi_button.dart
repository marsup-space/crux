import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../../theme/crux_theme.dart';

/// A single clickable segment within a [MultiButton].
///
/// Each segment owns its own label and optional press callback. When the
/// surrounding [MultiButton] is hovered, the segment list is rendered as
/// `seg0 | seg1 | seg2 …` and the segment under the cursor is highlighted.
///
/// Example:
/// ```dart
/// MultiButtonSegment(label: 'open',   onPressed: () => openInExplorer()),
/// MultiButtonSegment(label: 'switch', onPressed: () => switchProject()),
/// ```
class MultiButtonSegment {
  /// The text rendered for this segment when the [MultiButton] is hovered.
  final String label;

  /// Callback invoked when this segment is tapped while the button is
  /// in the hovered state. A null callback renders the segment as
  /// disabled (dim, non-clickable).
  final VoidCallback? onPressed;

  const MultiButtonSegment({required this.label, this.onPressed});
}

/// A button that, on hover, splits into multiple clickable segments
/// separated by `|`. The visual style is modelled on [Button], so the
/// widget feels at home next to it in the existing UI.
///
/// When the mouse is outside the button, the static [label] is shown.
/// When the mouse enters, the button morphs into `seg0 | seg1 | …` and
/// each half can be clicked independently. The segment currently under
/// the cursor is highlighted; the others stay dim, giving the user a
/// clear preview of which action a click will trigger.
///
/// **Width stability.** The button always reserves at least the
/// horizontal space the un-hovered [label] needs. When hovered, the
/// segment row may grow beyond that, but it will never shrink the
/// button, so neighbouring layout (such as the right-aligned project
/// path on the bottom bar) does not jitter as the mouse enters and
/// leaves.
///
/// **Per-segment visual state.** The segment under the cursor gets
/// the [hoverColor] text colour, a bold weight and a contrasting
/// [hoverSegmentBgColor] background, while the rest stay in
/// [dimHoverColor]. Disabled segments (those without a callback) drop
/// to the lowest-contrast colour and ignore hover styling.
///
/// The widget intentionally does not `extends Button`: a [Button]
/// exposes a single `onPressed` callback, whereas a [MultiButton]
/// needs one callback per segment, so the two APIs do not compose.
/// The styling parameters are kept identical (same names, same
/// defaults) so a [MultiButton] is a drop-in visual sibling of
/// [Button].
///
/// Example:
/// ```dart
/// MultiButton(
///   label: '~/projects/crux',
///   segments: [
///     MultiButtonSegment(label: 'open',   onPressed: openInExplorer),
///     MultiButtonSegment(label: 'switch', onPressed: promptForSwitch),
///   ],
/// )
/// ```
class MultiButton extends StatefulComponent {
  /// The text displayed when the button is not hovered. Also sets the
  /// minimum width of the hovered state.
  final String label;

  /// The clickable segments rendered when the button is hovered.
  /// Must contain at least one entry.
  final List<MultiButtonSegment> segments;

  /// Text color in the normal (non-hovered) state.
  final Color color;

  /// Text color of the *active* (mouse-over) segment when hovered.
  final Color hoverColor;

  /// Text color of segments that are not under the cursor while the
  /// button is hovered.
  final Color dimHoverColor;

  /// Color used for segments whose [MultiButtonSegment.onPressed] is
  /// `null`. Renders last in the visual hierarchy so the user can
  /// tell which actions are unavailable without trying to click.
  final Color disabledColor;

  /// Color of the `|` separators that join segments on hover.
  final Color separatorColor;

  /// Background color in the normal state.
  final Color bgColor;

  /// Background color when hovered (applied to the whole button).
  final Color hoverBgColor;

  /// Background color of the segment currently under the cursor.
  final Color hoverSegmentBgColor;

  /// Padding inside the button. The horizontal component is added to
  /// the label width when computing the minimum button width, so the
  /// hovered state never becomes narrower than the idle one.
  final EdgeInsets padding;

  /// Extra text style applied to all text (colors are overridden).
  final TextStyle? style;

  /// Whether the button is keyboard-focused. Mirrors [Button.focused].
  final bool focused;

  /// Text color when keyboard-focused (and not hovered).
  final Color focusColor;

  /// Background color when keyboard-focused (and not hovered).
  final Color focusBgColor;

  const MultiButton({
    super.key,
    required this.label,
    required this.segments,
    this.color = CruxTheme.buttonTextDisabled,
    this.hoverColor = CruxTheme.buttonTextHover,
    this.dimHoverColor = CruxTheme.buttonTextDisabled,
    this.disabledColor = CruxTheme.onSurfaceDim,
    this.separatorColor = CruxTheme.onSurfaceDim,
    this.bgColor = CruxTheme.buttonBackground,
    this.hoverBgColor = CruxTheme.buttonBackgroundHover,
    this.hoverSegmentBgColor = CruxTheme.surfaceVariant,
    this.padding = const EdgeInsets.symmetric(horizontal: 1),
    this.style,
    this.focused = false,
    this.focusColor = CruxTheme.buttonTextFocused,
    this.focusBgColor = CruxTheme.buttonBackgroundFocused,
  }) : assert(segments.length >= 1, 'MultiButton requires at least one segment');

  @override
  State<MultiButton> createState() => _MultiButtonState();
}

class _MultiButtonState extends State<MultiButton> {
  /// True when the mouse is anywhere inside the button. Managed
  /// exclusively by the outer [MouseRegion] so that moving the cursor
  /// over a separator (which is not its own [MouseRegion]) does not
  /// reset the hovered state.
  bool _hovered = false;

  /// Index of the segment under the cursor, or `null` if the cursor is
  /// in a gap (separators). Managed by the per-segment [MouseRegion]s.
  int? _activeSegment;

  /// Width of the idle label including its horizontal padding. Used
  /// as a lower bound on the button width so the row never collapses
  /// to a smaller width than the un-hovered label.
  double get _labelWidth {
    final textWidth = UnicodeWidth.stringWidth(component.label);
    return textWidth + component.padding.left + component.padding.right;
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      // When the cursor truly leaves the button the active segment
      // (if any) is also gone.
      if (!hovered) _activeSegment = null;
    });
  }

  void _setActiveSegment(int? index) {
    if (_activeSegment == index) return;
    setState(() => _activeSegment = index);
  }

  @override
  Component build(BuildContext context) {
    final btn = component;
    final minWidth = _labelWidth;

    // Decide which child to render, but always wrap it in a
    // ConstrainedBox with a minWidth equal to the label width. That
    // way the hovered row can grow if the segments are wider, but
    // never shrinks below the idle label.
    final Component visible;
    if (!_hovered) {
      // Idle state: render the single label. We pick the same color
      // triplet as [Button] so a MultiButton sitting next to a regular
      // Button reads as the same family.
      final fg = btn.focused ? btn.focusColor : btn.color;
      final bg = btn.focused ? btn.focusBgColor : btn.bgColor;
      final style = TextStyle(
        color: fg,
        fontWeight: btn.focused ? FontWeight.bold : null,
      ).merge(btn.style);

      visible = Container(
        decoration: BoxDecoration(color: bg),
        padding: btn.padding,
        child: Text(btn.label, style: style),
      );
    } else {
      // Hovered state: build a row of `[seg0, sep, seg1, sep, …]`
      // and wrap each segment in its own MouseRegion so we can tell
      // which half the cursor is over. Separators are NOT in their
      // own region, so the outer region keeps ownership of the
      // hovered state while the cursor glides over them.
      final children = <Component>[];
      for (var i = 0; i < btn.segments.length; i++) {
        if (i > 0) {
          children.add(
            Text(
              ' │ ',
              style: TextStyle(color: btn.separatorColor).merge(btn.style),
            ),
          );
        }
        final segment = btn.segments[i];
        final isActive = _activeSegment == i;
        final hasAction = segment.onPressed != null;
        final Color fg;
        final FontWeight? weight;
        if (!hasAction) {
          fg = btn.disabledColor;
          weight = null;
        } else if (isActive) {
          fg = btn.hoverColor;
          weight = FontWeight.bold;
        } else {
          fg = btn.dimHoverColor;
          weight = null;
        }
        // The active segment gets its own background "pill" so the
        // user can see which sub-button they are about to press.
        // The pill stops at the segment edges, so neighbouring
        // segments remain at the regular hover background.
        final segmentBg = (isActive && hasAction)
            ? btn.hoverSegmentBgColor
            : null;

        children.add(
          MouseRegion(
            opaque: false,
            onEnter: (_) => _setActiveSegment(i),
            onExit: (_) => _setActiveSegment(null),
            child: GestureDetector(
              // Disabled segments have no callback, so swallow the tap
              // by passing an empty handler — we still want the
              // hit-test to land on the segment rather than the
              // separator next to it.
              onTap: hasAction ? segment.onPressed : () {},
              behavior: HitTestBehavior.opaque,
              child: Container(
                decoration: segmentBg == null
                    ? null
                    : BoxDecoration(color: segmentBg),
                padding: btn.padding,
                child: Text(
                  segment.label,
                  style: TextStyle(color: fg, fontWeight: weight).merge(
                    btn.style,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      visible = Container(
        decoration: BoxDecoration(color: btn.hoverBgColor),
        padding: btn.padding,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
    }

    // Constrain the visible child to be at least as wide as the
    // idle label. When the hovered row is narrower than the label,
    // the extra space sits on the right and the row stays
    // left-aligned, which keeps the cursor's x position stable
    // across the transition.
    final constrained = ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: visible,
    );

    // Outer MouseRegion: tracks whether the cursor is *anywhere*
    // inside the button. Per-segment regions update _activeSegment
    // independently; this one is the source of truth for the
    // hovered/idle morph.
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: constrained,
    );
  }
}

// Multi-button measures segment label widths in display cells (CJK, emoji)
// using nocterm's internal unicode-width helpers. Not re-exported publicly.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/text/text_layout_engine.dart';
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
/// each segment can be clicked independently. The segment currently
/// under the cursor is highlighted; the others stay dim, giving the
/// user a clear preview of which action a click will trigger.
///
/// **Size stability.** Hovering never changes the button's size. The
/// button captures the width its non-hovered layout would occupy —
/// the parent-provided width when one is available (e.g. the side
/// panel's full width, so hover does not widen the surrounding
/// `Column` and nudge siblings like the git-status rows above), or
/// the idle label's intrinsic width when the parent leaves the width
/// unconstrained — and pins both the idle and the hovered states to
/// exactly that width. The height is also pinned: when the idle label
/// soft-wraps to multiple rows, the hovered state preserves that
/// multi-row footprint and centres the segment row vertically inside
/// it, so the button never collapses to a single line on hover.
///
/// **Even segment distribution.** On hover the fixed width is split
/// evenly across the segments: each segment occupies an equal share
/// of the button and its label is centred within that share, so the
/// options read as a set of balanced half-buttons spread across the
/// original footprint rather than a left-anchored cluster. A segment
/// whose label no longer fits its share is character-truncated with
/// a trailing `~` (mirroring the panel's session-title behaviour).
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
  final Color? color;

  /// Text color of the *active* (mouse-over) segment when hovered.
  final Color? hoverColor;

  /// Text color of segments that are not under the cursor while the
  /// button is hovered.
  final Color? dimHoverColor;

  /// Color used for segments whose [MultiButtonSegment.onPressed] is
  /// `null`. Renders last in the visual hierarchy so the user can
  /// tell which actions are unavailable without trying to click.
  final Color? disabledColor;

  /// Color of the `|` separators that join segments on hover.
  final Color? separatorColor;

  /// Background color in the normal state.
  final Color? bgColor;

  /// Background color when hovered (applied to the whole button).
  final Color? hoverBgColor;

  /// Background color of the segment currently under the cursor.
  final Color? hoverSegmentBgColor;

  /// Padding inside the button. The horizontal component is added to
  /// the label width when computing the minimum button width, so the
  /// hovered state never becomes narrower than the idle one.
  final EdgeInsets padding;

  /// Extra text style applied to all text (colors are overridden).
  final TextStyle? style;

  /// Whether the button is keyboard-focused. Mirrors [Button.focused].
  final bool focused;

  /// Text color when keyboard-focused (and not hovered).
  final Color? focusColor;

  /// Background color when keyboard-focused (and not hovered).
  final Color? focusBgColor;

  const MultiButton({
    super.key,
    required this.label,
    required this.segments,
    this.color,
    this.hoverColor,
    this.dimHoverColor,
    this.disabledColor,
    this.separatorColor,
    this.bgColor,
    this.hoverBgColor,
    this.hoverSegmentBgColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 1),
    this.style,
    this.focused = false,
    this.focusColor,
    this.focusBgColor,
  }) : assert(
         segments.length >= 1,
         'MultiButton requires at least one segment',
       );

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

  /// The width the button is pinned to, captured from the
  /// non-hovered layout (see [build]). `null` until the first layout
  /// pass completes, in which case the button falls back to the idle
  /// label's intrinsic width.
  double? _fixedWidth;

  /// Guards the deferred re-layout that applies a freshly captured
  /// [_fixedWidth]: the LayoutBuilder runs during layout, so the
  /// markNeedsBuild has to happen after the pass completes (post-frame),
  /// not synchronously — scheduling it synchronously would re-dirty the
  /// tree every frame and pumpAndSettle would never settle.
  bool _widthRecaptureScheduled = false;

  /// Number of times [build] has run. Exposed to the test harness so
  /// it can assert hover does not trigger an unbounded rebuild loop.
  int get debugBuildCount => _buildCount;
  int _buildCount = 0;

  /// Intrinsic width of the idle label including its horizontal
  /// padding. Used as the fallback width before the first layout
  /// measurement arrives, and as the fixed width when the parent
  /// leaves the button's width unconstrained.
  double get _labelWidth {
    final textWidth = UnicodeWidth.stringWidth(component.label);
    return textWidth + component.padding.left + component.padding.right;
  }

  /// Compute the height (in rows) the idle state occupies for a given
  /// [width]. The idle label is rendered with [Text] which soft-wraps
  /// when the content exceeds the available width, so the resulting
  /// height can be more than one row. The hovered state uses this to
  /// keep the same footprint instead of collapsing to a single row.
  double _idleHeightForWidth(double width) {
    final contentWidth =
        (width - component.padding.left - component.padding.right)
            .clamp(1, double.infinity)
            .toInt();
    final layout = TextLayoutEngine.layout(
      component.label,
      TextLayoutConfig(softWrap: true, maxWidth: contentWidth),
    );
    return layout.actualHeight +
        component.padding.top +
        component.padding.bottom;
  }

  /// Truncate [text] to fit within [maxWidth] display cells, adding
  /// a trailing '~' when anything was dropped. Mirrors the panel's
  /// session-title truncation so shortened segment labels read the
  /// same as other truncated text in the UI.
  static String _truncateToWidth(String text, double maxWidth) {
    if (maxWidth <= 0) return '';
    if (UnicodeWidth.stringWidth(text) <= maxWidth) return text;
    // Reserve 1 col for the trailing '~'.
    final budget = maxWidth - 1;
    if (budget <= 0) return '~';
    final chars = text.characters;
    double width = 0;
    final buf = StringBuffer();
    for (final c in chars) {
      final cw = UnicodeWidth.stringWidth(c);
      if (width + cw > budget) break;
      width += cw;
      buf.write(c);
    }
    buf.write('~');
    return buf.toString();
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
    _buildCount++; // test-only: lets the harness assert we don't rebuild-loop
    final btn = component;
    final theme = CruxTheme.of(context);
    final color = btn.color ?? theme.buttonTextDisabled;
    final hoverColor = btn.hoverColor ?? theme.buttonTextHover;
    final dimHoverColor = btn.dimHoverColor ?? theme.buttonTextDisabled;
    final disabledColor = btn.disabledColor ?? theme.onSurfaceDim;
    final separatorColor = btn.separatorColor ?? theme.onSurfaceDim;
    final bgColor = btn.bgColor ?? theme.buttonBackground;
    final hoverBgColor = btn.hoverBgColor ?? theme.buttonBackgroundHover;
    final hoverSegmentBgColor = btn.hoverSegmentBgColor ?? theme.surfaceVariant;
    final focusColor = btn.focusColor ?? theme.buttonTextFocused;
    final focusBgColor = btn.focusBgColor ?? theme.buttonBackgroundFocused;

    // The width both states are pinned to. Until the first layout
    // measurement arrives (see the LayoutBuilder below) fall back to
    // the idle label's intrinsic width so the button still renders at
    // a sensible size on the very first frame.
    final fixedWidth = _fixedWidth ?? _labelWidth;

    // Decide which child to render. Both states are wrapped in a
    // SizedBox of the SAME width so hovering never grows or shrinks
    // the button and neighbouring layout does not jitter as the mouse
    // enters and leaves.
    Component buildVisible(double width) {
      if (!_hovered) {
        // Idle state: render the single label. We pick the same color
        // triplet as [Button] so a MultiButton sitting next to a regular
        // Button reads as the same family.
        final fg = btn.focused ? focusColor : color;
        final bg = btn.focused ? focusBgColor : bgColor;
        final style = TextStyle(
          color: fg,
          fontWeight: btn.focused ? FontWeight.bold : null,
        ).merge(btn.style);

        return Container(
          width: width,
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
                style: TextStyle(color: separatorColor).merge(btn.style),
              ),
            );
          }
          final segment = btn.segments[i];
          final isActive = _activeSegment == i;
          final hasAction = segment.onPressed != null;
          final Color fg;
          final FontWeight? weight;
          if (!hasAction) {
            fg = disabledColor;
            weight = null;
          } else if (isActive) {
            fg = hoverColor;
            weight = FontWeight.bold;
          } else {
            fg = dimHoverColor;
            weight = null;
          }
          // The active segment gets its own background "pill" so the
          // user can see which sub-button they are about to press.
          // The pill covers the segment's whole equal share of the
          // button, so the hover target reads as a proper half-button
          // rather than a highlight hugging the label text.
          final segmentBg = (isActive && hasAction)
              ? hoverSegmentBgColor
              : null;

          children.add(
            // Each segment is wrapped in an Expanded so the button's
            // fixed width is distributed evenly across the options.
            // The segment's own MouseRegion + GestureDetector span the
            // full share, giving every option a generous, equal-sized
            // click target.
            Expanded(
              child: MouseRegion(
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
                      // Truncate against the segment's equal share of
                      // the button (separators take the rest) so a long
                      // label can never push the row past the fixed
                      // width. Expanded would cap the overflow anyway,
                      // but truncating first keeps the text measurable
                      // and shows the '~' affordance instead of silent
                      // clipping.
                      _truncateToWidth(
                        segment.label,
                        width / btn.segments.length -
                            (btn.padding.left + btn.padding.right),
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: fg,
                        fontWeight: weight,
                      ).merge(btn.style),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // The hover background covers exactly the same footprint as the
        // idle state — same width AND same height. The idle label may
        // have soft-wrapped to multiple rows; without pinning the height
        // the single-row [Row] would collapse the button to one line.
        // The [Row] is centred vertically within the preserved height so
        // the segments read as a middle band rather than jumping to the
        // top of a taller box.
        return Container(
          width: width,
          height: _idleHeightForWidth(width),
          decoration: BoxDecoration(color: hoverBgColor),
          child: Center(child: Row(children: children)),
        );
      }
    }

    // Capture the width the non-hovered layout would occupy and pin
    // the button to it, so hovering can never resize the component:
    //
    //  * When the parent gives a finite max width (the common case —
    //    e.g. the side panel's Column), the un-hovered button fills
    //    it, so `constraints.maxWidth` IS the idle width. Without the
    //    pin the hovered Row (mainAxisSize.max + Expanded children)
    //    would adopt the same width and momentarily widen the Column's
    //    intrinsic maxWidth, nudging siblings such as the git-status
    //    rows above.
    //  * When the parent leaves the width unbounded (e.g. a
    //    start-aligned Column passing infinite maxWidth), the idle
    //    label's intrinsic width is used instead.
    //
    // The captured value is applied one frame later via a deferred
    // markNeedsBuild — the LayoutBuilder pattern used elsewhere in the
    // panel (state must not be mutated during layout, so the rebuild
    // is scheduled post-frame rather than synchronously).
    return LayoutBuilder(
      builder: (context, constraints) {
        // A child may be constrained narrower than its intrinsic label
        // width. Use that real width for both the text layout and its
        // reserved height; otherwise a wrapped idle label paints below the
        // one-row footprint calculated from the unconstrained label width.
        final width = constraints.maxWidth.isFinite
            ? min(fixedWidth, constraints.maxWidth)
            : fixedWidth;
        final visible = buildVisible(width);
        // Only re-measure in the idle state. While hovered the child
        // is pinned to [_fixedWidth], which can feed back into the
        // constraints on the next layout pass, so sampling then would
        // oscillate between the parent's width and the pinned width.
        // The hover morph never changes the outer layout, so the idle
        // measurement stays valid for the whole hover session.
        if (_hovered) return _wrapWithMouseRegion(visible, width);
        final measured = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _labelWidth;
        // Absorb only growth. The pinned child can transiently shrink
        // the reported maxWidth (the LayoutBuilder forwards the
        // child's constraint negotiation back up), so a smaller
        // reading is not a real shrink of the available space — it's
        // the pin itself. Genuine growth (a longer label, a wider
        // panel) still re-seeds the width.
        if (measured > fixedWidth && !_widthRecaptureScheduled) {
          _widthRecaptureScheduled = true;
          scheduleMicrotask(() {
            _widthRecaptureScheduled = false;
            if (!mounted || _hovered || _fixedWidth == measured) return;
            setState(() => _fixedWidth = measured);
          });
        }
        return _wrapWithMouseRegion(visible, width);
      },
    );
  }

  Component _wrapWithMouseRegion(Component child, double fixedWidth) {
    // Outer MouseRegion: tracks whether the cursor is *anywhere*
    // inside the button. Per-segment regions update
    // _activeSegment independently; this one is the source of
    // truth for the hovered/idle morph.
    //
    // The height is pinned to the idle label's (possibly multi-row)
    // footprint so the hovered state — a single-row [Row] inside a
    // [Center] — still occupies the same vertical space and the hover
    // background covers the full area.
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: SizedBox(
        width: fixedWidth,
        height: _idleHeightForWidth(fixedWidth),
        child: child,
      ),
    );
  }
}

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../models/plan_selection.dart';
import '../services/plan_mode_controller.dart';
import '../theme/crux_theme.dart';
import 'annotated_scrollbar.dart';
import 'plan_scrollbar.dart';
import 'ui/button.dart';
import 'ui/multi_button.dart';

/// Below this pane width the heading markers are dropped (plain thumb
/// only) so their tooltips don't crowd the already-narrow text.
const double kPlanScrollbarMarkerMinWidth = 24;

/// Minimum width (columns) the plan pane shrinks to before the layout
/// collapses to single-column.
const double kPlanPaneMinWidth = 30;

/// Maximum width (columns) the plan pane grows to.
const double kPlanPaneMaxWidth = 80;

/// Chat-pane floor (columns) while plan mode is active: below this the
/// info sidebar drops first (§9.6 collapse order) rather than letting
/// three panes starve the chat area. 56 keeps the chat side comfortable
/// (toolbar + bubbles + input), which puts the sidebar's survival line
/// at ≈158 terminal columns — plan mode hides it decidedly earlier than
/// the bare ≥100-col rule.
const double kPlanChatPaneMinWidth = 56;

/// Resolved horizontal split of the chat panel row — see
/// [resolvePlanSplit].
class PlanSplitLayout {
  const PlanSplitLayout({
    required this.showSidebar,
    required this.sidebarWidth,
    required this.planPaneWidth,
  });

  /// Whether the right-hand info sidebar renders at all.
  final bool showSidebar;

  /// The sidebar's width in columns; `0` when [showSidebar] is false.
  final double sidebarWidth;

  /// The plan pane's width in columns; `0` when plan mode is inactive.
  final double planPaneWidth;
}

/// Resolve the chat panel's horizontal layout for [totalWidth] columns.
///
/// When plan mode is inactive this keeps the bare sidebar decision
/// ([sidebarWidth] non-null ⇔ the terminal is wide enough for it). When
/// active:
///   1. the info sidebar drops FIRST when keeping three panes would
///      starve chat below [kPlanChatPaneMinWidth] — chat is the primary
///      surface, the sidebar is ambient;
///   2. the plan/chat split halves what remains so the plan pane is
///      never wider than the chat pane, bounded by
///      [kPlanPaneMinWidth]/[kPlanPaneMaxWidth]. Only at extreme
///      widths (terminal ≲ 2×[kPlanPaneMinWidth]) can the min clamp
///      leave chat a column short of plan — the documented
///      single-column-collapse territory (§9.6).
PlanSplitLayout resolvePlanSplit(
  double totalWidth, {
  required bool planActive,
  double? sidebarWidth,
}) {
  if (!planActive) {
    return PlanSplitLayout(
      showSidebar: sidebarWidth != null,
      sidebarWidth: sidebarWidth ?? 0,
      planPaneWidth: 0,
    );
  }
  if (sidebarWidth != null) {
    final avail = totalWidth - sidebarWidth - 2; // plan|chat + chat|sidebar dividers
    final planPaneWidth = ((avail - 1) / 2)
        .clamp(kPlanPaneMinWidth, kPlanPaneMaxWidth)
        .toDouble();
    if (avail - planPaneWidth >= kPlanChatPaneMinWidth) {
      return PlanSplitLayout(
        showSidebar: true,
        sidebarWidth: sidebarWidth,
        planPaneWidth: planPaneWidth,
      );
    }
  }
  // Sidebar dropped: two-pane split over the row minus its divider.
  final avail = totalWidth - 1;
  final planPaneWidth = ((avail - 1) / 2)
      .clamp(kPlanPaneMinWidth, kPlanPaneMaxWidth)
      .toDouble();
  return PlanSplitLayout(
    showSidebar: false,
    sidebarWidth: 0,
    planPaneWidth: planPaneWidth,
  );
}

/// The left pane of plan mode: renders the plan document as markdown,
/// tracks the selection, flashes agent edits, and hosts the version
/// timeline at the bottom.
///
/// A dumb renderer of [PlanModeController] — every mutation goes through
/// the controller; the pane listens and repaints.
class PlanDocPane extends StatefulComponent {
  final PlanModeController controller;
  final Strings strings;

  const PlanDocPane({
    super.key,
    required this.controller,
    this.strings = kEnglishStrings,
  });

  @override
  State<PlanDocPane> createState() => _PlanDocPaneState();
}

class _PlanDocPaneState extends State<PlanDocPane>
    with SingleTickerProviderStateMixin {
  /// Drives the flash-fade repaint clock.
  late final AnimationController _fadeClock = AnimationController(
    vsync: this,
    duration: kFlashFade,
  );

  /// Drives the follow-mode scroll animation.
  AnimationController? _scrollAnim;

  @override
  void initState() {
    super.initState();
    component.controller.addListener(_onControllerChanged);
    // Ticking the fade clock repaints the flash rows at frame rate for
    // the fade duration.
    _fadeClock.addListener(_onFadeTick);
  }

  @override
  void dispose() {
    component.controller.removeListener(_onControllerChanged);
    _fadeClock.dispose();
    _scrollAnim?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final c = component.controller;
    // Re-parse under the real theme on the first build after the pane
    // learns it (the controller parsed with the mono fallback on enter).
    final theme = CruxTheme.of(context);
    if (!identical(c.theme, theme)) {
      c.theme = theme;
    }
    if (c.activeFlashes.isNotEmpty && !_fadeClock.isAnimating) {
      _fadeClock.forward(from: 0.0);
    }
    if (mounted) setState(() {});
  }

  void _onFadeTick() {
    if (!mounted) return;
    setState(() {});
    if (_fadeClock.isCompleted) {
      component.controller.activeFlashes.removeWhere(
        (f) => f.isExpiredAt(DateTime.now()),
      );
    }
  }

  /// Animate the scroll offset to [targetRow] over ~200 ms ease-out.
  /// `ScrollController` has only `jumpTo` — the animation drives
  /// `jumpTo` per frame (the same frame-driven mechanism the codebase
  /// uses for fades).
  void _animateScrollTo(double targetRow) {
    final sc = component.controller.scrollController;
    _scrollAnim?.dispose();
    final anim = AnimationController.unbounded(
      value: sc.offset,
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scrollAnim = anim;
    anim.addListener(() {
      sc.jumpTo(anim.value);
    });
    anim.animateTo(targetRow, curve: Curves.easeOut);
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final c = component.controller;
    final strings = component.strings;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 80;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(theme, c, strings, width),
            Expanded(
              child: SelectionArea(
                selectionColor: theme.selectionColor,
                onSelectionInfoChanged: (info) {
                  final range = info.singleRange;
                  if (range == null) {
                    c.clearSelection();
                  } else {
                    c.onSelectionRange(range.$1, range.$2);
                  }
                },
                child: PlanScrollbar(
                  controller: c.scrollController,
                  thumbVisibility: true,
                  // Narrow panes drop the heading markers (plain thumb
                  // only) so their tooltips don't crowd the text.
                  markers: width < kPlanScrollbarMarkerMinWidth
                      ? const []
                      : [
                          for (final h in c.parsed.headings)
                            ScrollbarMarker(
                              itemIndex: h.renderedRow,
                              label: h.text,
                              color: theme.accent,
                            ),
                        ],
                  // A marker click is a user scroll — it drops the pane
                  // to FREE mode (same as wheel/drag), keeping the
                  // follow/free state machine honest.
                  onMarkerTap: c.onUserScroll,
                  child: SingleChildScrollView(
                    controller: c.scrollController,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: RichText(
                        text: TextSpan(children: c.parsed.spans),
                        softWrap: true,
                        lineBackgroundProvider: (row) =>
                            _flashColorForRow(theme, c, row),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _buildFooter(theme, c, strings, width),
          ],
        );
      },
    );
  }

  Component _buildHeader(
    CruxThemeData theme,
    PlanModeController c,
    Strings strings,
    int width,
  ) {
    final fileName = c.planDocPath == null
        ? ''
        : c.planDocPath!.split(RegExp(r'[/\\]')).last;
    final modeBadge = c.viewMode == PlanViewMode.follow
        ? strings.t('plan.pane.follow')
        : strings.t('plan.pane.free');
    final historyBadge = c.isViewingHistory
        ? strings.t('plan.timeline.viewingVersion', {
            'version': '${c.viewingVersion}',
            'head': '${c.headVersion}',
          })
        : '';
    final parts = <String>[
      if (fileName.isNotEmpty) fileName,
      modeBadge,
      if (c.approved) strings.t('plan.pane.approved'),
      if (historyBadge.isNotEmpty) historyBadge,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join('  ·  '),
              style: TextStyle(color: theme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Approve toggle (design doc §5 P6): lifts the edit/write/shell
          // guards so the agent can implement the plan; same state as
          // `/plan approve`. When approved the same button offers the
          // reverse action (unapprove re-arms the guards).
          Button(
            label: c.approved
                ? strings.t('plan.pane.unapprove')
                : strings.t('plan.pane.approve'),
            onPressed: c.approved ? c.unapprove : c.approve,
            color: c.approved ? theme.warning : theme.success,
          ),
          const SizedBox(width: 1),
          Button(
            label: strings.t('plan.pane.exit'),
            onPressed: c.exit,
            color: theme.error,
          ),
        ],
      ),
    );
  }

  Component _buildFooter(
    CruxThemeData theme,
    PlanModeController c,
    Strings strings,
    int width,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: theme.divider),
          Row(
            children: [
              // Version timeline (P5): clickable v1..HEAD markers.
              Expanded(
                child: _PlanTimelineRow(controller: c, strings: strings),
              ),
              if (c.viewMode == PlanViewMode.free)
                MultiButton(
                  label: strings.t('plan.pane.jumpToLatest'),
                  segments: [
                    MultiButtonSegment(
                      label: strings.t('plan.pane.jumpToLatest'),
                      onPressed: () {
                        c.onJumpToLatest();
                        _animateScrollTo(
                          c.scrollController.offset,
                        );
                      },
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Background color for [row] when a flash covers it, fading toward
  /// transparent over [kFlashFade].
  Color? _flashColorForRow(CruxThemeData theme, PlanModeController c, int row) {
    if (c.activeFlashes.isEmpty) return null;
    final now = DateTime.now();
    for (final flash in c.activeFlashes) {
      if (flash.renderedRows.contains(row)) {
        final progress = flash.progressAt(now);
        if (progress >= 1.0) continue;
        // Fade from the selection color toward transparent.
        return theme.selectionColor.withOpacity(0.45 * (1 - progress));
      }
    }
    return null;
  }
}

/// The version-timeline row: one compact numeric button per version
/// (`1 2 3 …`), clickable to time-travel the pane (§9.3). HEAD is
/// emphasized and the currently-viewed version highlighted; a separate
/// "revert" action restores a past version as the new HEAD.
///
/// This replaces the old `MultiButton` strip: `MultiButton` pins a fixed
/// width and splits it **evenly** across segments (truncating each with
/// `~`), so with many versions the `v1…vN` labels crushed into unreadable
/// slivers and later versions became unreachable. Here the row is a plain
/// `Row` of buttons laid out to the pane's full inner width (the footer's
/// `Expanded` hands it the width); when the buttons would overflow, the
/// trailing window keeps the most-recent versions (ending at HEAD) and
/// the currently-viewed version reachable.
class _PlanTimelineRow extends StatelessComponent {
  final PlanModeController controller;
  final Strings strings;

  const _PlanTimelineRow({required this.controller, required this.strings});

  /// Width (columns) of a single version button: the numeric label plus
  /// the button's horizontal padding, plus the single space that
  /// separates it from the next button.
  static int _versionCellWidth(int version) {
    // Bare number (`1`, `12`, …) — no `v` prefix, no `HEAD` text.
    final digits = version.toString().length;
    return digits + 2 /* Button h-padding */ + 1 /* inter-button space */;
  }

  /// Pick the window of versions `[lo..hi]` (1-based, inclusive) that
  /// fits [maxWidth], keeping the most-recent versions (ending at HEAD)
  /// and guaranteeing [keep] (the currently-viewed version) is inside.
  (int, int) _visibleWindow(int head, int keep, int maxWidth) {
    var lo = head;
    var used = _versionCellWidth(head);
    // Grow the window leftwards (most-recent first) while it fits.
    while (lo > 1 && used + _versionCellWidth(lo - 1) <= maxWidth) {
      lo--;
      used += _versionCellWidth(lo);
    }
    // Ensure the viewed version is reachable: if it fell off the left
    // edge, slide the window left (dropping the newest non-viewed
    // versions) until it's included.
    while (lo > keep && lo > 1) {
      lo--;
    }
    return (lo, head);
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final c = controller;
    final head = c.headVersion;
    if (head <= 0) {
      return Text(
        strings.t('plan.timeline.empty'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 80;
        final (lo, hi) = _visibleWindow(head, c.viewingVersion, maxWidth);

        final children = <Component>[
          for (var v = lo; v <= hi; v++) ...[
            if (v > lo) const SizedBox(width: 1),
            _VersionButton(
              version: v,
              isHead: v == head,
              isViewed: v == c.viewingVersion,
              onPressed: () => c.viewVersion(v),
            ),
          ],
        ];

        // The revert action is only meaningful when viewing a past
        // version. Keep it as a separate action (shown only then).
        if (c.isViewingHistory) {
          children.add(const SizedBox(width: 1));
          children.add(
            Button(
              label: strings.t('plan.timeline.revert'),
              onPressed: () => c.revertTo(c.viewingVersion),
            ),
          );
        }

        return Row(children: children);
      },
    );
  }
}

/// One version marker in the timeline: a bare number. HEAD renders bold
/// (inverse where supported); the currently-viewed version is
/// highlighted. The `v`/`HEAD` text stays in the header/status area
/// (`viewing v3 · current v7`), so dropping it from the strip loses no
/// information and keeps each marker 1–3 columns wide.
class _VersionButton extends StatelessComponent {
  final int version;
  final bool isHead;
  final bool isViewed;
  final VoidCallback onPressed;

  const _VersionButton({
    required this.version,
    required this.isHead,
    required this.isViewed,
    required this.onPressed,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Button(
      label: '$version',
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 1),
      color: isViewed
          ? theme.accent
          : isHead
              ? theme.buttonText
              : theme.buttonTextDisabled,
      bgColor: isViewed ? theme.surfaceVariant : null,
      style: TextStyle(
        fontWeight: (isHead || isViewed) ? FontWeight.bold : null,
      ),
    );
  }
}

import 'package:nocterm/nocterm.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.dart';
import '../../theme/crux_theme.dart';
import '../../services/skills/skill_discovery.dart';
import '../../services/skills/skill.dart';
import '../../version.dart';
import '../ui/button.dart';
import '../input_chips.dart';
import '../input_keys.dart';
import '../input_overlay.dart';
import '../input_overlay_popover.dart';
import '../overlay_controller.dart';
import 'home_layout_store.dart';
import 'home_widgets.dart';
import 'widgets/activity_widget.dart';
import 'widgets/coding_plan_widget.dart';
import 'widgets/quick_actions_widget.dart';
import 'widgets/recent_sessions_widget.dart';
import 'widgets/settings_widget.dart';
import 'widgets/skills_widget.dart';
import 'widgets/tokens_widget.dart';
import 'widgets/notes_widget.dart';
import 'widgets/workspace_widget.dart';
import 'widgets/yesterday_widget.dart';
import 'plugin_home_widget.dart';

/// The home screen — an independent full screen, not a modal overlay.
///
/// Unlike the modal panes (session manager, `Fullpane`), home wears no
/// overlay chrome: no dimmed barrier, no inset margins, no close
/// button. It owns the whole terminal, the same way the chat screen
/// does. You leave it not by "closing" it but by *going* somewhere —
/// `esc` / `enter` on an action returns to the chat.
///
/// Phase 2 turns the shell into the bento-grid dashboard: a responsive
/// grid of bordered boxes fed by a [HomeWidgetRegistry], with
/// keyboard-first navigation, mouse-clickable boxes, and vertical
/// scrolling when the grid outgrows the viewport. The grid still ships
/// stub boxes; the live built-ins land in Phase 3.
class HomeScreen extends StatefulComponent {
  /// Called when the user leaves home for the chat screen (`esc`, and
  /// later any action that opens a session).
  final VoidCallback onExit;

  /// Widgets to lay out. When null, the grid is filled with
  /// [StubHomeWidget]s so the layout engine can be exercised before the
  /// Phase 3 built-ins exist.
  final List<HomeWidget>? widgets;

  /// The context handed to every widget. When null, a minimal context
  /// is synthesized (runCommand always reports not-busy, close →
  /// [onExit]) so the grid can render before the panel wires services.
  final HomeContext? context_;

  /// Persisted layout to apply on open (box order + spans from
  /// `[home].layout`). Entries whose id isn't among the available
  /// widgets are skipped; widgets with no entry append at the end in
  /// their default order. When null, the default order/spans are used.
  final List<HomeLayoutEntry>? initialLayout;

  /// Called whenever edit mode changes the layout (reorder / resize /
  /// hide / re-add) with the new full placement list, so the caller can
  /// persist it. Null in tests/previews (edit mode still works, it just
  /// isn't saved).
  final void Function(List<HomeLayoutEntry> layout)? onLayoutChanged;

  /// Quit the app cleanly (prints the run summary, tears down the
  /// terminal). Wired by the chat panel to `QuitHandler
  /// .quitAndPrintSummary` — the single exit path for the whole app,
  /// same as `/quit` and the chat input's Ctrl+C handler. When null
  /// (tests), Ctrl+C on home is a no-op instead of a hard `exit()`.
  final VoidCallback? quitApp;

  /// Quit immediately without summary output. Used as the Ctrl+C
  /// fallback when no app-level handler is wired; matches nocterm's
  /// default Ctrl+C semantics (exit now, no cleanup) so a missing
  /// quit handler can never trap the user on the home screen.
  final VoidCallback? quitNow;

  /// Start a new Chat-mode conversation with [text] as the first prompt,
  /// then leave home for the chat screen. Returns false if refused
  /// mid-stream. Null (tests / previews) means "no starter wired" — the
  /// quick-chat input then does nothing on submit.
  final bool Function(String text)? onStartChat;

  /// Shared overlay state for the full-featured quick-chat input. When
  /// null (tests / previews), the input is a plain starter field.
  final OverlayController? overlayController;

  /// Shared text buffer backing the quick-chat input. When null, home
  /// falls back to its own local controller.
  final TextEditingController? inputController;

  /// Trigger detection (@ / # / $ / slash) for the quick-chat input.
  final InputOverlay? inputOverlay;

  /// Key handling (overlay navigation, command mode, submit) for the
  /// quick-chat input.
  final InputKeyHandler? inputKeyHandler;

  /// Max visible rows in the overlay popover.
  final int maxVisibleItems;

  /// Wired by the chat panel so the quick-chat area can register its
  /// local rebuild callback. Typing in the field must only rebuild the
  /// input row (+ its popover), never the whole home grid — the panel
  /// points the InputOverlay/InputKeyHandler `refresh` at this widget
  /// instead of its own panel-wide setState, which used to rebuild all
  /// ~10 boxes (~26ms) on every keystroke. Null in tests/previews.
  final void Function(VoidCallback rebuild)? onQuickChatAreaMounted;

  const HomeScreen({
    super.key,
    required this.onExit,
    this.widgets,
    this.context_,
    this.initialLayout,
    this.onLayoutChanged,
    this.quitApp,
    this.quitNow,
    this.onStartChat,
    this.overlayController,
    this.inputController,
    this.inputOverlay,
    this.inputKeyHandler,
    this.maxVisibleItems = 6,
    this.onQuickChatAreaMounted,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// One placed box: the widget and the span the user (or default) chose.
/// The grid lays out placements in order; edit mode mutates this list
/// (reorder / resize / hide / re-add) and persists the result.
class _Placement {
  final HomeWidget widget;
  final int span;

  const _Placement(this.widget, this.span);
}

/// A laid-out row: the widgets in it, their spans, and the row's height
/// (max of the boxes' `heightFor`, so shorter boxes stretch their
/// borders to match — a dashboard with ragged bottoms looks broken).
class _Row {
  final List<HomeWidget> widgets;
  final List<int> spans;

  _Row(this.widgets, this.spans);

  int get height {
    var h = 0;
    for (var i = 0; i < widgets.length; i++) {
      // +2 for the border rows, +1 for the title-button row when the
      // box has one (its title renders as a component row, not in the
      // painted border).
      final wh = widgets[i].heightFor(spans[i]) +
          2 +
          (widgets[i].hasTitleButtons ? 1 : 0);
      if (wh > h) h = wh;
    }
    return h;
  }
}

class _HomeScreenState extends State<HomeScreen> {
  // Splash ASCII-art logo — the same art the boot splash renders, so
  // home carries the brand. Colored with the theme's accent.
  static const _logo = [
    '  ██████╗   ██████╗  ██╗   ██╗ ██╗  ██╗',
    ' ██╔════╝  ██╔══██╗ ██║   ██║  ██╗██╔╝',
    ' ██║      ██████╔╝ ██║   ██║   ███╔╝ ',
    ' ██║      ██╔══██╗ ██║   ██║  ██╔██╗ ',
    '  ██████╗ ██║  ██║  █████╔╝ ██╔╝ ██╗',
  ];

  /// Rows above the scroll viewport: container top padding (1) + hero
  /// block (5 logo rows; the info column shares them) + gap (1). The box
  /// hover handler uses this to map the cursor's terminal y to a content
  /// row.
  static const double _kAboveViewport = 1 + 5 + 1;

  final _scrollController = ScrollController();

  /// Controller for the quick-chat input at the bottom of home.
  final TextEditingController _chatController = TextEditingController();

  /// Index of the focused box in the flat placement list.
  int _focusedIndex = 0;

  /// Test-only view of the focused box index, so navigation tests can
  /// assert focus without scraping the rendered border color.
  @visibleForTesting
  int get focusedIndexForTest => _focusedIndex;

  /// One-line notice shown when an action is refused (e.g. runCommand
  /// mid-stream) or an edit is rejected. Rendered in the footer; cleared
  /// on the next key.
  String? _notice;

  /// True while edit mode is active: a distinct key scope (reorder /
  /// resize / hide / re-add) with its own footer legend and an
  /// `[editing]` marker in the hero header.
  bool _editing = false;

  /// Hot reload runs `reassemble`, not `initState`, so one-shot
  /// initializations that read constructor inputs must be repeated
  /// here — otherwise a reassembled screen keeps the pre-edit
  /// placements and a removed/renamed box stays on screen.
  @override
  void reassemble() {
    super.reassemble();
    _skillsCache = null;
    _allById = {for (final w in _defaultWidgets()) w.id: w};
    _placements = _resolvePlacements();
    _wireWidgetListeners();
  }

  /// The ordered, span-tagged placements shown in the grid. Built once
  /// from the default order + [HomeScreen.initialLayout]; mutated by
  /// edit mode. The single source of truth for what's on screen and in
  /// what order.
  late List<_Placement> _placements;

  /// Every widget the grid could show, keyed by id — the union of the
  /// visible placements and the hidden ones available for re-add.
  late Map<String, HomeWidget> _allById;

  /// Signature of the last plugin list folded into [_allById] (the
  /// comma-joined plugin ids). The registry rescans every ~2 s on its
  /// own timer; the home screen notices set changes here, in build,
  /// and rebuilds the widget map + placements so plugin boxes hot-swap
  /// without re-entering home. (Writing layout fields during build is
  /// this file's existing pattern — see `_packedRowsCache`.)
  String? _lastPluginSignature;

  /// Memoized [discoverSkills] for this home mount. Discovery is a
  /// synchronous directory walk (~2ms warm, dozens of stat() calls)
  /// and the skills box re-reads it several times per build —
  /// `itemCount`, `selectedIndex`, `selectItemAt`, and `build` each
  /// invoke the closure, so a single hover-driven rebuild used to pay
  /// 5+ scans. One scan per mount makes those free; the state is
  /// recreated whenever home is left and re-entered (matching the
  /// widget's "install a skill and re-enter home" contract), and
  /// [reassemble] drops it so hot reload re-scans.
  List<SkillInfo>? _skillsCache;

  List<SkillInfo> _cachedSkills() =>
      _skillsCache ??= discoverSkills(cwd: _ctx.projectPath);

  void _syncPluginBoxes() {
    final plugins = _ctx.plugins?.call();
    if (plugins == null) return; // no plugin wiring: nothing to sync
    // The registry also fires placement-affecting edits (a spec's span
    // list can't change without a new file, so ids suffice as the
    // signature).
    final signature = plugins.map((p) => p.id).join(',');
    if (signature == _lastPluginSignature) return;
    _lastPluginSignature = signature;
    // _defaultWidgets() already folds in the FRESH plugin list; a
    // user-edited placement order survives via _resolvePlacements
    // (persisted ids still resolve; vanished ids drop out; new ids
    // append at the end).
    _allById = {for (final w in _defaultWidgets()) w.id: w};
    _placements = _resolvePlacements();
    _wireWidgetListeners();
  }

  /// The default widgets for this screen (the five built-ins, or the
  /// caller-supplied list). Order is the default layout order.
  List<HomeWidget> _defaultWidgets() {
    if (component.widgets != null) return component.widgets!;
    final ctx = _ctx;
    return [
      WorkspaceHomeWidget(),
      QuickActionsHomeWidget(seedInput: ctx.seedInput),
      SettingsHomeWidget(),
      // Compact status boxes: tokens, live provider usage, and the
      // activity heatmap.
      TokensHomeWidget(),
      CodingPlanHomeWidget(),
      ActivityHomeWidget(),
      SkillsHomeWidget(skills: _cachedSkills),
      NotesHomeWidget(
        service: ctx.notesService,
        openNotes: ctx.openNotes,
      ),
      RecentSessionsHomeWidget(
        sessions: ctx.sessions,
        currentSessionId: ctx.currentSessionId,
        onSwitch: ctx.switchSession,
      ),
      YesterdayHomeWidget(sessions: ctx.sessions),
      // Spec-driven plugin boxes (`placement = home/both`): appended
      // after the built-ins so user plugins land at the grid's end
      // (editable/reorderable like every other box). Built fresh on
      // each _defaultWidgets() pass — re-running in initState and
      // reassemble — so registry rescans hot-swap boxes. But the grid
      // caches _allById across builds, so ALSO refresh below whenever
      // the plugin list changes (see didUpdateComponent-less path in
      // build via _syncPluginBoxes).
      if (ctx.plugins != null && ctx.pluginHost != null)
        ...PluginHomeWidgets.build(ctx.plugins!(), ctx.pluginHost!),
    ];
  }

  HomeContext get _ctx =>
      component.context_ ?? HomeContext.minimal(close: component.onExit);

  // ── Hero info lines ─────────────────────────────────────────────

  static String _formatDate(DateTime d, Strings s) {
    final weekdays = s.t('home.weekdays').split(',');
    final months = s.t('home.months').split(',');
    return s.t('home.date', {
      'weekday': weekdays[d.weekday - 1],
      'month': months[d.month - 1],
      'day': '${d.day}',
    });
  }

  /// Workspace fact for the hero: the project directory basename,
  /// mirroring the workspace box's `dir` line but shorter.
  String _workspaceLine() {
    final path = _ctx.projectPath;
    if (path.isEmpty) return _ctx.strings.t('home.noWorkspace');
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }

  /// Branch fact for the hero — dimmed, and honest when there's no repo.
  String _branchLine() {
    final status = _ctx.gitStatusService.current;
    if (!status.isRepo) return _ctx.strings.t('home.notGitRepo');
    final branch = status.branch.isEmpty
        ? _ctx.strings.t('home.noBranch')
        : status.branch;
    return '⎇ $branch';
  }

  @override
  void initState() {
    super.initState();
    _allById = {for (final w in _defaultWidgets()) w.id: w};
    _placements = _resolvePlacements();
    _wireWidgetListeners();
  }

  /// Subscribe to each widget's change notification so a widget that
  /// mutates its own state (day navigation, …) can ask home to re-run
  /// `build` via [HomeWidget.notifyChanged]. Wired in `initState` and
  /// `reassemble` because both rebuild `_allById` — with fresh widget
  /// instances on the default path, the same instances on the
  /// caller-supplied path.
  void _wireWidgetListeners() {
    for (final widget in _allById.values) {
      widget.onChanged = () {
        if (mounted) setState(() {});
      };
    }
  }

  /// Merge the persisted layout with the available widgets into the
  /// placement list. Persisted entries come first in their saved order
  /// (skipping ids this build doesn't have); any widget with no entry
  /// appends at the end in default order with its default span. A widget
  /// whose saved span it doesn't support falls back to its default.
  List<_Placement> _resolvePlacements() {
    final saved = component.initialLayout;
    final placements = <_Placement>[];
    final placed = <String>{};
    if (saved != null) {
      for (final entry in saved) {
        final widget = _allById[entry.id];
        if (widget == null || placed.contains(entry.id)) continue;
        placements.add(_Placement(widget, _sanitizedSpan(widget, entry.span)));
        placed.add(entry.id);
      }
    }
    for (final widget in _allById.values) {
      if (placed.contains(widget.id)) continue;
      placements.add(_Placement(widget, _defaultSpan(widget)));
    }
    return placements;
  }

  /// The largest span a widget supports (its default look at wide
  /// widths). Used when there's no persisted entry for it.
  static int _defaultSpan(HomeWidget widget) =>
      widget.supportedSpans.reduce((a, b) => a > b ? a : b);

  /// Clamp a persisted span to what the widget supports: the closest
  /// supported span, defaulting to the widget's own default when the
  /// saved value is unusable.
  static int _sanitizedSpan(HomeWidget widget, int span) {
    final spans = widget.supportedSpans;
    if (spans.contains(span)) return span;
    // Closest supported span to the requested one.
    var best = _defaultSpan(widget);
    for (final s in spans) {
      if ((s - span).abs() < (best - span).abs()) best = s;
    }
    return best;
  }

  /// Current layout as persistable entries (order + span).
  List<HomeLayoutEntry> _layoutEntries() =>
      [for (final p in _placements) HomeLayoutEntry(p.widget.id, p.span)];

  /// Persist the current layout via the caller's callback, if any.
  void _persistLayout() {
    component.onLayoutChanged?.call(_layoutEntries());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  // ── Edit mode ─────────────────────────────────────────────────────

  void _toggleEdit() {
    setState(() {
      _editing = !_editing;
      _notice = null;
    });
  }

  /// Hidden widgets available for re-add (registered but not placed).
  List<HomeWidget> get _hiddenWidgets {
    final placed = {for (final p in _placements) p.widget.id};
    return [for (final w in _allById.values) if (!placed.contains(w.id)) w];
  }

  /// Reorder the focused box one step left/right in the placement list.
  void _editMove(int direction) {
    if (_placements.length < 2) return;
    final from = _focusedIndex.clamp(0, _placements.length - 1);
    final to = (from + direction).clamp(0, _placements.length - 1);
    if (to == from) return;
    setState(() {
      final item = _placements.removeAt(from);
      _placements.insert(to, item);
      _focusedIndex = to;
      _notice = null;
    });
    _persistLayout();
  }

  /// Cycle the focused box's span within its `supportedSpans`.
  /// [direction] is +1 (grow, `=`) or -1 (shrink, `-`); single-span
  /// widgets can't be resized.
  void _editResize(int direction) {
    final index = _focusedIndex.clamp(0, _placements.length - 1);
    final placement = _placements[index];
    final spans = placement.widget.supportedSpans.toList()..sort();
    if (spans.length < 2) {
      setState(() => _notice = _ctx.strings.t('home.fixedSize'));
      return;
    }
    final current = spans.indexOf(placement.span);
    final next = spans[(current + direction) % spans.length];
    setState(() {
      _placements[index] = _Placement(placement.widget, next);
      _notice = null;
    });
    _persistLayout();
  }

  /// Hide the focused box (remove it from the placements; it stays
  /// available for re-add via `a`).
  void _editHide() {
    if (_placements.isEmpty) return;
    if (_placements.length == 1) {
      setState(() => _notice = _ctx.strings.t('home.keepOne'));
      return;
    }
    final index = _focusedIndex.clamp(0, _placements.length - 1);
    setState(() {
      _placements.removeAt(index);
      _focusedIndex = _focusedIndex.clamp(0, _placements.length - 1);
      _notice = null;
    });
    _persistLayout();
  }

  /// Re-add the first hidden widget (registered but not placed).
  /// Multi-hidden re-add is intentionally minimal: each `a` press brings
  /// back one box in default order.
  void _editAdd() {
    final hidden = _hiddenWidgets;
    if (hidden.isEmpty) {
      setState(() => _notice = _ctx.strings.t('home.noHidden'));
      return;
    }
    final widget = hidden.first;
    setState(() {
      _placements.add(_Placement(widget, _defaultSpan(widget)));
      _focusedIndex = _placements.length - 1;
      _notice = null;
    });
    _persistLayout();
  }

  // ── Layout ────────────────────────────────────────────────────────

  /// Responsive column count: 4 columns at ≥120 cols, 2 at 80–119, 1
  /// stacked column below 80. Never scrolls horizontally.
  static int columnsForWidth(int width) {
    if (width >= 120) return 4;
    if (width >= 80) return 2;
    return 1;
  }

  /// The span a widget is laid out at. With [preferred] (the user's
  /// chosen span), it's that span clamped to [columns] and to the
  /// widget's `supportedSpans` — the closest supported span that doesn't
  /// exceed the layout. Without a preference, the largest span in
  /// [HomeWidget.supportedSpans] that fits [columns]. Falls back to the
  /// smallest supported span when nothing fits (e.g. a span-2-only
  /// widget in a 1-column layout renders at span 1 — the widget must
  /// cope).
  static int spanFor(HomeWidget widget, int columns, {int? preferred}) {
    final spans = widget.supportedSpans.toList()..sort();
    if (preferred != null) {
      // Largest supported span that fits both the layout and the
      // preference; if the preference is smaller than every supported
      // span, take the smallest supported one.
      var chosen = spans.first;
      final cap = preferred < columns ? preferred : columns;
      for (final s in spans) {
        if (s <= cap) chosen = s;
      }
      return chosen;
    }
    var chosen = spans.first;
    for (final s in spans) {
      if (s <= columns) chosen = s;
    }
    return chosen;
  }

  /// The smallest cell width (terminal columns, border+padding
  /// included) a *flexible* box tolerates while sharing a row. Below
  /// this a flexible box would rather wrap onto its own row than
  /// render as a sliver — a list box squeezed under ~2 characters
  /// wide shows nothing useful.
  static const _minFlexCellWidth = 12;

  /// Pack placements row-by-row across a grid [gridWidth] terminal
  /// columns wide.
  ///
  /// Boxes are either **rigid** (a positive [HomeWidget.minColumnWidth])
  /// or **flexible** (zero). A rigid box always renders at exactly its
  /// minimum content width and never shrinks, degrades, or drops out;
  /// flexible boxes share whatever width is left on the row. Packing
  /// is a pixel-aware greedy fill:
  ///
  /// * A rigid box joins the current row when its fixed cell width
  ///   still leaves every flexible box on the row at least
  ///   [_minFlexCellWidth]; otherwise it wraps onto a fresh row.
  /// * A flexible box joins the current row while it would get at
  ///   least [_minFlexCellWidth] after the row's rigid boxes are paid
  ///   for; otherwise it wraps.
  ///
  /// [columns] still sets the *flexible* boxes' span arithmetic (a
  /// span-2 flexible box takes twice the width of a span-1 one), and
  /// [HomeWidget.supportedSpans] still caps how wide a flexible box
  /// grows; neither constrains a rigid box's fixed width.
  List<_Row> _packRows(
    List<_Placement> placements,
    int columns,
    int gridWidth,
  ) {
    final rows = <_Row>[];
    var rowWidgets = <HomeWidget>[];
    var rowSpans = <int>[];
    var usedSpan = 0; // flexible span committed to the current row
    var rigidCells = 0; // rigid boxes on the current row
    var rigidPixels = 0; // pixels the rigid cells consume

    int flexiblePixels() => gridWidth - rigidPixels;

    // Pixels a flexible box would get if it joined the current row
    // now (sharing the post-rigid width by span).
    int prospectiveFlexWidth(int addedSpan) {
      final flexBoxes = rowWidgets.length - rigidCells + 1;
      final totalSpan = usedSpan + addedSpan;
      if (flexBoxes <= 0 || totalSpan <= 0) return 0;
      // Approximate an even per-span share of the flexible pixels.
      return flexiblePixels() * addedSpan ~/ totalSpan;
    }

    for (final p in placements) {
      final w = p.widget;
      final minContent = w.minColumnWidth;
      final isRigid = minContent > 0;
      final cellWidth = isRigid ? minContent + 4 : 0;
      final span = spanFor(w, columns, preferred: p.span);

      // Would adding this box overflow the row's span budget, leave
      // the row over-wide, or starve a flexible box? Then wrap first.
      //
      // The span budget keeps a full-span flexible box (e.g. span 4 in
      // 4 columns) on a row of its own instead of sharing it with
      // neighbors, matching the bento-grid intuition that a wider span
      // claims more of the row.
      final newRigidPixels = rigidPixels + cellWidth;
      final overSpan = usedSpan + span > columns;
      final overWide = newRigidPixels > gridWidth;
      final starved = !isRigid &&
          rowWidgets.isNotEmpty &&
          prospectiveFlexWidth(span) < _minFlexCellWidth;
      final rigidStarvesFlex = isRigid &&
          (rowWidgets.length - rigidCells) > 0 &&
          (gridWidth - newRigidPixels) <
              _minFlexCellWidth * (rowWidgets.length - rigidCells);

      if (rowWidgets.isNotEmpty &&
          (overSpan || overWide || starved || rigidStarvesFlex)) {
        rows.add(_Row(rowWidgets, rowSpans));
        rowWidgets = <HomeWidget>[];
        rowSpans = <int>[];
        usedSpan = 0;
        rigidCells = 0;
        rigidPixels = 0;
      }

      rowWidgets.add(w);
      rowSpans.add(isRigid ? 0 : span); // rigid cells don't consume span
      if (isRigid) {
        rigidCells++;
        rigidPixels += cellWidth;
      } else {
        usedSpan += span;
      }
    }
    if (rowWidgets.isNotEmpty) rows.add(_Row(rowWidgets, rowSpans));
    return rows;
  }

  /// Cumulative vertical offset (in terminal rows) of each packed row,
  /// used by auto-scroll to keep the focused box visible. Includes a
  /// 1-row gap between rows.
  List<double> _rowOffsets(List<_Row> rows) {
    final offsets = <double>[];
    var y = 0.0;
    for (final r in rows) {
      offsets.add(y);
      y += r.height + 1;
    }
    return offsets;
  }

  // ── Focus & activation ────────────────────────────────────────────

  /// (row, col) of the focused box, derived from `_focusedIndex` over
  /// the packed rows. The flat index walks rows in order.
  (int, int) _focusedCell(List<_Row> rows) {
    var index = _focusedIndex;
    for (var r = 0; r < rows.length; r++) {
      final cols = rows[r].widgets.length;
      if (index < cols) return (r, index);
      index -= cols;
    }
    return (0, 0);
  }

  /// Move focus to box [newIndex], resetting the newly-focused box's
  /// item selection so a revisited box starts on its first item.
  void _moveFocus(int newIndex, List<_Row> rows) {
    final count = _visibleWidgets.length;
    if (count == 0) return;
    final clamped = newIndex.clamp(0, count - 1);
    setState(() {
      _focusedIndex = clamped;
      _notice = null;
    });
    _visibleWidgets[clamped].resetSelection();
    _ensureFocusedVisible(rows);
  }

  /// Move focus within the current row by [delta] boxes (←→), clamped to
  /// the row's ends. No wraparound: ← on the first box and → on the last
  /// stay put (Tab is the row-to-row affordance).
  void _moveHorizontal(int delta, List<_Row> rows) {
    final (row, col) = _focusedCell(rows);
    final cols = rows[row].widgets.length;
    final targetCol = (col + delta).clamp(0, cols - 1);
    if (targetCol == col) return;
    var index = 0;
    for (var r = 0; r < row; r++) {
      index += rows[r].widgets.length;
    }
    _moveFocus(index + targetCol, rows);
  }

  /// Move focus to the same column in another row, keeping the column
  /// position when possible (used by Tab / Shift+Tab and by ↑↓ falling
  /// through a passive box). [direction] is +1 (down) / -1 (up).
  void _moveRow(int direction, List<_Row> rows) {
    final (row, col) = _focusedCell(rows);
    final targetRow = (row + direction).clamp(0, rows.length - 1);
    if (targetRow == row) return;
    // Land on the same column if it exists in the target row, else the
    // last column of that row.
    final targetCols = rows[targetRow].widgets.length;
    final targetCol = col.clamp(0, targetCols - 1);
    var index = 0;
    for (var r = 0; r < targetRow; r++) {
      index += rows[r].widgets.length;
    }
    _moveFocus(index + targetCol, rows);
  }

  /// ↑↓ — select within the focused box when it has items; otherwise
  /// (passive box) move to the next row. Edit mode uses this to reach a
  /// box on another row, so it always moves rows there.
  void _moveVertical(int direction, List<_Row> rows, {bool forceRow = false}) {
    final visible = _visibleWidgets;
    if (visible.isEmpty) return;
    final widget = visible[_focusedIndex.clamp(0, visible.length - 1)];
    if (!forceRow && widget.itemCount > 0) {
      setState(() {
        widget.moveSelection(direction);
        _notice = null;
      });
      return;
    }
    _moveRow(direction, rows);
  }

  void _ensureFocusedVisible(List<_Row> rows) {
    final (row, _) = _focusedCell(rows);
    final offsets = _rowOffsets(rows);
    if (row >= offsets.length) return;
    _scrollController.ensureVisible(
      itemOffset: offsets[row],
      itemExtent: rows[row].height.toDouble(),
    );
  }

  /// Enter — activate the focused box's selected item (item boxes) or
  /// its whole-box action (passive boxes).
  void _activateFocused() {
    final widgets = _visibleWidgets;
    if (widgets.isEmpty) return;
    final widget = widgets[_focusedIndex.clamp(0, widgets.length - 1)];
    final action = widget.itemCount > 0
        ? widget.activateItem(_ctx, widget.selectedIndex)
        : widget.activate(_ctx);
    if (action == null) return; // passive box: no-op
    action();
  }

  // ── Keys ──────────────────────────────────────────────────────────

  bool _handleKey(KeyboardEvent event) {
    final rows = _packedRowsCache ?? const <_Row>[];
    final key = event.logicalKey;

    // ── Ctrl+C — quit, in any mode ──
    // The whole app has `CtrlCBehavior.disabled`, so nocterm itself
    // won't exit on Ctrl+C. The chat input handles it for the chat
    // screen; the home screen must handle it here too — otherwise Ctrl+C
    // is swallowed by the `return true` at the bottom and the user is
    // trapped. Routes through `quitApp` (QuitHandler → run summary +
    // clean teardown), the same exit path as `/quit` and the chat's
    // Ctrl+C. Falls back to `quitNow` (hard exit) when no handler is
    // wired (defensive — production always wires one).
    if (key == LogicalKey.keyC && event.isControlPressed) {
      final quit = component.quitApp ?? component.quitNow;
      if (quit != null) quit();
      return true;
    }

    // ── Edit-mode key scope ──
    // Distinct from navigation: arrows reorder, `-`/`=` resize, `x`
    // hides, `a` re-adds, `e`/`esc` exits back to navigation. Handled
    // first so the same physical keys mean different things per mode.
    if (_editing) {
      if (key == LogicalKey.escape || key == LogicalKey.keyE) {
        _toggleEdit();
        return true;
      }
      if (key == LogicalKey.arrowLeft) {
        _editMove(-1);
        return true;
      }
      if (key == LogicalKey.arrowRight) {
        _editMove(1);
        return true;
      }
      if (key == LogicalKey.minus) {
        _editResize(-1);
        return true;
      }
      if (key == LogicalKey.equal) {
        _editResize(1);
        return true;
      }
      if (key == LogicalKey.keyX) {
        _editHide();
        return true;
      }
      if (key == LogicalKey.keyA) {
        _editAdd();
        return true;
      }
      // Up/down still move focus between rows in edit mode (so you can
      // reach a box on another row to edit it), but PgUp/PgDn/Home/End/
      // enter are swallowed — you can't activate or leave while editing.
      if (key == LogicalKey.arrowUp) {
        _moveVertical(-1, rows, forceRow: true);
        return true;
      }
      if (key == LogicalKey.arrowDown) {
        _moveVertical(1, rows, forceRow: true);
        return true;
      }
      return true; // swallow everything else while editing
    }

    // ── Normal-mode key scope ──
    if (key == LogicalKey.escape) {
      component.onExit();
      return true;
    }
    if (key == LogicalKey.keyE) {
      _toggleEdit();
      return true;
    }
    // ←→ switch the focused box within its row.
    if (key == LogicalKey.arrowLeft) {
      _moveHorizontal(-1, rows);
      return true;
    }
    if (key == LogicalKey.arrowRight) {
      _moveHorizontal(1, rows);
      return true;
    }
    // `[` / `]` press the focused box's title buttons: `[` runs the
    // first (‹ = back / older), `]` the last (› = forward / latest) —
    // the keyboard twin of clicking the title-row buttons. No-op (but
    // still consumed) when the focused box has no title buttons.
    if (key == LogicalKey.bracketLeft || key == LogicalKey.bracketRight) {
      final widgets = _visibleWidgets;
      if (widgets.isNotEmpty) {
        final widget = widgets[_focusedIndex.clamp(0, widgets.length - 1)];
        final buttons = widget.titleButtons;
        if (buttons != null && buttons.isNotEmpty) {
          final action =
              key == LogicalKey.bracketLeft ? buttons.first : buttons.last;
          action.onPressed?.call();
        }
      }
      return true;
    }
    // ↑↓ select items inside the focused box; on a passive box (no
    // items) they fall through to row navigation.
    if (key == LogicalKey.arrowUp) {
      _moveVertical(-1, rows);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      _moveVertical(1, rows);
      return true;
    }
    // Tab / Shift+Tab jump to the next / previous row, same column.
    if (key == LogicalKey.tab) {
      _moveRow(event.isShiftPressed ? -1 : 1, rows);
      return true;
    }
    if (key == LogicalKey.pageUp) {
      _scrollController.scrollUp(_scrollController.viewportDimension);
      return true;
    }
    if (key == LogicalKey.pageDown) {
      _scrollController.scrollDown(_scrollController.viewportDimension);
      return true;
    }
    if (key == LogicalKey.home) {
      _scrollController.jumpTo(0);
      return true;
    }
    if (key == LogicalKey.end) {
      _scrollController.jumpTo(_scrollController.maxScrollExtent);
      return true;
    }
    if (key == LogicalKey.enter) {
      _activateFocused();
      return true;
    }
    // Consume every other key — home is the only screen up, so nothing
    // else should react to input while it's open.
    return true;
  }

  // The packed rows for the current build, cached so the key handler
  // (which runs outside build) navigates the same layout that's on
  // screen.
  List<_Row>? _packedRowsCache;

  /// The widgets actually on screen, derived from the packed rows each
  /// build. Differs from `_widgets` (the placement list) when a box is
  /// dropped because the window is too narrow for its
  /// [HomeWidget.minColumnWidth]: focus and activation walk this list
  /// so a hidden box is unreachable.
  List<HomeWidget> _visibleWidgets = const [];

  // ── Quick-chat input ──────────────────────────────────────────────

  bool get _hasFullInput =>
      component.overlayController != null &&
      component.inputController != null &&
      component.inputOverlay != null &&
      component.inputKeyHandler != null;

  Component _quickChatArea(CruxThemeData theme) {
    // The full input path re-airs its own rebuilds through the local
    // state below (see _QuickChatArea); the fallback field keeps
    // home's setState (it's one Text + the local controller, cheap).
    return _QuickChatArea(
      hasFullInput: _hasFullInput,
      overlayController: component.overlayController,
      inputController: component.inputController,
      inputOverlay: component.inputOverlay,
      inputKeyHandler: component.inputKeyHandler,
      maxVisibleItems: component.maxVisibleItems,
      fallbackController: _chatController,
      strings: _ctx.strings,
      onSubmit: _submitChat,
      onKey: _handleKey,
      onMounted: component.onQuickChatAreaMounted,
      theme: theme,
    );
  }

  void _submitChat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final ok = component.onStartChat?.call(trimmed);
    if (ok == null || !ok) return; // no starter wired, or refused mid-stream
    _chatController.clear();
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    _syncPluginBoxes();
    final theme = CruxTheme.of(context);
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Container(
        color: theme.background,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Hero header ──
            // Logo on the left; an info column on the right fills the
            // wide-screen dead space with the launch facts (version,
            // date, workspace, branch) — the same "where am I" answer
            // the dashboard below elaborates.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in _logo)
                      Text(line, style: TextStyle(color: theme.accent)),
                  ],
                ),
                const SizedBox(width: 3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'v$kCruxVersion',
                          style: TextStyle(color: theme.onSurfaceDim),
                        ),
                        // Edit-mode marker: a hidden modal mode is a
                        // usability trap, so editing is announced right
                        // in the hero.
                        if (_editing)
                          Text(
                            '  [${_ctx.strings.t('home.editing')}]',
                            style: TextStyle(
                              color: theme.warningColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    Text(
                      _formatDate(DateTime.now(), _ctx.strings),
                      style: TextStyle(color: theme.onSurfaceDim),
                    ),
                    // Workspace dir — omitted when the launch has no
                    // project (e.g. tests), since the workspace box
                    // already says "(unknown)" and an empty hero line
                    // would just repeat it.
                    if (_ctx.projectPath.isNotEmpty)
                      Text(
                        _workspaceLine(),
                        style: TextStyle(color: theme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      _branchLine(),
                      style: TextStyle(color: theme.onSurfaceDim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 1),

            // ── Dashboard grid ──
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth.isFinite
                      ? constraints.maxWidth.floor()
                      : 120;
                  final columns = columnsForWidth(width);
                  final rows = _packRows(_placements, columns, width);
                  _packedRowsCache = rows;
                  // Visible widgets come from the packed rows, not the
                  // placement list: a box dropped for lack of width is
                  // out of rendering AND keyboard navigation.
                  _visibleWidgets = [
                    for (final row in rows) ...row.widgets,
                  ];
                  // The focused box may have just dropped out (window
                  // narrowed past its min width) — clamp the index so
                  // navigation never points at a hidden box.
                  if (_focusedIndex >= _visibleWidgets.length) {
                    _focusedIndex =
                        (_visibleWidgets.length - 1).clamp(0, 1 << 30);
                  }
                  return _buildGrid(
                    context,
                    theme,
                    rows,
                    width,
                    columns,
                  );
                },
              ),
            ),

            // ── Quick-chat input (+ overlay popover) ──
            // A one-line field to start a fresh Chat conversation, with
            // the slash / @ / # / $ popover stacked above it. One
            // self-contained component that rebuilds ITSELF on typing —
            // a keystroke never re-lays-out the whole dashboards grid.
            // Hidden during edit mode (edit mode owns the keyboard).
            if (!_editing) _quickChatArea(theme),
            const SizedBox(height: 1),

            // ── Key-hint footer ──
            if (_notice != null)
              Text(_notice!, style: TextStyle(color: theme.errorColor))
            else if (_editing)
              Text(
                _ctx.strings.t('home.footerEdit'),
                style: TextStyle(color: theme.warningColor),
              )
            else
              Text(
                _ctx.strings.t('home.footerNav'),
                style: TextStyle(color: theme.hintText),
              ),
          ],
        ),
      ),
    );
  }

  Component _buildGrid(
    BuildContext context,
    CruxThemeData theme,
    List<_Row> rows,
    int width,
    int columns,
  ) {
    // Flat index of each box, walking rows in order, to know which is
    // focused.
    var flatIndex = 0;
    final rowOffsets = _rowOffsets(rows);
    final rowComponents = <Component>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final cells = <Component>[];
      // Rigid boxes (a positive minColumnWidth) take a fixed pixel
      // width and never shrink; the flexible boxes split what's left
      // by their span. First pass: total flexible span and the pixels
      // the rigid cells consume (minColumnWidth is a *content* width;
      // the cell adds border 2 + horizontal padding 2).
      var flexSpan = 0;
      var rigidPixels = 0;
      for (var c = 0; c < row.widgets.length; c++) {
        final w = row.widgets[c];
        if (w.minColumnWidth > 0) {
          rigidPixels += w.minColumnWidth + 4;
        } else {
          flexSpan += row.spans[c];
        }
      }
      final flexPixels = (width - rigidPixels).clamp(0, width);
      for (var c = 0; c < row.widgets.length; c++) {
        final index = flatIndex++;
        final widget = row.widgets[c];
        final span = row.spans[c];
        final box = _buildBox(
          context,
          theme,
          widget,
          span,
          row.height,
          index == _focusedIndex,
          index,
          rowOffsets[r],
        );
        if (widget.minColumnWidth > 0) {
          // Rigid box: a fixed cell width it never shrinks below.
          cells.add(
            SizedBox(
              width: (widget.minColumnWidth + 4).toDouble(),
              child: box,
            ),
          );
        } else {
          // Flexible box: its span's share of the pixels left over.
          cells.add(
            SizedBox(
              width: flexSpan > 0 ? (flexPixels * span / flexSpan) : 0,
              child: box,
            ),
          );
        }
      }
      rowComponents.add(
        Container(
          height: row.height.toDouble(),
          margin: const EdgeInsets.only(bottom: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rowComponents,
      ),
    );
  }

  /// One bordered box: rounded border (active color when focused),
  /// title in the border, widget content inside, and click/hover
  /// handling. Stretched to the row height by the parent's `Row`.
  ///
  /// [scrollContentRow] is the box's y offset within the scroll viewport's
  /// content (from [_rowOffsets]); the box MouseRegion's hover handler
  /// uses it — plus the scroll offset and the fixed hero height above the
  /// viewport — to map the cursor's terminal y to a row index.
  Component _buildBox(
    BuildContext context,
    CruxThemeData theme,
    HomeWidget widget,
    int span,
    int height,
    bool focused,
    int index,
    double scrollContentRow,
  ) {
    final borderColor = focused ? theme.borderActive : theme.outline;
    final titleColor = focused ? theme.accent : theme.onSurfaceVariant;
    // A box is actionable when it has selectable items (Enter/click act
    // on one) or a whole-box action (passive-but-clickable, e.g. git).
    final hasItems = widget.itemCount > 0;
    final boxAction = widget.activate(_ctx);

    // A box with title buttons renders its title as a real component
    // row: the buttons need hover + tap, which the painted border title
    // can't host (it's painted into the border cells at paint time).
    // The title row takes one content row — budgeted in `_Row.height` —
    // and the border above it paints as a plain line.
    final titleButtons = widget.titleButtons;
    final hasTitleButtons = titleButtons != null && titleButtons.isNotEmpty;

    final boxContent = Container(
      height: height.toDouble(),
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder.all(
          color: borderColor,
          style: BoxBorderStyle.rounded,
        ),
        title: hasTitleButtons
            ? null
            : BorderTitle(
                text: widget.titleFor(_ctx),
                style: TextStyle(
                  color: titleColor,
                  fontWeight: focused ? FontWeight.bold : null,
                ),
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      // EVERY box's content lives inside a scrollview: the scrollview's
      // paint clips to the viewport, so no content can ever paint past
      // the border — a too-tall box scrolls instead of overflowing, and
      // the scrollbar thumb signals it. Passive boxes (git, tokens,
      // workspace) still center their short summaries vertically inside
      // the scroll area so a 1-line status doesn't hug the top of a
      // stretched box. Item-list boxes stay top-aligned (their
      // hover/click row math assumes content starts at row 0), and so
      // do boxes that opt out via [HomeWidget.verticallyCenter] — a
      // content list like Yesterday must keep top alignment for the
      // scroll to read naturally.
      child: hasTitleButtons
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titleRow(theme, widget, titleButtons, focused),
                Expanded(
                  child: _BoxScrollArea(
                    owner: widget,
                    child: _boxContent(context, widget, span, focused),
                  ),
                ),
              ],
            )
          : _BoxScrollArea(
              owner: widget,
              child: _boxContent(context, widget, span, focused),
            ),
    );

    // Hover-focus lives on a non-opaque MouseRegion so it never blocks
    // clicks from reaching the content. onHover additionally maps the
    // cursor to an item row for item-list boxes (per-row MouseRegions
    // never receive hover under a wrapping region in nocterm, so the
    // row lookup happens here instead).
    final hoverable = MouseRegion(
      onEnter: (_) {
        if (_focusedIndex != index) {
          setState(() {
            _focusedIndex = index;
            _notice = null;
          });
        }
      },
      onHover: (event) {
        if (!hasItems) return;
        // Terminal y of the box content's first row:
        //   viewport top (hero) − scroll offset + box's scroll-content
        //   row + 1 border row.
        final firstContentY =
            _kAboveViewport - _scrollController.offset + scrollContentRow + 1;
        // The box content is itself scrollable now — the cursor's
        // viewport row maps to the absolute item index through the
        // box's own scroll offset.
        final row =
            (event.y - firstContentY).round() + widget.boxScrollOffset;
        if (row < 0 || row >= widget.itemCount) return;
        // selectItemAt reports whether the highlight actually moved
        // (the same-index short-circuit inside the widgets keeps a
        // sweep along one row free). Rebuild only when the selection
        // or the focused box changed — mouse motion that changes
        // nothing must not schedule frames at all, or hover feels
        // laggy under a burst of motion events.
        final selectionChanged = widget.selectItemAt(row);
        final focusChanged = _focusedIndex != index;
        if (!selectionChanged && !focusChanged) return;
        setState(() {
          if (focusChanged) _focusedIndex = index;
          _notice = null;
        });
      },
      opaque: false,
      child: boxContent,
    );

    // Only a passive / whole-action box (git, tokens, …) needs a
    // box-level click routed to its action. An item-list box
    // (quick-actions, recent-sessions) must NOT carry an opaque
    // GestureDetector here: it would shadow the rows' own taps (the
    // tap arena auto-accepts on pointer-up, and an opaque ancestor swallows
    // the child hit), making mouse clicks either no-op or fire the wrong
    // (focused) item. Hover-focus + the rows' own detectors suffice for
    // item boxes; focus/selection is set by the row tap itself.
    if (hasItems || boxAction == null) {
      return hoverable;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _focusedIndex = index;
          _notice = null;
        });
        final action = widget.activate(_ctx);
        if (action != null) action();
      },
      child: hoverable,
    );
  }

  /// The widget's rendered content, vertically centered when the box is
  /// passive and opts in ([HomeWidget.verticallyCenter]). Extracted so
  /// the title-button and plain-border box chrome share one path.
  Component _boxContent(
    BuildContext context,
    HomeWidget widget,
    int span,
    bool focused,
  ) {
    final hasItems = widget.itemCount > 0;
    return hasItems || !widget.verticallyCenter
        ? widget.build(context, _ctx, span, focused: focused)
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.build(context, _ctx, span, focused: focused),
            ],
          );
  }

  /// The interactive title row for a box with [HomeWidget.titleButtons]:
  /// the title text (styled like the painted border title) followed by
  /// the buttons. Buttons render as the shared [Button] component —
  /// hover raises their background, click fires [HomeTitleButton
  /// .onPressed]. A button with a null callback renders as a dimmed,
  /// inert label (taps ignored), matching the disabled look of the
  /// painted title.
  Component _titleRow(
    CruxThemeData theme,
    HomeWidget widget,
    List<HomeTitleButton> buttons,
    bool focused,
  ) {
    final titleColor = focused ? theme.accent : theme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.titleFor(_ctx),
          style: TextStyle(
            color: titleColor,
            fontWeight: focused ? FontWeight.bold : null,
          ),
        ),
        for (final button in buttons)
          if (button.onPressed == null)
            Text(
              ' ${button.label} ',
              style: TextStyle(color: theme.buttonTextDisabled),
            )
          else
            Button(
              label: button.label,
              onPressed: button.onPressed,
              color: theme.onSurfaceVariant,
              hoverColor: theme.buttonTextHover,
              padding: const EdgeInsets.symmetric(horizontal: 1),
            ),
      ],
    );
  }
}

/// The quick-chat input area: the overlay popover (slash / @ / # / $
/// completion) stacked above the one-line "start a new chat" field.
///
/// Self-contained statefulness: everything that changes while typing —
/// the text, the cursor, the popover rows — is repainted by THIS
/// component's own setState, never by the home screen's. This is a
/// performance boundary, not a style choice: home's build re-runs
/// every box widget (~10 boxes, worst case ~26ms of layout on a single
/// rebuild) and a keystroke used to trigger exactly that through the
/// panel-wide `_refresh` callback. Key events that belong to the grid
/// (navigation while the field is empty) bounce back out via [onKey]
/// to `_HomeScreenState._handleKey`, which re-renders the grid as
/// before.
class _QuickChatArea extends StatefulComponent {
  /// Whether the full-featured input is wired (controller / overlay /
  /// key handler from the chat panel). False in tests/previews → the
  /// plain local-controller field renders.
  final bool hasFullInput;

  final OverlayController? overlayController;
  final TextEditingController? inputController;
  final InputOverlay? inputOverlay;
  final InputKeyHandler? inputKeyHandler;
  final int maxVisibleItems;

  /// Home's local controller — used when [inputController] is null.
  final TextEditingController fallbackController;

  final Strings strings;

  /// Submit on Enter (full path submits via [inputKeyHandler]; this
  /// covers the fallback field's own `onSubmitted`).
  final void Function(String text) onSubmit;

  /// Grid key handler for empty-field navigation keys.
  final bool Function(KeyboardEvent event) onKey;

  /// Rebuild hook for the chat panel: the panel swaps the
  /// InputOverlay/InputKeyHandler `refresh` to this component's local
  /// setState, so typing rebuilds only this subtree. Cleared on
  /// unmount.
  final void Function(VoidCallback rebuild)? onMounted;

  final CruxThemeData theme;

  const _QuickChatArea({
    required this.hasFullInput,
    required this.overlayController,
    required this.inputController,
    required this.inputOverlay,
    required this.inputKeyHandler,
    required this.maxVisibleItems,
    required this.fallbackController,
    required this.strings,
    required this.onSubmit,
    required this.onKey,
    required this.onMounted,
    required this.theme,
  });

  @override
  State<_QuickChatArea> createState() => _QuickChatAreaState();
}

class _QuickChatAreaState extends State<_QuickChatArea> {
  void _localRebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    component.onMounted?.call(_localRebuild);
  }

  @override
  void dispose() {
    component.onMounted?.call(() {});
    super.dispose();
  }

  /// The quick-chat field keeps home's keyboard shortcuts working while
  /// it's empty: arrows / Tab / PgUp / PgDn / Home / End / Enter / `e` /
  /// `[` / `]` are delegated to the grid's key handler for navigation,
  /// edit mode, and box activation. Once the user has typed something,
  /// the field owns the keyboard (typing, cursor, Enter to submit).
  ///
  /// With the full-featured input wired, empty-field nav keys still go
  /// to the grid; every other key goes to the [InputKeyHandler] (overlay
  /// navigation, command mode, chip backspace, Enter to submit).
  bool _keyHandler(KeyboardEvent event) {
    final keyHandler = component.inputKeyHandler;
    final controller = component.inputController;
    if (keyHandler != null && controller != null) {
      if (controller.text.isEmpty) {
        final key = event.logicalKey;
        switch (key) {
          case LogicalKey.arrowUp:
          case LogicalKey.arrowDown:
          case LogicalKey.arrowLeft:
          case LogicalKey.arrowRight:
          case LogicalKey.tab:
          case LogicalKey.pageUp:
          case LogicalKey.pageDown:
          case LogicalKey.home:
          case LogicalKey.end:
          case LogicalKey.enter:
          case LogicalKey.keyE:
          case LogicalKey.bracketLeft:
          case LogicalKey.bracketRight:
            return component.onKey(event);
          default:
            break;
        }
      }
      return keyHandler.handleKeyEvent(event);
    }

    if (component.fallbackController.text.isNotEmpty) return false;
    final key = event.logicalKey;
    switch (key) {
      case LogicalKey.arrowUp:
      case LogicalKey.arrowDown:
      case LogicalKey.arrowLeft:
      case LogicalKey.arrowRight:
      case LogicalKey.tab:
      case LogicalKey.pageUp:
      case LogicalKey.pageDown:
      case LogicalKey.home:
      case LogicalKey.end:
      case LogicalKey.enter:
      case LogicalKey.keyE:
      case LogicalKey.bracketLeft:
      case LogicalKey.bracketRight:
        return component.onKey(event);
      default:
        return false;
    }
  }

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final controller =
        component.inputController ?? component.fallbackController;
    final styleSegments = component.hasFullInput
        ? buildInputChipSegments(
            text: controller.text,
            mentionChips: component.overlayController!.mentionChips,
            theme: theme,
            baseStyle: TextStyle(color: theme.foreground),
          )
        : null;

    final children = <Component>[
      LayoutBuilder(
        builder: (context, constraints) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: theme.surface,
              border: BoxBorder.all(
                color: theme.accent,
                style: BoxBorderStyle.rounded,
              ),
              title: BorderTitle(
                text: component.strings.t('home.newChat'),
                style: TextStyle(
                  color: theme.accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            child: Row(
              children: [
                Text('> ', style: TextStyle(color: theme.onSurfaceDim)),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focused: true,
                    maxLines: 1,
                    style: TextStyle(color: theme.foreground),
                    placeholder: component.strings.t('home.newChatPlaceholder'),
                    styleSegments: styleSegments,
                    onSubmitted: component.onSubmit,
                    onKeyEvent: _keyHandler,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ];

    // Popover above the field (bottom-up column: field first, popover
    // unshifts above it via the parent Column ordering — matches the
    // old `[..._popover(), field]` order by rebuilding the column with
    // the popover as a leading child when active).
    if (component.hasFullInput) {
      final popover = buildOverlayPopover(
        overlay: component.overlayController!,
        maxVisible: component.maxVisibleItems,
        strings: component.strings,
        refresh: _localRebuild,
      );
      if (popover != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [popover, const SizedBox(height: 1), ...children],
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// A box's scrollable content area. Wraps the widget's content in a
/// `Scrollbar + SingleChildScrollView`: the scrollview's paint clips
/// to the viewport, so content taller than the box scrolls instead of
/// painting past the border, and the scrollbar thumb signals it. The
/// current scroll offset is mirrored back to the owning widget via
/// [HomeWidget.boxScrollOffset] so home's box-level hover math can
/// translate a viewport row into an absolute item index.
class _BoxScrollArea extends StatefulComponent {
  final HomeWidget owner;
  final Component child;

  const _BoxScrollArea({required this.owner, required this.child});

  @override
  State<_BoxScrollArea> createState() => _BoxScrollAreaState();
}

class _BoxScrollAreaState extends State<_BoxScrollArea> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // Mirror the scroll offset back to the owning widget so home's
    // box-level hover math (viewport row → absolute item index) stays
    // correct once the list is scrolled.
    _controller.addListener(() {
      component.owner.boxScrollOffset = _controller.offset.round();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the selected item visible: when ↑↓ moves the selection
        // past the last visible row, scroll so it stays in view. Only
        // item boxes need this (passive boxes have no selection).
        final owner = component.owner;
        if (owner.itemCount > 0 && constraints.maxHeight.isFinite) {
          final viewport = constraints.maxHeight.floor();
          final selected = owner.selectedIndex;
          var first = _controller.offset.round();
          if (selected < first) {
            first = selected;
          } else if (selected > first + viewport - 1) {
            first = selected - viewport + 1;
          }
          first = first.clamp(0, (owner.itemCount - viewport).clamp(0, owner.itemCount));
          if (_controller.offset.round() != first) {
            _controller.jumpTo(first.toDouble());
          }
        }
        return Scrollbar(
          controller: _controller,
          thumbColor: theme.onSurfaceDim.withOpacity(0.4),
          trackColor: theme.surfaceVariant.withOpacity(0.3),
          child: SingleChildScrollView(
            controller: _controller,
            child: component.child,
          ),
        );
      },
    );
  }
}

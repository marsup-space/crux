import 'package:nocterm/nocterm.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../theme/crux_theme.dart';
import '../../services/skills/skill_discovery.dart';
import '../../version.dart';
import 'home_layout_store.dart';
import 'home_widgets.dart';
import 'widgets/activity_widget.dart';
import 'widgets/quick_actions_widget.dart';
import 'widgets/recent_sessions_widget.dart';
import 'widgets/skills_widget.dart';
import 'widgets/tokens_widget.dart';
import 'widgets/notes_widget.dart';
import 'widgets/workspace_widget.dart';
import 'widgets/yesterday_widget.dart';

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

  const HomeScreen({
    super.key,
    required this.onExit,
    this.widgets,
    this.context_,
    this.initialLayout,
    this.onLayoutChanged,
    this.quitApp,
    this.quitNow,
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
      final wh = widgets[i].heightFor(spans[i]) + 2; // + border rows
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

  static const _weekdays = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Rows above the scroll viewport: container top padding (1) + hero
  /// block (5 logo rows; the info column shares them) + gap (1). The box
  /// hover handler uses this to map the cursor's terminal y to a content
  /// row.
  static const double _kAboveViewport = 1 + 5 + 1;

  final _scrollController = ScrollController();

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
    _allById = {for (final w in _defaultWidgets()) w.id: w};
    _placements = _resolvePlacements();
  }

  /// The ordered, span-tagged placements shown in the grid. Built once
  /// from the default order + [HomeScreen.initialLayout]; mutated by
  /// edit mode. The single source of truth for what's on screen and in
  /// what order.
  late List<_Placement> _placements;

  /// Every widget the grid could show, keyed by id — the union of the
  /// visible placements and the hidden ones available for re-add.
  late Map<String, HomeWidget> _allById;

  /// The default widgets for this screen (the five built-ins, or the
  /// caller-supplied list). Order is the default layout order.
  List<HomeWidget> _defaultWidgets() {
    if (component.widgets != null) return component.widgets!;
    final ctx = _ctx;
    return [
      WorkspaceHomeWidget(),
      QuickActionsHomeWidget(seedInput: ctx.seedInput),
      // The three span-1 boxes sit together and fill one row.
      TokensHomeWidget(),
      ActivityHomeWidget(),
      SkillsHomeWidget(skills: () => discoverSkills(cwd: _ctx.projectPath)),
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
    ];
  }

  HomeContext get _ctx =>
      component.context_ ?? HomeContext.minimal(close: component.onExit);

  // ── Hero info lines ─────────────────────────────────────────────

  static String _formatDate(DateTime d) =>
      '${_weekdays[d.weekday - 1]} ${_months[d.month - 1]} ${d.day}';

  /// Workspace fact for the hero: the project directory basename,
  /// mirroring the workspace box's `dir` line but shorter.
  String _workspaceLine() {
    final path = _ctx.projectPath;
    if (path.isEmpty) return '(no workspace)';
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }

  /// Branch fact for the hero — dimmed, and honest when there's no repo.
  String _branchLine() {
    final status = _ctx.gitStatusService.current;
    if (!status.isRepo) return 'not a git repo';
    final branch = status.branch.isEmpty ? '(no branch)' : status.branch;
    return '⎇ $branch';
  }

  @override
  void initState() {
    super.initState();
    _allById = {for (final w in _defaultWidgets()) w.id: w};
    _placements = _resolvePlacements();
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

  List<HomeWidget> get _widgets =>
      [for (final p in _placements) p.widget];

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
      setState(() => _notice = 'this box has a fixed size');
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
      setState(() => _notice = 'keep at least one box');
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
      setState(() => _notice = 'no hidden boxes');
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

  /// Pack placements row-by-row into [columns] columns. Each box prefers
  /// its chosen [ _Placement.span] (clamped to the column count and to
  /// what the widget supports), degrading gracefully to fit the
  /// *remaining* space in the current row rather than overflowing it. It
  /// wraps to a fresh row only when even the box's smallest span doesn't
  /// fit the remaining space.
  List<_Row> _packRows(List<_Placement> placements, int columns) {
    final rows = <_Row>[];
    var rowWidgets = <HomeWidget>[];
    var rowSpans = <int>[];
    var used = 0;
    for (final p in placements) {
      final w = p.widget;
      // The box's preferred span: its chosen span, but never wider than
      // the layout allows or than the widget supports.
      var span = spanFor(w, columns, preferred: p.span);
      final minSpan = w.supportedSpans.reduce((a, b) => a < b ? a : b);
      // Wrap only when the box can't fit the remaining space even at its
      // smallest span; otherwise degrade the span to fit.
      if (used + span > columns && used + minSpan > columns && rowWidgets.isNotEmpty) {
        rows.add(_Row(rowWidgets, rowSpans));
        rowWidgets = <HomeWidget>[];
        rowSpans = <int>[];
        used = 0;
        span = spanFor(w, columns, preferred: p.span);
      } else if (used + span > columns) {
        span = columns - used; // degrade to fill the remaining space
      }
      rowWidgets.add(w);
      rowSpans.add(span);
      used += span;
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
    final count = _widgets.length;
    if (count == 0) return;
    final clamped = newIndex.clamp(0, count - 1);
    setState(() {
      _focusedIndex = clamped;
      _notice = null;
    });
    _widgets[clamped].resetSelection();
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
    final widget = _widgets[_focusedIndex.clamp(0, _widgets.length - 1)];
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
    final widgets = _widgets;
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

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
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
                            '  [editing]',
                            style: TextStyle(
                              color: theme.warningColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    Text(
                      _formatDate(DateTime.now()),
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
                  final rows = _packRows(_placements, columns);
                  _packedRowsCache = rows;
                  return _buildGrid(
                    context,
                    theme,
                    _widgets,
                    rows,
                    width,
                    columns,
                  );
                },
              ),
            ),

            // ── Key-hint footer ──
            if (_notice != null)
              Text(_notice!, style: TextStyle(color: theme.errorColor))
            else if (_editing)
              Text(
                '←→ reorder · -/= resize · x hide · a add · e/esc done',
                style: TextStyle(color: theme.warningColor),
              )
            else
              Text(
                '↑↓ select · ←→ box · tab row · enter open · e edit · esc chat',
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
    List<HomeWidget> widgets,
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
      for (var c = 0; c < row.widgets.length; c++) {
        final index = flatIndex++;
        final widget = row.widgets[c];
        final span = row.spans[c];
        cells.add(
          Expanded(
            flex: span,
            child: _buildBox(
              context,
              theme,
              widget,
              span,
              row.height,
              index == _focusedIndex,
              index,
              rowOffsets[r],
            ),
          ),
        );
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

    final boxContent = Container(
      height: height.toDouble(),
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder.all(
          color: borderColor,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle(
          text: widget.title,
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
      child: _BoxScrollArea(
        owner: widget,
        child: hasItems || !widget.verticallyCenter
            ? widget.build(context, _ctx, span, focused: focused)
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  widget.build(context, _ctx, span, focused: focused),
                ],
              ),
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
        var changed = widget.selectItemAt(row);
        if (changed && _focusedIndex != index) {
          _focusedIndex = index;
          changed = true;
        }
        if (changed) {
          setState(() {
            _notice = null;
          });
        }
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

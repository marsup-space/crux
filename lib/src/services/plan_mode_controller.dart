import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../components/tool_detail_utils.dart';
import '../components/ui/markdown_isolate.dart' show MarkdownThemeFields;
import '../markdown/plan_markdown_parser.dart';
import '../models/plan_selection.dart';
import '../models/session_runtime_state.dart';
import 'plan_doc_store.dart';

/// Default plan document name created by `/plan` with no argument.
const kDefaultPlanDocName = 'PLAN.md';

/// Skeleton written when the plan file doesn't exist yet.
const kPlanDocSkeleton = '# Plan\n\n';

/// Per-session owner of all plan-mode state (design doc §4).
///
/// One instance per `ChatPanel` (the design says "keyed on session id";
/// the controller re-keys itself when the session changes — see
/// [attachSession]). The pane ([PlanDocPane]) is a dumb renderer of this
/// controller; every mutation goes through here and [notifyListeners].
///
/// Two external couplings:
///   - [onFileChanged] — notified by ChatPanel whenever the plan doc's
///     on-disk content may have changed (enter, agent edit, revert), so
///     the panel can refresh derived state.
///   - [runtimeFor] — resolves the current session's
///     [SessionRuntimeState] so [planDocPath] can be mirrored there for
///     the tool guards and the per-turn system-prompt block (§5 P6). The
///     plan-mode instruction is injected per-turn by `chat_turn_executor`
///     (layered on the resolved prompt, never persisted), so no prompt
///     rebuild is needed on enter/exit.
class PlanModeController extends ChangeNotifier {
  PlanModeController({
    MarkdownThemeFields? theme,
    this.onFileChanged,
    this.runtimeFor,
    this.runtimeById,
  }) : _theme = theme;

  /// Theme used by the parser for span styles. Settable because the
  /// theme object is only available at build time in the pane; the
  /// controller parses lazily and re-parses when this changes.
  MarkdownThemeFields? _theme;
  MarkdownThemeFields? get theme => _theme;
  set theme(MarkdownThemeFields? value) {
    if (identical(value, _theme)) return;
    _theme = value;
    if (_active) _reparse();
  }

  /// Called whenever the plan doc's on-disk content may have changed
  /// (enter, agent edit, revert). ChatPanel uses it to refresh derived
  /// state.
  final void Function()? onFileChanged;

  /// Resolves the current session's runtime so [planDocPath] can be
  /// mirrored into `SessionRuntimeState` (the tool guards read it from
  /// there — §5 P6).
  final SessionRuntimeState? Function()? runtimeFor;

  /// Resolves ANY session's runtime by id — needed by session-bound
  /// plan state: [attachSession] reads the incoming session's plan
  /// mirror to decide reopen-vs-collapse and writes the outgoing
  /// session's saved view state. Null in tests (the
  /// `_runtimeForId` fallback then degrades gracefully).
  final SessionRuntimeState? Function(int sessionId)? runtimeById;

  // ── Core state ────────────────────────────────────────────────────

  bool _active = false;
  bool get active => _active;

  String? _planDocPath;
  String? get planDocPath => _planDocPath;

  /// Whether the plan has been approved (design doc §5 P6): while
  /// approved the pane stays visible (and [planDocPath] stays non-null)
  /// but the edit/write/shell plan-mode guards are lifted so the agent
  /// can implement the plan. Unapproving re-arms the guards. This is a
  /// separate flag from [planDocPath] — nulling the path to lift the
  /// guards would also collapse the pane, which is the opposite of
  /// "keep the doc visible while editing".
  bool _approved = false;
  bool get approved => _approved;

  PlanViewMode _viewMode = PlanViewMode.follow;
  PlanViewMode get viewMode => _viewMode;

  String _docText = '';
  String get docText => _docText;

  PlanParseResult _parsed = PlanParseResult.empty;
  PlanParseResult get parsed => _parsed;

  final ScrollController scrollController = ScrollController();
  double lastFreeScrollOffset = 0.0;

  PlanSelection? _selection;
  PlanSelection? get selection => _selection;

  final List<FlashRegion> activeFlashes = [];

  PlanDocStore? _store;
  PlanDocStore? get store => _store;

  /// The version the pane is currently showing. Always == [headVersion]
  /// unless the user is time-traveling via the timeline.
  int _viewingVersion = 0;
  int get viewingVersion => _viewingVersion;
  int get headVersion => _store?.headVersion ?? 0;

  /// Whether the pane is showing a past version (read-only preview).
  bool get isViewingHistory => _viewingVersion != headVersion;

  PlanRevertEvent? _pendingRevert;

  /// Set on [revertTo], consumed (read + cleared) by the next turn's
  /// `<plan-context>` injection (§9.3).
  PlanRevertEvent? get pendingRevert => _pendingRevert;
  void clearPendingRevert() {
    _pendingRevert = null;
  }

  /// Scroll offset captured at the last agent edit — the "Jump to
  /// latest" target in free mode.
  double _lastEditScrollTarget = 0.0;

  // ── Lifecycle ─────────────────────────────────────────────────────

  /// Enter plan mode on [path] (defaults to `<projectPath>/PLAN.md`).
  /// Creates the file with a skeleton when absent. Idempotent while
  /// active on the same path; switching paths re-enters.
  void enter(String projectPath, {String? planName}) {
    final name = (planName == null || planName.isEmpty)
        ? kDefaultPlanDocName
        : (planName.endsWith('.md') ? planName : '$planName.md');
    final path = p.normalize(p.join(projectPath, name));

    final file = File(path);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
      file.writeAsStringSync(kPlanDocSkeleton);
    }

    _planDocPath = path;
    _active = true;
    _approved = false;
    _viewMode = PlanViewMode.follow;
    _selection = null;
    _pendingRevert = null;
    activeFlashes.clear();

    _store = PlanDocStore(
      projectPath: projectPath,
      sessionId: _sessionId ?? 0,
      planName: name,
    );
    _docText = file.readAsStringSync();
    _store!.ensureInitialized(_docText);
    _viewingVersion = headVersion;
    _reparse();
    _mirrorPlanState();
    onFileChanged?.call();
    notifyListeners();
  }

  /// Leave plan mode. The pane collapses; the file on disk stays as-is.
  void exit() {
    if (!_active) return;
    _active = false;
    _planDocPath = null;
    _approved = false;
    _selection = null;
    _pendingRevert = null;
    activeFlashes.clear();
    _store = null;
    _viewingVersion = 0;
    _mirrorPlanState();
    onFileChanged?.call();
    notifyListeners();
  }

  // ── Approved sub-state ────────────────────────────────────────────

  /// Approve the plan: the doc stays visible but the edit/write/shell
  /// guards lift so the agent can implement it. No-op when inactive or
  /// already approved.
  void approve() {
    if (!_active || _approved) return;
    _approved = true;
    _mirrorPlanState();
    notifyListeners();
  }

  /// Unapprove: re-arm the plan-mode guards (back to plan-doc-only
  /// editing). The doc stays visible. No-op when not approved.
  void unapprove() {
    if (!_approved) return;
    _approved = false;
    _mirrorPlanState();
    notifyListeners();
  }

  // ── Session keying ────────────────────────────────────────────────

  int? _sessionId;

  /// The session the pane is currently bound to, or null before the
  /// first attach. Read by the turn orchestrator to gate per-session
  /// `<plan-context>` injection.
  int? get sessionId => _sessionId;

  /// Whether the pane is currently bound to [sessionId]. A background
  /// session's turn uses this to decide it must NOT receive the
  /// foreground session's plan-context block.
  bool isAttachedTo(int sessionId) =>
      _active && _sessionId == sessionId;

  /// Re-key the controller when the current session changes.
  ///
  /// Plan view is session-bound: switching to a session with no plan
  /// collapses the pane; switching to one whose runtime still carries a
  /// `planDocPath` re-opens it there (with the session's saved viewing
  /// position). Leaving a session saves the pane's view state (view
  /// mode, timeline position, scroll offset) into that session's
  /// runtime so a later switch-back restores it.
  void attachSession(int sessionId) {
    if (_sessionId == sessionId) return;

    // 1. Save the outgoing session's pane state into its runtime.
    _saveViewStateForOutgoingSession();

    _sessionId = sessionId;

    // 2. Restore from the incoming session's runtime mirror.
    final rt = _runtimeForId(sessionId);
    final resumedPath = rt?.planDocPath;
    if (resumedPath == null || resumedPath.isEmpty) {
      // Incoming session has no plan → collapse the pane (doc on disk
      // stays as-is).
      if (_active) {
        _active = false;
        _planDocPath = null;
        _approved = false;
        _selection = null;
        _pendingRevert = null;
        activeFlashes.clear();
        _store = null;
        _viewingVersion = 0;
        onFileChanged?.call();
        notifyListeners();
      }
      return;
    }

    // 3. Incoming session has a plan: (re)open the pane on its doc.
    //    The file may have changed on disk since (background session
    //    edits, external editor) — read it fresh.
    final file = File(resumedPath);

    final wasActive = _active;
    _active = true;
    _planDocPath = resumedPath;
    _approved = rt!.planApproved;
    _store = PlanDocStore(
      projectPath: p.dirname(resumedPath),
      sessionId: sessionId,
      planName: p.basename(resumedPath),
    );
    _docText = file.existsSync() ? file.readAsStringSync() : '';
    _store!.ensureInitialized(_docText);
    // Absorb edits made while this session was in the background (the
    // controller only mirrors the foreground session, so the version
    // log missed them): when the file on disk no longer equals the
    // log's head, append it as a regular edit version so the timeline
    // stays linear and auditable.
    {
      final head = _store!.headVersion;
      final headContent = head > 0 ? _store!.readVersion(head) : null;
      if (headContent != null && headContent != _docText) {
        _store!.append(_docText);
      }
    }
    _selection = null;
    _pendingRevert = null;
    activeFlashes.clear();
    _viewMode = rt.planViewModeWasFree
        ? PlanViewMode.free
        : PlanViewMode.follow;
    _lastEditScrollTarget = 0.0;

    // Restore the saved timeline position: a saved history version
    // keeps time-traveling at that version; HEAD restores to the
    // (possibly advanced) head.
    if (rt.planWasViewingHistory &&
        rt.planSavedViewingVersion > 0 &&
        rt.planSavedViewingVersion <= _store!.headVersion) {
      _viewingVersion = rt.planSavedViewingVersion;
      final content = _store!.readVersion(_viewingVersion);
      if (content != null) {
        _parsed = parsePlanDocument(content, _theme ?? _monoTheme);
      }
    } else {
      _viewingVersion = _store!.headVersion;
      _reparse();
    }

    // Replay the saved scroll offset. jumpTo clamps against whatever
    // metrics the pane currently knows; if they're stale (the pane is
    // about to re-lay-out on the restored content) the next layout
    // silently corrects the offset into the real bounds — the same
    // clamp semantics every other scroll site here relies on.
    scrollController.jumpTo(rt.planSavedScrollOffset);

    // Always notify on a re-open: the pane must rebuild even when the
    // previous session happened to show the same file.
    if (!wasActive) onFileChanged?.call();
    notifyListeners();
  }

  /// Persist the current pane's view state into the outgoing session's
  /// runtime so a later switch-back can restore it. The core plan flags
  /// (`planDocPath` / `planApproved`) are already mirrored there by
  /// `_mirrorPlanState`; this adds the view-position snapshot.
  void _saveViewStateForOutgoingSession() {
    final sid = _sessionId;
    if (sid == null || !_active) return;
    final rt = _runtimeForId(sid);
    if (rt == null) return;
    rt.planWasViewingHistory = isViewingHistory;
    rt.planSavedViewingVersion = _viewingVersion;
    rt.planSavedScrollOffset = scrollController.offset;
    rt.planViewModeWasFree = _viewMode == PlanViewMode.free;
  }

  SessionRuntimeState? _runtimeForId(int sessionId) =>
      runtimeById?.call(sessionId);

  // ── Edits ─────────────────────────────────────────────────────────

  /// Called when a tool result mutated the plan doc. [oldText] /
  /// [newText] are the before/after file contents, [sessionId] the
  /// session whose turn made the edit. Edits from a session other than
  /// the currently attached one are ignored (the pane is session-bound;
  /// the background session's plan version log is rebuilt from disk on
  /// switch-back). Recomputes the parse, diffs, pushes flash regions,
  /// snapshots the version, and — in follow mode — scrolls to the
  /// first changed range.
  void onAgentEdit(String oldText, String newText, {int? sessionId}) {
    // A background session's edit must not redraw the current pane.
    if (sessionId != null && sessionId != _sessionId) return;
    if (!_active) return;
    _docText = newText;
    _reparse();
    _viewingVersion = _store?.append(newText) ?? headVersion;

    final changedLines = _changedSourceLines(oldText, newText);
    final rows = <int>{
      for (final range in changedLines)
        ..._parsed.sourceMap.sourceLinesToRenderedRows(range.$1, range.$2),
    }.toList()
      ..sort();
    if (rows.isNotEmpty) {
      activeFlashes.add(FlashRegion(
        renderedRows: rows,
        startedAt: DateTime.now(),
      ));
      _pruneFlashes();
      if (_viewMode == PlanViewMode.follow) {
        _lastEditScrollTarget = rows.first.toDouble();
        scrollToRow(rows.first);
      } else {
        _lastEditScrollTarget = rows.first.toDouble();
      }
    }
    onFileChanged?.call();
    notifyListeners();
  }

  /// Revert HEAD to [version]'s content: appends a new version equal to
  /// the target (history stays linear), writes the file on disk, and
  /// records the [PlanRevertEvent] so the next turn tells the agent
  /// (§9.3).
  void revertTo(int version) {
    final store = _store;
    final path = _planDocPath;
    if (store == null || path == null) return;
    final content = store.readVersion(version);
    if (content == null) return;

    final fromVersion = headVersion;
    File(path).writeAsStringSync(content);
    final newHead = store.append(
      content,
      kind: PlanVersionKind.revert,
      revertedTo: version,
    );
    _docText = content;
    _reparse();
    _viewingVersion = newHead;
    _pendingRevert = PlanRevertEvent(
      fromVersion: fromVersion,
      toVersion: version,
      at: DateTime.now(),
    );
    onFileChanged?.call();
    notifyListeners();
  }

  // ── Viewing / scroll ──────────────────────────────────────────────

  /// Time-travel the pane to [version] (pure UI; the file on disk stays
  /// HEAD — §9.3). Pass [headVersion] to return to HEAD.
  void viewVersion(int version) {
    final store = _store;
    if (store == null) return;
    _viewingVersion = version;
    if (version == headVersion) {
      _reparse();
    } else {
      final content = store.readVersion(version);
      if (content != null) {
        _parsed = parsePlanDocument(content, _theme ?? _monoTheme);
      }
    }
    notifyListeners();
  }

  /// User scrolled (wheel/drag). In follow mode this transitions to free
  /// mode; the next agent edit is the re-center trigger (peek-friendly).
  void onUserScroll() {
    if (_viewMode == PlanViewMode.follow) {
      _viewMode = PlanViewMode.free;
      lastFreeScrollOffset = scrollController.offset;
      notifyListeners();
    }
  }

  /// "Jump to latest" — back to follow mode, scrolled to the last edit.
  void onJumpToLatest() {
    _viewMode = PlanViewMode.follow;
    _viewingVersion = headVersion;
    _reparse();
    scrollToRow(_lastEditScrollTarget.round());
    notifyListeners();
  }

  /// Scroll the pane so [row] is visible (jump — no animation here; the
  /// animated variant lives in the pane, which owns the
  /// [AnimationController] vsync).
  void scrollToRow(int row) {
    final target = row.toDouble().clamp(
          scrollController.minScrollExtent,
          scrollController.maxScrollExtent,
        );
    scrollController.jumpTo(target);
  }

  // ── Selection ─────────────────────────────────────────────────────

  /// Update the current selection from rendered offsets (called by the
  /// pane's `SelectionArea` info callback).
  void onSelectionRange(int renderedStart, int renderedEnd) {
    if (!_active || renderedStart >= renderedEnd) {
      if (_selection != null) {
        _selection = null;
        notifyListeners();
      }
      return;
    }
    final start = _parsed.sourceMap.renderedToSource(renderedStart);
    final end = _parsed.sourceMap
        .renderedToSource(renderedEnd, bias: MapBias.end);
    final source = _viewedText;
    final startOffset = start.offset.clamp(0, source.length);
    final endOffset = end.offset.clamp(0, source.length);
    final verbatim = startOffset < endOffset
        ? source.substring(startOffset, endOffset)
        : '';
    _selection = PlanSelection(
      text: verbatim,
      startLine: start.line,
      startCol: start.column,
      endLine: end.line,
      endCol: end.column,
      fromVersion: _viewingVersion,
    );
    notifyListeners();
  }

  void clearSelection() {
    if (_selection == null) return;
    _selection = null;
    notifyListeners();
  }

  /// The text the pane is currently rendering (HEAD or a past version).
  String get _viewedText => _viewingVersion == headVersion
      ? _docText
      : (_store?.readVersion(_viewingVersion) ?? _docText);

  // ── Viewport → source lines (for <plan-context>) ──────────────────

  /// The source line range the user is currently looking at, derived
  /// from the scroll offset and viewport height. Returns null when the
  /// pane has nothing rendered.
  (int, int)? viewportSourceLines({int? viewportRows}) {
    if (!_active || _parsed.renderedText.isEmpty) return null;
    final rows = viewportRows ?? scrollController.viewportDimension.round();
    final topRow = scrollController.offset.floor();
    final bottomRow = topRow + (rows <= 0 ? 1 : rows) - 1;
    final lineStarts = _flatRowStarts();
    if (lineStarts.isEmpty) return null;
    final topOffset = topRow >= lineStarts.length
        ? _parsed.renderedText.length
        : lineStarts[topRow];
    final bottomOffset = bottomRow >= lineStarts.length
        ? _parsed.renderedText.length
        : lineStarts[bottomRow];
    final top = _parsed.sourceMap.renderedToSource(topOffset);
    final bottom = _parsed.sourceMap.renderedToSource(bottomOffset);
    return (top.line, bottom.line);
  }

  /// Char offset of the start of each rendered flat row.
  List<int> _flatRowStarts() {
    final text = _parsed.renderedText;
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }

  // ── Internals ─────────────────────────────────────────────────────

  static const _monoTheme = _MonoTheme();

  void _reparse() {
    _parsed = parsePlanDocument(_docText, _theme ?? _monoTheme);
  }

  void _pruneFlashes() {
    final now = DateTime.now();
    activeFlashes.removeWhere((f) => f.isExpiredAt(now));
  }

  void _mirrorPlanState() {
    final rt = runtimeFor?.call();
    if (rt != null) {
      rt.planDocPath = _active ? _planDocPath : null;
      rt.planApproved = _active && _approved;
    }
  }

  /// Diff [oldText] → [newText] and return the changed source line
  /// ranges (0-based, inclusive) on the NEW side. Uses the vibe diff's
  /// LCS; `contextLines: 0` keeps only the changed rows.
  List<(int, int)> _changedSourceLines(String oldText, String newText) {
    final diff = computeLineDiff(oldText, newText, contextLines: 0);
    final ranges = <(int, int)>[];
    var newLine = 0;
    int? rangeStart;
    var lastAdded = -2;
    for (final line in diff) {
      switch (line.kind) {
        case DiffLineKind.added:
          if (rangeStart == null || newLine != lastAdded + 1) {
            if (rangeStart != null) ranges.add((rangeStart, lastAdded));
            rangeStart = newLine;
          }
          lastAdded = newLine;
          newLine++;
        case DiffLineKind.removed:
          // A pure removal flashes the line that now sits where the
          // removed block was (or the previous line at EOF).
          final anchor = newLine == 0 ? 0 : newLine - 1;
          ranges.add((anchor, anchor));
        case DiffLineKind.context:
          if (rangeStart != null) {
            ranges.add((rangeStart, lastAdded));
            rangeStart = null;
          }
          newLine++;
        case DiffLineKind.gap:
          if (rangeStart != null) {
            ranges.add((rangeStart, lastAdded));
            rangeStart = null;
          }
          newLine += line.elidedCount;
      }
    }
    if (rangeStart != null) ranges.add((rangeStart, lastAdded));
    return ranges;
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}

/// Parser theme used before the pane has supplied a real one (the
/// controller parses on [enter], before the first build). Styles are
/// colorless defaults; the pane re-parses with the real theme on its
/// first build via `controller.theme = …`.
class _MonoTheme implements MarkdownThemeFields {
  const _MonoTheme();

  static const _c = Color(0xFF000000);

  @override
  Color get markdownText => _c;
  @override
  Color get thinkingExpandedText => _c;
  @override
  Color get mdH1 => _c;
  @override
  Color get mdH2 => _c;
  @override
  Color get mdH3 => _c;
  @override
  Color get mdH4 => _c;
  @override
  Color get mdH5 => _c;
  @override
  Color get mdH6 => _c;
  @override
  Color get mdBold => _c;
  @override
  Color get mdItalic => _c;
  @override
  Color get mdStrikethrough => _c;
  @override
  Color get mdInlineCode => _c;
  @override
  Color get mdInlineCodeBg => _c;
  @override
  Color get mdCodeBlockText => _c;
  @override
  Color get mdBlockquote => _c;
  @override
  Color get mdLink => _c;
  @override
  Color get codeBlockBackground => _c;
  @override
  Color get codeBlockGutter => _c;
  @override
  Color get codeBlockHeader => _c;
  @override
  Color get outline => _c;
  @override
  Color get surface => _c;
  @override
  Color get surfaceVariant => _c;
  @override
  Color get highlightDefault => _c;
  @override
  Color get highlightKeyword => _c;
  @override
  Color get highlightStorage => _c;
  @override
  Color get highlightFunction => _c;
  @override
  Color get highlightType => _c;
  @override
  Color get highlightAttribute => _c;
  @override
  Color get highlightString => _c;
  @override
  Color get highlightComment => _c;
  @override
  Color get highlightConstant => _c;
  @override
  Color get highlightNumeric => _c;
  @override
  Color get highlightVariable => _c;
  @override
  Color get highlightTag => _c;
  @override
  Color get highlightPunctuation => _c;
  @override
  Color get syntaxOperator => _c;
}

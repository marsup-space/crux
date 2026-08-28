// Unicode-width measurement (CJK, emoji, ZWJ) is used to align the extra-info
// panel's git-status rows. Lives in nocterm's `lib/src/`; not re-exported.
// ignore_for_file: implementation_imports

import 'dart:io';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../services/git_status_service.dart';
import '../services/plugin.dart';
import '../services/plugin_registry.dart';
import '../theme/crux_theme.dart';
import '../models/session.dart';
import '../i18n/strings.dart';
import '../utils/frame_profiler.dart';
import '../utils/ticker_registry.dart';
import '../utils/terminal_symbols.dart';
import 'git_status_widget.dart';
import 'plugin_sidebar_box.dart';
import 'plugin_content.dart';
import 'session_controller.dart';
import 'ui/auxiliary_model_button.dart';
import 'ui/fps_counter.dart';
import 'ui/multi_button.dart';

/// Time-based grouping for sessions in the sidebar.
enum _SessionGroup {
  yesterday('chat.sessions.yesterday'),
  threeDays('chat.sessions.threeDays'),
  archived('chat.sessions.archived'),
  chats('chat.sessions.chats'),
  chatsArchived('chat.sessions.chatsArchived');

  const _SessionGroup(this.label);
  final String label;
}

/// Sentinel row marker: "render a horizontal divider here". Pinned
/// rows are followed by a divider so they read as their own visual
/// band at the top of the section, without needing a "Pinned" header
/// label. Marker-only (no fields) so the list-of-Object payload stays
/// allocation-light.
class _DividerRow {
  const _DividerRow();
}

/// Right-hand side panel showing the active and historical sessions,
/// plus a [MultiButton] pinned to the bottom that exposes the current
/// project path as two actions: `open` (reveal in the system file
/// explorer) and `switch` (seed the chat input with `/project `).
///
/// Sessions are grouped by recency:
/// - **Today** — no label, just the sessions at the top
/// - **Yesterday** — sessions from the previous calendar day
/// - **3 Days** — sessions from 2–3 days ago
///
/// Sessions older than 3 days are auto-archived by
/// [SessionController.initSessions] and don't appear in the list.
/// An "Archived" hint row at the bottom shows the count and reminds
/// the user about `/unarchive`.
class ExtraInfoPanel extends StatefulComponent {
  final List<Session> sessions;

  /// Chat-mode sessions (global, not project-scoped). Rendered in a
  /// "Chats" section below the "Sessions" list. Visible in every
  /// Crux instance.
  final List<Session> chats;
  final int currentSessionId;
  final void Function(int) onSwitchSession;

  /// Invoked when the user clicks the pin/star affordance on a session
  /// or chat row. Toggles [Session.pinnedAt]; null hides the affordance
  /// (tests/contexts without a controller).
  final void Function(int sessionId)? onTogglePin;

  final VoidCallback? onSessionTitleTap;

  /// Number of archived sessions (not included in [sessions]).
  final int archivedCount;

  /// Number of archived Chat-mode sessions (not included in [chats]).
  final int archivedChatCount;

  /// Creates a new Chat-mode session. Wired by the chat panel to
  /// [SessionController.createChatSession]; when null the "Chats"
  /// section header hides its add button.
  final Future<void> Function()? onCreateChat;

  /// Creates a new workspace session. Wired by the chat panel to the
  /// `/new` path; when null the "Sessions" header hides its add
  /// button.
  final Future<void> Function()? onCreateSession;

  /// Invoked when the user clicks the `open` segment of the project
  /// path button. Should open the project directory in the system
  /// file explorer and surface any failure as a toast.
  final VoidCallback? onOpenProject;

  /// Invoked when the user clicks the `switch` segment of the project
  /// path button. Should populate the chat input with `/project ` so
  /// the user can type a new project path and submit it.
  final VoidCallback? onSwitchProject;

  /// Live git status of the project root. Powers both the
  /// [GitStatusWidget] rendered just above the project widget and
  /// the branch / sync annotations on the project widget itself.
  /// Must be the same instance owned by [ChatPanel] so the polling
  /// timer keeps running after panel rebuilds; passing a fresh
  /// instance here would orphan the timer (and leak it on dispose).
  final GitStatusService gitStatusService;

  /// Spec-driven plugins for the current project (sidebar placement —
  /// `.crux/plugins/*.toml` + global `~/.crux/plugins/`, discovered by
  /// [PluginRegistry]). Each renders one boxed row above the git
  /// status. Null in tests/contexts where no plugins should appear.
  final List<Plugin>? plugins;

  /// Session controller backing the [AuxiliaryModelButton] rendered
  /// just above the git status / project widgets. Optional so tests
  /// that don't exercise the button can omit it; when null the
  /// button is not rendered.
  final SessionController? sessionController;

  /// Called when the user clicks the auxiliary-model button. The
  /// chat panel wires this to `stashAndSetCommand('/auxiliary ')`.
  final VoidCallback? onAuxiliaryPressed;

  /// Wiring handed to plugin boxes/rows (prompt/shell/screen/todo
  /// handlers + session recording), shared by the sidebar and home
  /// renderers. Null in tests/contexts with no host; those action
  /// kinds then hide.
  final PluginHost? pluginHost;
  final Strings strings;

  const ExtraInfoPanel({
    required this.sessions,
    this.chats = const [],
    required this.currentSessionId,
    required this.onSwitchSession,
    this.onTogglePin,
    required this.archivedCount,
    this.archivedChatCount = 0,
    this.onCreateChat,
    this.onCreateSession,
    required this.gitStatusService,
    this.plugins,
    this.onSessionTitleTap,
    this.onOpenProject,
    this.onSwitchProject,
    this.sessionController,
    this.onAuxiliaryPressed,
    this.pluginHost,
    this.strings = kEnglishStrings,
  });

  @override
  State<ExtraInfoPanel> createState() => _ExtraInfoPanelState();
}

class _ExtraInfoPanelState extends State<ExtraInfoPanel> {
  TickerToken? _animTicker;
  double _phase = 0.0;
  final Set<int> _hoveredIds = {};
  bool _titleHovered = false;

  // Bumped on every git-status change so the panel's own
  // MultiButton (which renders `path:branch ↑N ↓N` in its idle
  // label) re-renders in lock-step with the [GitStatusWidget].
  // The widget subscribes independently for its own rows; this
  // is a separate subscription because the project widget is
  // rendered by *this* state, not by the child widget.
  int _gitTick = 0;

  /// Floor for the per-row title truncation. Used when the panel is
  /// narrower than expected (defensive — shouldn't normally trigger).
  static const int _maxTitleLenFloor = 14;

  /// Ceiling for the per-row title truncation. Caps titles so they
  /// never outgrow the panel even if it's resized beyond its target.
  static const int _maxTitleLenCeiling = 40;

  /// Phase advance rate (radians per second) for the
  /// session-status fade pulse. Drives a sinusoidal color
  /// lerp between dim and bright; the original cadence
  /// advanced by 0.3 every 50 ms tick (= 6 rad/s).
  static const double _animRadiansPerSecond = 6.0;
  static const Duration _animInterval = Duration(milliseconds: 50);

  Color get _prefixDim => CruxTheme.of(context).onSurfaceDim;
  Color get _prefixBright => CruxTheme.of(context).sessionPrefixRunning;

  /// Flattened row items for the list view. Each item is either a
  /// [_SessionGroup] header or a [Session] row. This avoids nested
  /// ListViews and lets [ListView.builder] handle everything in one
  /// flat list.
  List<Object> _rows = const [];
  List<Session>? _prevSessions;
  List<Session>? _prevChats;
  int _prevArchivedCount = 0;
  int _prevArchivedChatCount = 0;
  int _prevFingerprint = 0;

  /// Compute a lightweight fingerprint of the session list so that
  /// in-place mutations (e.g. a session's [updatedAt] being bumped
  /// when the user continues it) correctly invalidate the cached row
  /// list.  Using [identical] on the list reference is insufficient
  /// because [Session.updatedAt] is mutated on the existing object
  /// without replacing the list.
  static int _fingerprint(List<Session> sessions, List<Session> chats) {
    var hash = 0;
    for (final s in sessions) {
      //updatedAt.millisecondsSinceEpoch changes when a session is
      // continued, which is exactly the signal we need. pinnedAt is
      // mixed in so pin/unpin re-derives the row list without touching
      // updatedAt.
      hash ^= s.id ^
          s.updatedAt.millisecondsSinceEpoch ^
          (s.pinnedAt?.millisecondsSinceEpoch ?? 0);
    }
    // Mix chats in with a distinct constant so a chat and a session
    // with the same id/updatedAt don't cancel out in the XOR.
    for (final s in chats) {
      hash ^=
          (s.id ^
              s.updatedAt.millisecondsSinceEpoch ^
              (s.pinnedAt?.millisecondsSinceEpoch ?? 0)) *
          0x9e3779b1;
    }
    return hash;
  }

  /// Build the flat row list from the sorted sessions, inserting
  /// group headers where appropriate.
  ///
  /// Layout:
  /// - Sessions section:
  ///   - Pinned sessions (sorted by pin time, newest first), followed
  ///     by a horizontal divider that separates them from the rest
  ///   - Today's sessions, **no header label**
  ///   - "Yesterday" header + yesterday's sessions
  ///   - "3 Days" header + sessions from 2–3 days ago
  ///   - "N archived /unarchive #id" hint
  /// - Chats section:
  ///   - "Chats" header (divider)
  ///   - Pinned chats (sorted by pin time, newest first), followed
  ///     by a divider
  ///   - Today's chats, no header
  ///   - "Yesterday" / "3 Days" headers + those buckets
  ///   - "N archived /unarchive #id" hint
  ///
  /// Pinned rows are deliberately not hoisted into a single
  /// cross-section group at the very top: a pinned chat must stay
  /// in the Chats section (where chats live) and a pinned session
  /// must stay in the Sessions section. The previous "shared
  /// Pinned header" layout made a pinned chat look like it had
  /// jumped into the workspace Sessions list. Pinned rows now sit
  /// at the top of their own section, with a divider underneath so
  /// the visual band reads as a "Pinned" group without needing a
  /// label.
  static List<Object> _buildRows(
    List<Session> sorted,
    int archivedCount,
    List<Session> sortedChats,
    int archivedChatCount,
  ) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final threeDaysAgo = todayStart.subtract(const Duration(days: 3));

    final rows = <Object>[];

    // ── Sessions section ───────────────────────────────────────
    // Pinned sessions live at the very top of THIS section, not in a
    // shared top-of-list group. Sorted by pin time, newest first.
    // A divider below closes the "Pinned" visual band.
    final pinnedSessions = <Session>[
      for (final s in sorted)
        if (s.isPinned) s,
    ]..sort((a, b) => b.pinnedAt!.compareTo(a.pinnedAt!));
    if (pinnedSessions.isNotEmpty) {
      rows.addAll(pinnedSessions);
      rows.add(const _DividerRow());
    }

    // Bucket non-pinned sessions into recency groups.
    final today = <Session>[];
    final yesterday = <Session>[];
    final threeDays = <Session>[];

    for (final s in sorted) {
      if (s.isPinned) continue;
      if (!s.updatedAt.isBefore(todayStart)) {
        today.add(s);
      } else if (!s.updatedAt.isBefore(yesterdayStart)) {
        yesterday.add(s);
      } else if (!s.updatedAt.isBefore(threeDaysAgo)) {
        threeDays.add(s);
      }
      // Older than 3 days: already auto-archived by
      // SessionController.initSessions; shouldn't appear here.
    }

    // Today: no header, just the sessions.
    rows.addAll(today);
    if (yesterday.isNotEmpty) {
      rows.add(_SessionGroup.yesterday);
      rows.addAll(yesterday);
    }
    if (threeDays.isNotEmpty) {
      rows.add(_SessionGroup.threeDays);
      rows.addAll(threeDays);
    }
    if (archivedCount > 0) {
      rows.add(_SessionGroup.archived);
    }

    // ── Chats section ────────────────────────────────────────────
    // Workspace-free conversations, listed globally. Mirrors the
    // sessions list's recency grouping (today unlabeled, then
    // "Yesterday" / "3 Days") so the two sections read identically.
    // A chat running in another Crux instance is refused on tap by
    // SessionController's lease check.
    //
    // Pinned chats live at the top of THIS section, not hoisted into
    // a shared cross-section header — that's what made a pinned chat
    // appear above every workspace session in the previous layout.
    final unpinnedChats = <Session>[
      for (final s in sortedChats)
        if (!s.isPinned) s,
    ];
    if (unpinnedChats.isNotEmpty ||
        sortedChats.any((s) => s.isPinned) ||
        archivedChatCount > 0) {
      rows.add(_SessionGroup.chats);

      // Pinned chats, sorted by pin time, newest first, with a
      // divider underneath so they read as a top-of-section band.
      final pinnedChats = <Session>[
        for (final s in sortedChats)
          if (s.isPinned) s,
      ]..sort((a, b) => b.pinnedAt!.compareTo(a.pinnedAt!));
      if (pinnedChats.isNotEmpty) {
        rows.addAll(pinnedChats);
        rows.add(const _DividerRow());
      }

      final chatsToday = <Session>[];
      final chatsYesterday = <Session>[];
      final chatsThreeDays = <Session>[];
      for (final s in unpinnedChats) {
        if (!s.updatedAt.isBefore(todayStart)) {
          chatsToday.add(s);
        } else if (!s.updatedAt.isBefore(yesterdayStart)) {
          chatsYesterday.add(s);
        } else if (!s.updatedAt.isBefore(threeDaysAgo)) {
          chatsThreeDays.add(s);
        }
      }
      rows.addAll(chatsToday);
      if (chatsYesterday.isNotEmpty) {
        rows.add(_SessionGroup.yesterday);
        rows.addAll(chatsYesterday);
      }
      if (chatsThreeDays.isNotEmpty) {
        rows.add(_SessionGroup.threeDays);
        rows.addAll(chatsThreeDays);
      }
      if (archivedChatCount > 0) {
        rows.add(_SessionGroup.chatsArchived);
      }
    }
    return rows;
  }

  List<Object> get _ensureRows {
    final sessions = component.sessions;
    final chats = component.chats;
    final archived = component.archivedCount;
    final archivedChat = component.archivedChatCount;
    final fp = _fingerprint(sessions, chats);
    if (_prevSessions != sessions ||
        _prevChats != chats ||
        _prevFingerprint != fp ||
        _prevArchivedCount != archived ||
        _prevArchivedChatCount != archivedChat) {
      _prevSessions = sessions;
      _prevChats = chats;
      _prevFingerprint = fp;
      _prevArchivedCount = archived;
      _prevArchivedChatCount = archivedChat;
      final sorted = List<Session>.from(sessions)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final sortedChats = List<Session>.from(chats)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _rows = _buildRows(sorted, archived, sortedChats, archivedChat);
    }
    return _rows;
  }

  @override
  void initState() {
    super.initState();
    _startAnimIfNeeded();
    // Subscribe to git-status changes so the project widget's
    // `path:branch ↑N ↓N` label stays in sync with the
    // [GitStatusWidget] rendered above it. We could share a
    // subscription with that widget, but the wiring is simpler
    // if each component manages its own listener — and the cost
    // is one extra `setState` every ~5s when the repo is
    // changing.
    component.gitStatusService.addListener(_onGitStatusChanged);
  }

  @override
  void didUpdateComponent(ExtraInfoPanel old) {
    super.didUpdateComponent(old);
    if (!identical(old.gitStatusService, component.gitStatusService)) {
      old.gitStatusService.removeListener(_onGitStatusChanged);
      component.gitStatusService.addListener(_onGitStatusChanged);
    }
    _startAnimIfNeeded();
  }

  @override
  void dispose() {
    _animTicker?.cancel();
    component.gitStatusService.removeListener(_onGitStatusChanged);
    super.dispose();
  }

  void _onGitStatusChanged() {
    // Bump the tick so the build method reads the fresh snapshot
    // without us having to plumb the value through props. The
    // widget tree already short-circuits no-op repaints via
    // [GitStatus.==], so the only cost of an unconditional
    // setState here is the widget-element diff itself.
    _gitTick++;
    if (mounted) setState(() {});
  }

  bool _hasRespondingSession() {
    return component.sessions.any((s) => s.status == SessionStatus.running);
  }

  void _startAnimIfNeeded() {
    if (_hasRespondingSession()) {
      _animTicker ??= TickerRegistry.instance.subscribe(
        name: 'extraInfoAnim',
        interval: _animInterval,
        onTick: (elapsed) {
          if (!_hasRespondingSession()) {
            _animTicker?.cancel();
            _animTicker = null;
            _phase = 0.0;
          }
          // Delta-time advance: convert the wall-clock delta to
          // seconds and multiply by the radian rate. On a slow
          // frame the phase advances further; on a fast frame
          // less — pulse rate stays constant in real time.
          final dt = elapsed == Duration.zero
              ? 0.05
              : elapsed.inMicroseconds / Duration.microsecondsPerSecond;
          _phase += _animRadiansPerSecond * dt;
          setState(() {});
        },
      );
    } else {
      _animTicker?.cancel();
      _animTicker = null;
      _phase = 0.0;
    }
  }

  double _fadeIntensity() {
    final raw = (sin(_phase) + 1.0) / 2.0;
    return raw;
  }

  String _statusPrefix(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return terminalSymbol('·', '.');
      case SessionStatus.running:
        return terminalSymbol('▶', '>');
      case SessionStatus.needUserAction:
        return '?';
      case SessionStatus.done:
        return terminalSymbol('✦', '*');
      case SessionStatus.interrupted:
        return terminalSymbol('✗', 'x');
    }
  }

  Color _prefixColor(SessionStatus status, bool isCurrent) {
    if (isCurrent) return CruxTheme.of(context).sessionPrefixActive;
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.of(context).sessionPrefixIdle;
      case SessionStatus.running:
        return Color.lerp(_prefixDim, _prefixBright, _fadeIntensity())!;
      case SessionStatus.needUserAction:
        return CruxTheme.of(context).sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.of(context).sessionPrefixDone;
      case SessionStatus.interrupted:
        return CruxTheme.of(context).sessionPrefixInterrupted;
    }
  }

  Color _titleColor(SessionStatus status, bool isCurrent, bool isHovered) {
    if (isCurrent || isHovered) {
      return CruxTheme.of(context).sessionPrefixActive;
    }
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.of(context).sessionPrefixIdle;
      case SessionStatus.running:
        return CruxTheme.of(context).sessionPrefixRunning;
      case SessionStatus.needUserAction:
        return CruxTheme.of(context).sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.of(context).sessionPrefixDone;
      case SessionStatus.interrupted:
        return CruxTheme.of(context).sessionPrefixInterrupted;
    }
  }

  Color _bgColor(bool isCurrent, bool isHovered) {
    if (isCurrent) return CruxTheme.of(context).wizardRowBgSelected;
    if (isHovered) return CruxTheme.of(context).wizardRowBgSelected;
    return CruxTheme.of(context).buttonBackground;
  }

  /// Truncate [text] so it fits within [maxWidth] terminal columns,
  /// measuring by display width (not code units) so wide characters
  /// like CJK glyphs and emoji are accounted for correctly. The
  /// truncation marker is a trailing `~`. Splits on grapheme clusters
  /// to avoid breaking surrogate pairs / combining sequences.
  String _truncateByWidth(String text, int maxWidth) {
    if (maxWidth <= 0) return '';
    if (UnicodeWidth.stringWidth(text) <= maxWidth) return text;
    // Reserve 1 col for the trailing '~'.
    final budget = maxWidth - 1;
    final chars = text.characters;
    int width = 0;
    int count = 0;
    for (final c in chars) {
      final cw = UnicodeWidth.stringWidth(c);
      if (width + cw > budget) break;
      width += cw;
      count++;
    }
    return '${chars.take(count)}~';
  }

  /// Build the idle label for the project [MultiButton]. Shape:
  ///
  ///   `~/path/to/project`               (not a git repo)
  ///   `~/path/to/project:main`          (clean, in sync)
  ///   `~/path/to/project:main ↑3`       (3 commits to push)
  ///   `~/path/to/project:main ↓2`       (2 commits to pull)
  ///   `~/path/to/project:main ↑3 ↓2`    (both)
  ///
  /// The result is *not* truncated here — the surrounding
  /// `MultiButton` widens to fit it via [LayoutBuilder] at the
  /// call site. We still pass a single, self-contained string so
  /// the widget can compute its minimum width correctly.
  String _composeProjectLabel(String path, GitStatus git) {
    if (!git.isRepo || git.branch.isEmpty) return path;
    final buf = StringBuffer(path)
      ..write(':')
      ..write(git.branch);
    if (git.ahead > 0) {
      buf
        ..write(' ')
        ..write(terminalSymbol('↑', '^'))
        ..write(git.ahead);
    }
    if (git.behind > 0) {
      buf
        ..write(' ')
        ..write(terminalSymbol('↓', 'v'))
        ..write(git.behind);
    }
    return buf.toString();
  }

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'extraInfoPanel.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scale the per-row title length with the panel's actual width:
        // reserve 1 col for the status prefix, 1 for the leading space,
        // 1 for the gap before the star, and 1 for the pin/star glyph,
        // then use the rest of the panel for the title itself so no
        // width is wasted. Clamp so titles never get absurdly short or
        // long at extreme widths.
        final maxTitleLen = (constraints.maxWidth - 4)
            .clamp(_maxTitleLenFloor, _maxTitleLenCeiling)
            .toInt();

        final panel = component;
        final rows = _ensureRows;

        final header = Container(
          decoration: BoxDecoration(
            color: _titleHovered
                ? CruxTheme.of(context).wizardRowBgSelected
                : CruxTheme.of(context).buttonBackground,
          ),
          child: Row(
            children: [
              Expanded(
                child: MouseRegion(
                  onEnter: (_) => setState(() => _titleHovered = true),
                  onExit: (_) => setState(() => _titleHovered = false),
                  opaque: false,
                  child: GestureDetector(
                    onTap: () => component.onSessionTitleTap?.call(),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Text(
                          component.strings.t('chat.sessions.sessions'),
                          style: TextStyle(
                            color: _titleHovered
                                ? CruxTheme.of(context).wizardTextSelected
                                : CruxTheme.of(context).wizardTitle,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (component.onSessionTitleTap != null)
                          Text(
                            ' ⚙',
                            style: TextStyle(
                              color: _titleHovered
                                  ? CruxTheme.of(context).buttonTextFocused
                                  : CruxTheme.of(context).outline,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // "+" → new workspace session. Sits at the right edge of
              // the "Sessions" title row.
              if (component.onCreateSession != null)
                _AddButton(
                  hint: component.strings.t('chat.sessions.newSession'),
                  onPressed: component.onCreateSession!,
                ),
            ],
          ),
        );

        final home = Platform.environment['HOME'] ?? '';
        final cwd = Directory.current.path;
        final displayPath = home.isNotEmpty && cwd.startsWith(home)
            ? '~${cwd.substring(home.length)}'
            : cwd;
        // Compose the project widget's idle label so it identifies
        // both the directory *and* the git state. Layout:
        //
        //   `path[:branch [↑N ↓M]]`
        //
        // The branch + sync arrows are omitted when the project
        // isn't a git repo (`isRepo` false) so the widget still
        // works for non-tracked directories. `_gitTick` is read
        // here purely to force this build to re-run when the
        // service emits a new snapshot — the value itself is
        // discarded.
        // ignore: unused_local_variable
        final _ = _gitTick;
        final git = component.gitStatusService.current;
        final projectLabel = _composeProjectLabel(displayPath, git);

        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 1),
                header,
                Divider(color: CruxTheme.of(context).outline, height: 1),
                Expanded(
                  child: ListView.builder(
                    lazy: true,
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final item = rows[index];
                      if (item is _SessionGroup) {
                        return _buildGroupHeader(item);
                      }
                      if (item is _DividerRow) {
                        // Closes the "Pinned" visual band at the top
                        // of a section. Width: 1 cell, color matches
                        // the panel's outline so it reads as a
                        // continuation of the section chrome.
                        return Divider(
                          color: CruxTheme.of(context).outline,
                          height: 1,
                        );
                      }
                      return _buildSessionRow(
                        item as Session,
                        panel,
                        maxTitleLen,
                      );
                    },
                  ),
                ),
                // Spec-driven plugins (sidebar placement): one boxed row
                // per `.crux/plugins/*.toml` (or legacy/global) spec —
                // status label + action segments. Written by any
                // session, rendered by every session on the same
                // project. Sits directly above the auxiliary-model
                // button, grouped with the panel's workspace-level
                // controls.
                for (final plugin in component.plugins ??
                    const <Plugin>[])
                  PluginSidebarBox(
                    plugin: plugin,
                    host: component.pluginHost ??
                        PluginHost(projectPath: Directory.current.path),
                    strings: component.strings,
                  ),
                // Auxiliary-model button, hosted by the side panel
                // on wide terminals (on narrow terminals the chat
                // toolbar renders it instead). Sits directly above
                // the git/project widgets; click dumps `/auxiliary `
                // into the chat input.
                // Renders as its own full-width bordered box (same
                // chrome as the spec widgets above), with `aux` as
                // the border title. The border + horizontal padding
                // eat 4 columns, so the button's width budget is
                // trimmed accordingly to keep the label inside.
                if (component.sessionController != null)
                  Container(
                    width: constraints.maxWidth,
                    decoration: BoxDecoration(
                      color: CruxTheme.of(context).surface,
                      border: BoxBorder.all(
                        color: CruxTheme.of(context).outline,
                        style: BoxBorderStyle.rounded,
                      ),
                      title: BorderTitle(
                        text: component.strings.t('chat.sidebar.aux'),
                        style: TextStyle(
                          color: CruxTheme.of(context).onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Hinted(
                      hint: component.strings.t('chat.sidebar.auxHint'),
                      child: AuxiliaryModelButton(
                        sessionController: component.sessionController!,
                        onPressed: component.onAuxiliaryPressed,
                        showAuxLabel: false,
                        maxWidth: (constraints.maxWidth - 4).toInt(),
                      ),
                    ),
                  ),
                // Git status: file-level info (branch is also
                // surfaced here, but the project widget below
                // repeats it as part of `path:branch`). Now rendered
                // in its own full-width bordered box — same chrome as
                // the spec widgets and the aux button above — so the
                // bottom block reads as a matched set. The box is
                // omitted entirely outside a repo, keeping the old
                // collapse behaviour (layout stays tight).
                if (git.isRepo)
                  Container(
                    width: constraints.maxWidth,
                    decoration: BoxDecoration(
                      color: CruxTheme.of(context).surface,
                      border: BoxBorder.all(
                        color: CruxTheme.of(context).outline,
                        style: BoxBorderStyle.rounded,
                      ),
                      title: BorderTitle(
                        text: component.strings.t('chat.sidebar.git'),
                        style: TextStyle(
                          color: CruxTheme.of(context).onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: GitStatusWidget(
                      service: component.gitStatusService,
                      onTap: () => component.gitStatusService.refresh(),
                      strings: component.strings,
                    ),
                  ),
                // Project directory: `path:branch ↑N ↓N` plus the
                // `open` / `switch` actions. Wrapped in the same
                // bordered box as the other bottom-block widgets.
                Container(
                  width: constraints.maxWidth,
                  decoration: BoxDecoration(
                    color: CruxTheme.of(context).surface,
                    border: BoxBorder.all(
                      color: CruxTheme.of(context).outline,
                      style: BoxBorderStyle.rounded,
                    ),
                    title: BorderTitle(
                      text: component.strings.t('chat.sidebar.project'),
                      style: TextStyle(
                        color: CruxTheme.of(context).onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: MultiButton(
                    label: projectLabel,
                    color: CruxTheme.of(context).onSurfaceVariant,
                    hoverColor: CruxTheme.of(context).foreground,
                    segments: [
                      MultiButtonSegment(
                        label: component.strings.t('chat.sidebar.open'),
                        onPressed: panel.onOpenProject,
                      ),
                      MultiButtonSegment(
                        label: component.strings.t('chat.sidebar.switch'),
                        onPressed: panel.onSwitchProject,
                      ),
                    ],
                  ),
                ),
                // FPS readout (debug-only). Rendered as a bordered widget
                // at the very bottom — same chrome as the git / project /
                // aux boxes — and collapses to nothing when debug is off.
                // Because it's a child of this panel (which itself only
                // mounts when the terminal is wide enough to show the side
                // panel), it inherits the "panel hidden ⇒ counter hidden"
                // behaviour for free.
                const FpsCounter(),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Build a group header row (Yesterday / 3 Days / Archived / Chats).
  Component _buildGroupHeader(_SessionGroup group) {
    if (group == _SessionGroup.archived) {
      final count = component.archivedCount;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Text(
              component.strings.t('chat.sessions.archivedCount', {'n': '$count'}),
              style: TextStyle(
                color: CruxTheme.of(context).onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              ' /unarchive #id',
              style: TextStyle(color: CruxTheme.of(context).hintText),
            ),
          ],
        ),
      );
    }
    // "Chats" section header — a divider + label so it reads as a
    // distinct section below the project sessions. The "+" button for
    // creating a chat lives in the fixed panel header area (next to
    // the "Sessions" title's own add button), not here, to keep the
    // scrollable rows stateless.
    if (group == _SessionGroup.chats) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: CruxTheme.of(context).outline, height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    component.strings.t('chat.sessions.chats'),
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceDim,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // "+" → new Chat-mode session. Mirrors the "Sessions"
                // header's own add button.
                if (component.onCreateChat != null)
                  _AddButton(
                    hint: component.strings.t('chat.sessions.newChat'),
                    onPressed: component.onCreateChat!,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (group == _SessionGroup.chatsArchived) {
      final count = component.archivedChatCount;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Text(
              component.strings.t('chat.sessions.archivedCount', {'n': '$count'}),
              style: TextStyle(
                color: CruxTheme.of(context).onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              ' /unarchive #id',
              style: TextStyle(color: CruxTheme.of(context).hintText),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        component.strings.t(group.label),
        style: TextStyle(
          color: CruxTheme.of(context).onSurfaceDim,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Build a single session row widget.
  Component _buildSessionRow(
    Session session,
    ExtraInfoPanel panel,
    int maxTitleLen,
  ) {
    final isCurrent = session.id == panel.currentSessionId;
    final isHovered = _hoveredIds.contains(session.id);
    final status = session.status;
    final prefix = _statusPrefix(status);
    // Untitled sessions render a locale-aware placeholder instead of
    // the persisted (empty) title — empty title IS the untitled state.
    final title = _truncateByWidth(
      session.isUntitled
          ? component.strings.t(
              session.isChat ? 'chat.newPlaceholder' : 'session.newPlaceholder',
            )
          : session.title,
      maxTitleLen,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIds.add(session.id)),
      onExit: (_) => setState(() => _hoveredIds.remove(session.id)),
      opaque: false,
      child: Container(
        decoration: BoxDecoration(color: _bgColor(isCurrent, isHovered)),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => panel.onSwitchSession(session.id),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    Text(
                      prefix,
                      style: TextStyle(
                        color: _prefixColor(status, isCurrent),
                        fontWeight: isCurrent ? FontWeight.bold : null,
                      ),
                    ),
                    Text(
                      ' $title',
                      style: TextStyle(
                        color: _titleColor(status, isCurrent, isHovered),
                        fontWeight:
                            isCurrent || isHovered ? FontWeight.bold : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (panel.onTogglePin != null)
              _PinButton(
                pinned: session.isPinned,
                hint: session.isChat
                    ? component.strings.t('chat.sessions.pinChat')
                    : component.strings.t('chat.sessions.pinSession'),
                onPressed: () => panel.onTogglePin!(session.id),
              ),
          ],
        ),
      ),
    );
  }
}

/// The small star affordance rendered at the right edge of each
/// session/chat row. A filled ★ means pinned; a hollow ☆ means not.
/// Clicking toggles the pin. Styled to match the panel's other glyph
/// chrome — dim at rest, brightens on hover, and always bright when
/// pinned so the state is legible without hovering.
class _PinButton extends StatefulComponent {
  final bool pinned;
  final String hint;
  final VoidCallback onPressed;

  const _PinButton({
    required this.pinned,
    required this.hint,
    required this.onPressed,
  });

  @override
  State<_PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<_PinButton> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final pinned = component.pinned;
    // `★` / `☆` (U+2605 / U+2606) are single-width in every common
    // monospace terminal font; the ASCII fallbacks keep the glyph
    // legible on legacy/7-bit terminals via terminalSymbol.
    final glyph = terminalSymbol(pinned ? '★' : '☆', pinned ? '*' : 'o');
    final color = pinned
        ? CruxTheme.of(context).sessionPrefixActive
        : _hovered
        ? CruxTheme.of(context).buttonTextFocused
        : CruxTheme.of(context).outline;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: component.onPressed,
        child: Hinted(
          hint: component.hint,
          // Leading space separates the star from the truncated title
          // so the glyph never sits flush against the last character.
          child: Text(
            ' $glyph',
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// The small "+" affordance rendered at the right edge of the
/// "Sessions" and "Chats" section titles. Creates a new session of
/// the corresponding kind. Styled to read as a subtle glyph that
/// brightens on hover, matching the panel's other header chrome.
class _AddButton extends StatefulComponent {
  final String hint;
  final Future<void> Function() onPressed;

  const _AddButton({required this.hint, required this.onPressed});

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hovered = false;
  bool _busy = false;

  @override
  Component build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_busy) return;
          setState(() => _busy = true);
          component.onPressed().whenComplete(() {
            if (mounted) setState(() => _busy = false);
          });
        },
        child: Hinted(
          hint: component.hint,
          child: Text(
            ' + ',
            style: TextStyle(
              color: _hovered
                  ? CruxTheme.of(context).buttonTextFocused
                  : CruxTheme.of(context).outline,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

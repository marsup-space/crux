import 'package:nocterm/nocterm.dart';

import '../../i18n/app_locale.dart';
import '../../i18n/strings.dart';
import '../../models/session.dart';
import '../../models/daily_usage_stats.dart';
import '../../services/auxiliary_service.dart' show YesterdaySummary;
import '../../services/git_status_service.dart';
import '../../services/notes_service.dart';
import '../../services/skills/skill.dart';
import '../polling_coordinator.dart';

/// Live services handed to every home widget.
///
/// This is a service *locator*, not a god-bag: the field list only
/// grows when a concrete widget needs a service none of the current
/// ones cover, and never for a single widget's convenience (such a
/// widget keeps its own reference at registration time). TOML-defined
/// widgets never see these services — they only render their file's
/// data and command output.
class HomeContext {
  /// Run a slash command against the chat panel (`_executeCommand`).
  ///
  /// Returns `false` while a response is in flight — session-mutating
  /// actions (`/new`, `switchSession`, continue) must not fire
  /// mid-stream. Callers surface a one-line notice and stay on home.
  /// Seed-only actions (e.g. `/project `) that don't execute are
  /// allowed regardless and don't go through this guard.
  final bool Function(String command) runCommand;

  /// Dismiss home and return to the chat screen.
  final VoidCallback close;

  /// Seed text into the chat input without executing (prefill for
  /// seed-only quick actions like `/project `).
  final void Function(String text) seedInput;

  /// The git-status service for the `git-status` box (push liveness).
  final GitStatusService gitStatusService;

  /// Sessions + chats, merged and ordered by `updatedAt` descending —
  /// the in-memory lists from the panel, read on each build. Feeds
  /// `recent-sessions` and `yesterday`.
  final List<Session> Function() sessions;

  /// The currently-active session id (for the `▸` marker), or null.
  final int? Function() currentSessionId;

  /// Switch to a session by id. Returns `false` if refused (mid-stream);
  /// the widget keeps home open so the user sees the refusal.
  final bool Function(int sessionId) switchSession;

  /// The workspace (project) directory the app was opened on. Feeds the
  /// `workspace` box. Empty when unknown (tests/previews).
  final String projectPath;

  /// The active model's composite key (`provider/model`), or null when
  /// no provider is configured. Shown in the `workspace` box.
  final String? Function() activeModel;

  /// Summarize recent work via the auxiliary model (single round, no
  /// tools) for the `yesterday` box. [sessions] is the in-memory merged
  /// session list; the implementation walks back from yesterday (up to
  /// [AuxiliaryService.maxLookbackDays] days) to the most recent day
  /// with activity and returns the summary plus how many days back it
  /// landed. Returns `null` when no auxiliary model is configured, the
  /// call fails, or no day in the window had activity — the box then
  /// falls back to its static session list. Null callback (tests /
  /// previews) means "no summarizer", same fallback.
  final Future<YesterdaySummary?> Function(List<Session> sessions)?
      summarizeYesterday;

  /// Open a fullpane showing a skill's full SKILL.md content (the
  /// `skills` box). Null (tests / previews) means "no viewer wired" —
  /// the box's rows then do nothing on activation.
  final void Function(SkillInfo skill)? showSkill;

  /// Fetch total tokens (in + out) per local calendar day for the
  /// `activity` heatmap box. [sinceDays] bounds the lookback window.
  /// Null (tests / previews) means "no store wired" — the box renders
  /// an empty grid.
  final Future<Map<String, int>> Function({required int sinceDays})?
      dailyTokenTotals;

  /// Fetch per-local-day usage stats (tokens, turns, active-session
  /// count) for the `today` box. [sinceDays] bounds the lookback window.
  /// Null (tests / previews) means "no store wired" — the box renders
  /// its empty state.
  final Future<Map<String, DailyUsageStats>> Function({required int sinceDays})?
      dailyUsageStats;

  /// Whether any LLM provider has an API key configured. Feeds the
  /// `setup` box's first checklist row. Defaults to `false` (tests /
  /// previews render the full pending checklist).
  final bool Function() hasProviderKey;

  /// The configured auxiliary model's display name, or `null` when no
  /// auxiliary model is set (or it was set to `none`). Feeds the
  /// `setup` box's second row.
  final String? Function() auxModelName;

  /// The active UI theme's id (e.g. `"dracula"`). Feeds the `settings`
  /// box. Null (tests / previews) means "unknown".
  final String? Function() themeId;

  /// The active UI language code (`"en"` / `"zh"`). Feeds the `settings`
  /// box. Null (tests / previews) means "unknown".
  final String? Function() localeId;

  /// A string lookup bound to the active UI language, for localizing home
  /// chrome (box titles, labels, hints). Falls back to English when
  /// [localeId] is null (tests / previews).
  Strings get strings => Strings(AppLocale.fromCode(localeId()));

  /// The current session's chat display mode (`"verbose"` / `"vibe"`).
  /// Feeds the `settings` box. Null when there's no current session.
  final String? Function() viewMode;

  /// Whether at least one search-capable web provider is configured.
  /// Feeds the `setup` box's third row.
  final bool Function() hasWebProvider;

  /// The notes feature's service — reads/writes the per-project note and
  /// the `.dart_tool/my_notes.json` projection the `my-notes` box renders.
  /// Null in tests/previews where no notes feature exists; the box then
  /// shows a "no notes" placeholder.
  final NotesService? notesService;

  /// Open the notes editor fullpane (the chat panel's `_openNotesFullpane`).
  /// Null in tests/previews with no fullpane host.
  final void Function()? openNotes;

  /// All connected providers that expose a live usage surface (a coding
  /// plan or a credit balance), in provider load order. Feeds the
  /// `coding-plan` box, which shows one row per provider with the
  /// provider name. Empty (tests / previews) means "no connected
  /// providers".
  final List<ConnectedProviderUsage> Function() connectedUsageProviders;

  const HomeContext({
    required this.runCommand,
    required this.close,
    required this.seedInput,
    required this.gitStatusService,
    required this.sessions,
    required this.currentSessionId,
    required this.switchSession,
    this.projectPath = '',
    this.activeModel = _noModel,
    this.summarizeYesterday,
    this.showSkill,
    this.dailyTokenTotals,
    this.dailyUsageStats,
    this.hasProviderKey = _false,
    this.auxModelName = _nullString,
    this.themeId = _nullString,
    this.localeId = _nullString,
    this.viewMode = _nullString,
    this.hasWebProvider = _false,
    this.notesService,
    this.openNotes,
    this.connectedUsageProviders = _noConnectedUsage,
  });

  static String? _noModel() => null;
  static bool _false() => false;
  static String? _nullString() => null;
  static List<ConnectedProviderUsage> _noConnectedUsage() => const [];

  /// A no-op context for rendering the bare grid without a panel behind
  /// it (layout tests, previews). Every service is a stub: no sessions,
  /// a fresh (non-repo) git service, nothing runs. [gitStatusService] is
  /// a real instance so the widget can subscribe to it harmlessly.
  HomeContext.minimal({required this.close})
      : runCommand = ((_) => true),
        seedInput = ((_) {}),
        gitStatusService = GitStatusService(),
        sessions = (() => const <Session>[]),
        currentSessionId = (() => null),
        switchSession = ((_) => false),
        projectPath = '',
        activeModel = _noModel,
        summarizeYesterday = null,
        showSkill = null,
        dailyTokenTotals = null,
        dailyUsageStats = null,
        hasProviderKey = _false,
        auxModelName = _nullString,
        themeId = _nullString,
        localeId = _nullString,
        viewMode = _nullString,
        hasWebProvider = _false,
        notesService = null,
        openNotes = null,
        connectedUsageProviders = _noConnectedUsage;
}

/// One pluggable dashboard box.
///
/// A widget renders a bordered box inside the home grid. It declares
/// which column spans it supports, how tall it wants to be, and what
/// (if anything) happens on `enter`/click. Built-ins and TOML-defined
/// widgets both implement this interface and live in the same grid.
abstract class HomeWidget {
  /// Stable id, used as the key in the persisted layout and the
  /// registry. Built-ins own their namespace; a TOML widget whose id
  /// collides with a built-in is skipped.
  String get id;

  /// Box chrome title, rendered in the border.
  String get title;

  /// The box's title localized for [ctx]'s active language. Defaults to
  /// [title] (English) — widgets override it when their title should
  /// follow the locale (most do; `Git` and a few proper nouns stay put).
  String titleFor(HomeContext ctx) => title;

  /// Column spans this widget can render at, e.g. `{1, 2}`. The layout
  /// engine assigns the largest span that fits the current column
  /// count.
  Set<int> get supportedSpans;

  /// Minimum content height in rows for the given span. A row's height
  /// is the max of its boxes' values; shorter boxes stretch their
  /// borders to match, so widgets must render at any height ≥ this.
  int heightFor(int span);

  /// Whether a passive box's short content should be vertically centered
  /// in the box when it's stretched taller than the content. Defaults to
  /// true (a 1-line git/tokens status looks better centered than hugging
  /// the top of a tall box). Boxes whose content fills the box or manages
  /// its own scrolling (e.g. the Yesterday summary, which wraps to many
  /// lines and scrolls) return false to stay top-aligned — centering a
  /// scrollable region would break its height constraint and mis-place
  /// the content.
  bool get verticallyCenter => true;

  /// Whether the box shows at all right now. Defaults to true — every
  /// box is always visible. Override to make a box conditional on live
  /// state: the `quick-start` setup checklist returns false once every
  /// item is done, so it drops out of the grid instead of taking up a
  /// cell with an "all set" one-liner.
  ///
  /// Evaluated on each build; a hidden box stays in the placement list
  /// (and the persisted layout) — it's only filtered out of the rendered
  /// grid and keyboard navigation — so it reappears the moment the
  /// condition flips back, in its original position.
  bool visibleWhen(HomeContext ctx) => true;

  /// The box content's current scroll offset (rows scrolled out of
  /// view). Home's box chrome wraps every box in a scrollview; the
  /// scroll area writes this so box-level hover can translate a
  /// viewport row into an absolute item index. `0` when unscrolled —
  /// which is always the case for truncated lists (quick-actions,
  /// recent-sessions), so those hover calculations are unchanged.
  int boxScrollOffset = 0;

  // ── Item selection ────────────────────────────────────────────────
  //
  // Boxes that present a list of selectable options (quick-actions,
  // recent-sessions) expose them through these members so home can drive
  // ↑↓ in-box selection, ←→ box switching, Tab row jumps, and Enter/click
  // per item. Passive boxes (git, tokens, yesterday, workspace) keep the
  // defaults and stay non-interactive.

  /// How many selectable items the box currently shows. `0` (the
  /// default) means the box has no items — home treats it as passive:
  /// ↑↓ skip past it to the next row and Enter falls back to
  /// [activate]. Recomputed on each build, so a box whose list grows or
  /// empties stays correct.
  int get itemCount => 0;

  /// The currently-highlighted item, owned by the widget (it knows its
  /// list). Home reads this to tell the widget which box is focused (via
  /// [build]'s `focused` arg); the widget renders the highlight only when
  /// focused.
  int get selectedIndex => 0;

  /// Move the highlight by [delta] (+1/-1) within the item list, with
  /// wraparound. Only called when [itemCount] > 0.
  void moveSelection(int delta) {}

  /// Move the highlight to the absolute item [index] (mouse hover). The
  /// home screen's box-level hover computes the row under the cursor and
  /// calls this. Returns `false` when [index] is out of range (hover over
  /// the box border / padding), so the caller can ignore it. The widget
  /// must only accept in-range indices.
  bool selectItemAt(int index) => false;

  /// Reset the highlight to the first item. Called when the box gains
  /// focus so a revisited box starts predictable.
  void resetSelection() {}

  /// Activate item [index] (Enter or per-item click). Return `null` for
  /// items that do nothing; the default routes to [activate] so legacy
  /// single-action boxes keep working. When this returns `null` *and*
  /// [itemCount] is 0, home's box-level Enter/click is a no-op.
  void Function()? activateItem(HomeContext ctx, int index) =>
      activate(ctx);

  /// Primary action for the whole box (Enter/click when the box has no
  /// selectable items). Return `null` for a passive box (no-op on
  /// activation). Returning a callback marks the box actionable (shown in
  /// the key legend / hover).
  void Function()? activate(HomeContext ctx);

  /// Render the box *content* (the border/title chrome is the grid's
  /// job, not the widget's). [focused] tells the widget whether its box
  /// currently holds home's focus — item-based boxes render their
  /// selection highlight only when focused so two boxes never show a
  /// highlight at once.
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  });

  // ── Title buttons & change notification ──────────────────────────
  //
  // Home caches its widget list across builds (the widgets are stateful
  // objects owned by home), so a widget that mutates its own state —
  // e.g. the yesterday box's day navigation — needs a way to (a) tell
  // home to rebuild and (b) hand home the title-row buttons to render.
  // These two members provide that without making HomeWidget a
  // nocterm Component.

  /// Small buttons rendered on the box's title row, after the title
  /// text (e.g. the yesterday box's `‹ ›` day navigation). Home lays
  /// them out and wires the taps; a null/empty list renders nothing.
  /// A button with a null [HomeTitleButton.onPressed] renders dimmed
  /// (disabled). Recomputed on each build, so enabled/disabled tracks
  /// the widget's state.
    List<HomeTitleButton>? get titleButtons => null;

  /// Whether the box has title buttons to render ([titleButtons] is
  /// non-empty). Home uses this to budget an extra title-row cell in
  /// the box height and to pick between the painted border title and
  /// the interactive component title row.
  bool get hasTitleButtons => titleButtons != null && titleButtons!.isNotEmpty;

  /// Rebuild notification. A stateful widget calls its listener when
  /// its title/content/buttons changed and home should re-run `build`.
  /// Home subscribes in `initState` (one listener per widget) and
  /// routes it to `setState`. Widgets that never change after first
  /// render (most) leave this null.
  void Function()? onChanged;

  /// Notify home (via [onChanged]) that this widget's state changed.
  void notifyChanged() => onChanged?.call();
}

/// A small tappable button shown in a box's title row. [label] is the
/// 1-2 char glyph (`‹`, `›`); [onPressed] is null when the action is
/// unavailable (rendered dimmed, taps ignored).
class HomeTitleButton {
  final String label;
  final void Function()? onPressed;
  const HomeTitleButton({required this.label, required this.onPressed});
}

/// The set of registered home widgets, keyed by [HomeWidget.id].
///
/// Same shape as `ToolRegistry`: built-ins register at startup, and
/// TOML-defined widgets register through the same path so built-in and
/// custom boxes live in the same grid and are rearranged identically.
class HomeWidgetRegistry {
  final Map<String, HomeWidget> _widgets = {};

  /// Register [widget]. Returns `false` (and keeps the existing entry)
  /// if a widget with the same id is already registered — first
  /// registration wins, which gives built-ins their namespace and gives
  /// project TOML widgets precedence over global ones when discovery
  /// registers project first.
  bool register(HomeWidget widget) {
    if (_widgets.containsKey(widget.id)) return false;
    _widgets[widget.id] = widget;
    return true;
  }

  HomeWidget? operator [](String id) => _widgets[id];

  /// All registered widgets, in registration order.
  List<HomeWidget> get widgets => List.unmodifiable(_widgets.values);

  int get length => _widgets.length;

  bool contains(String id) => _widgets.containsKey(id);
}

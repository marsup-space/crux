import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../models/session.dart';
import '../../../services/auxiliary_service.dart'
    show AuxiliaryService, YesterdaySummary, yesterdayLabelForDaysAgo;
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `yesterday` box — an auxiliary-model summary of what you worked
/// on most recently.
///
/// The box opens on the most recent day with any session activity,
/// walking back from yesterday up to [AuxiliaryService.maxLookbackDays].
/// Two title buttons navigate the window: `‹` steps to the previous
/// (older) day, `›` steps back toward the most recent active day. The
/// title always names the day being shown — "Yesterday", "2 days ago",
/// … — so it doubles as the position indicator.
///
/// When [HomeContext.summarizeYesterday] is wired (the real panel), the
/// box kicks off one single-round LLM call (no tools) for the day being
/// shown and displays the returned bullets. Each day's result is cached
/// on the widget, so stepping back and forth doesn't re-call the model.
/// While a call is in flight the box shows a "Summarizing…" line; if it
/// returns null (no auxiliary model / failure) it falls back to the
/// static session list for that day so the box is never empty. When the
/// callback is null (tests / previews) only the static list renders.
///
/// The service additionally caches each day's summary on disk (keyed by
/// the day-set fingerprint), so re-opening home the same day doesn't
/// re-call the model even across restarts.
///
/// Interaction: the box stays *passive* in home's item-selection sense
/// (no selectable rows, `activate` is null). The `‹ ›` buttons live in
/// the title (see [titleButtons]); home renders them on the title row
/// and maps the `[` / `]` keys to [goBack] / [goLatest] while the box
/// is focused.
class YesterdayHomeWidget extends HomeWidget {
  /// Sessions + chats, merged by the caller.
  final List<Session> Function() sessions;

  /// Injectable clock for tests.
  final DateTime Function() _now;

  YesterdayHomeWidget({
    required this.sessions,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  @override
  String get id => 'yesterday';

  /// Navigation override: null means "follow the most recent active
  /// day" (the default on open). Set by [goBack] / [goLatest]; cleared
  /// when navigation returns to the latest day, so the box follows new
  /// activity again.
  int? _navigatedDay;

  /// Per-day summary cache, so navigating back to an already-fetched
  /// day doesn't re-call the model (and shows its bullets instantly).
  final Map<int, YesterdaySummary> _summaryCache = {};

  /// Per-day request tracking, keyed by day so a result landing for a
  /// day we've navigated away from is cached but not shown.
  final Set<int> _requestedDays = {};

  /// The most recent day with any session activity (1..7), or null when
  /// nothing in the window was active. Recomputed on each access: the
  /// session list is in-memory and small, and the title getters read
  /// this OUTSIDE the build phase — state resolved later (e.g. on first
  /// build) would paint a stale first frame.
  int? get _latestActiveDay {
    for (var d = 1; d <= AuxiliaryService.maxLookbackDays; d++) {
      if (_sessionsOn(d).isNotEmpty) return d;
    }
    return null;
  }

  /// The day being shown: the navigated day when the user has
  /// navigated, else the most recent active day (yesterday when the
  /// whole week is empty).
  int get _daysAgo => _navigatedDay ?? _latestActiveDay ?? 1;

  @override
  String get title {
    final label = yesterdayLabelForDaysAgo(_daysAgo);
    return label[0].toUpperCase() + label.substring(1);
  }

  @override
  String titleFor(HomeContext ctx) {
    final label = _daysAgo == 1
        ? ctx.strings.t('home.day.yesterday')
        : ctx.strings.t('home.day.daysAgo', {'n': '$_daysAgo'});
    return label[0].toUpperCase() + label.substring(1);
  }

  /// The day being shown, for the title buttons / content.
  int get daysAgo => _daysAgo;

  /// Whether `‹` can step to an older day (not yet at the window edge).
  bool get canGoBack => _daysAgo < AuxiliaryService.maxLookbackDays;

  /// Whether `›` can step toward the most recent active day.
  bool get canGoLatest {
    final latest = _latestActiveDay;
    return latest != null && _daysAgo > latest;
  }

  /// The title buttons (`‹` older, `›` latest). Home renders them after
  /// the title text on the box's title row and wires the taps. Null
  /// when there's no activity in the whole window (nothing to
  /// navigate).
  @override
  List<HomeTitleButton>? get titleButtons {
    if (_latestActiveDay == null) return null;
    return [
      HomeTitleButton(
        label: '‹',
        onPressed: canGoBack ? goBack : null,
      ),
      HomeTitleButton(
        label: '›',
        onPressed: canGoLatest ? goLatest : null,
      ),
    ];
  }

  /// Step to the previous (older) day. No-op at the window edge.
  void goBack() {
    if (!canGoBack) return;
    _navigatedDay = _daysAgo + 1;
    notifyChanged();
  }

  /// Step back toward the most recent active day by one. No-op when
  /// already there. (Named for the button direction: `›` moves toward
  /// the latest.) Reaching the latest day clears the override so the
  /// box follows the latest again if new activity lands.
  void goLatest() {
    if (!canGoLatest) return;
    final next = _daysAgo - 1;
    _navigatedDay = next <= (_latestActiveDay ?? 1) ? null : next;
    notifyChanged();
  }

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// Taller than the other boxes — the summary wraps to several lines
  /// and the box scrolls, so it wants the room. 8 content rows (+2
  /// border) is enough to show a multi-line summary with scroll afford.
  @override
  int heightFor(int span) => 8;

  /// The summary scrolls — centering it would break the scrollview's
  /// height constraint and mis-place wrapped lines.
  @override
  bool get verticallyCenter => false;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  /// Sessions active on the day [daysAgo] back (local midnight-to-
  /// midnight), most-recent first.
  List<Session> _sessionsOn(int daysAgo) {
    final now = _now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final dayStart = todayStart.subtract(Duration(days: daysAgo));
    final dayEnd = todayStart.subtract(Duration(days: daysAgo - 1));
    final list = sessions().where((s) {
      final u = s.updatedAt;
      return !u.isBefore(dayStart) && u.isBefore(dayEnd);
    }).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final daysAgo = _daysAgo;
    final daySessions = _sessionsOn(daysAgo);
    final summarize = ctx.summarizeYesterday;

    // Kick the summary call for this day once. The service resolves the
    // same day window itself, so the result's `daysAgo` matches ours.
    YesterdaySummary? summary;
    var pending = false;
    if (summarize != null) {
      summary = _summaryCache[daysAgo];
      if (summary == null) {
        if (!_requestedDays.contains(daysAgo)) {
          _requestedDays.add(daysAgo);
          summarize(sessions()).then((result) {
            if (result != null) _summaryCache[result.daysAgo] = result;
            // Re-render whether or not we're still showing this day —
            // the cache write makes the bullets appear (and makes a
            // future navigation back to this day instant).
            notifyChanged();
          });
        }
        pending = true;
      }
    }

    return _YesterdayView(
      sessions: daySessions,
      daysAgo: daysAgo,
      summary: summary?.text,
      pending: pending,
      strings: ctx.strings,
    );
  }
}

/// The day view: summary bullets (when available), else a pending hint,
/// else the static session list for the day. Stateless — all the async
/// and navigation state lives on the [YesterdayHomeWidget] (which home
/// owns across builds), so navigation and late-arriving summaries just
/// re-render this with new inputs.
class _YesterdayView extends StatelessComponent {
  /// The shown day's sessions (the static fallback list).
  final List<Session> sessions;

  /// How many days back the shown day is (`1` = yesterday).
  final int daysAgo;

  /// The fetched summary for this day, or null when not (yet) available.
  final String? summary;

  /// True while the summary call for this day is in flight.
  final bool pending;

  final Strings strings;

  const _YesterdayView({
    required this.sessions,
    required this.daysAgo,
    required this.summary,
    required this.pending,
    required this.strings,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final dayLabel = daysAgo == 1
        ? strings.t('home.day.yesterday')
        : strings.t('home.day.daysAgo', {'n': '$daysAgo'});

    // 1. Summary available → the bullets, wrapped and scrollable.
    final summaryText = summary;
    if (summaryText != null) {
      final lines = summaryText
          .split(RegExp(r'\r\n|\r|\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      // softWrap: true lets each bullet wrap to the box width (no
      // ellipsis — the full text is the point). Scrolling is the box
      // chrome's job (_BoxScrollArea wraps every box in a scrollview),
      // so this stays a plain top-aligned column — a taller-than-box
      // summary just scrolls.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Row(
              children: [
                Expanded(
                  child: Text(
                    line,
                    softWrap: true,
                    style: TextStyle(color: theme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
        ],
      );
    }

    // 2. Call still in flight → a one-line pending hint.
    if (pending) {
      return Text(
        strings.t('home.yesterday.summarizing', {'day': dayLabel}),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    // 3. No summary → the static fallback list for the day.
    return _buildFallback(theme, dayLabel);
  }

  Component _buildFallback(CruxThemeData theme, String dayLabel) {
    if (sessions.isEmpty) {
      return Text(
        strings.t('home.yesterday.nothing', {'day': dayLabel}),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final children = <Component>[
      Text(
        strings.t(
          sessions.length == 1
              ? 'home.yesterday.sessionActive'
              : 'home.yesterday.sessionsActive',
          {'n': '${sessions.length}'},
        ),
        style: TextStyle(
          color: theme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    ];

    // Show a couple of the most recent titles as a memory jog. Same
    // width-bound need as the summary bullets — a bare Text here would
    // overflow the border on a long title.
    for (final s in sessions.take(2)) {
      children.add(
        Row(
          children: [
            Expanded(
              child: Text(
                '· ${s.title.isEmpty ? s.displayId : s.title}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.onSurfaceDim),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

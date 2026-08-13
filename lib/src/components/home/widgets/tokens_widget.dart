import 'package:nocterm/nocterm.dart';

import '../../../models/daily_usage_stats.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `today` box — a day's activity at a glance, with `‹ ›` title
/// navigation to walk the calendar.
///
/// Data source: [HomeContext.dailyUsageStats] (one SQL aggregate over
/// this workspace's messages, keyed by local calendar day). The box
/// defaults to **today** (`0` days back); `‹` steps to the previous
/// day, `›` steps back toward today, and the title names the day —
/// "Today", "Yesterday", "2 days ago", …, or the `MM-DD` date beyond a
/// week.
///
/// Shows three per-day metrics:
///   * **tokens** — total tokens (in + out) spent.
///   * **turns** — conversation turns (`role: 'user'` messages).
///   * **sessions** — distinct sessions with activity that day.
///
/// The whole daily-stats map is fetched once (one cheap query) and
/// cached on the widget, so stepping through days is instant. The same
/// `‹ ›` title-button + `[`/`]`-key setup as the `yesterday` box drives
/// navigation; home renders the buttons and keys for any widget
/// exposing [titleButtons].
///
/// Passive box — `activate` returns null; there's no primary action.
class TokensHomeWidget extends HomeWidget {
  /// Injectable clock for tests.
  final DateTime Function() _now;

  /// Injectable data source. Defaults to reading through the context;
  /// tests inject a fixed map.
  final Future<Map<String, DailyUsageStats>> Function(HomeContext ctx)?
      _loaderOverride;

  TokensHomeWidget({
    DateTime Function()? now,
    Future<Map<String, DailyUsageStats>> Function(HomeContext ctx)? loader,
  })  : _now = now ?? DateTime.now,
        _loaderOverride = loader;

  @override
  String get id => 'tokens';

  /// Navigation override: null means "today" (the default). Set by
  /// [goBack] / [goForward]; cleared when navigation returns to today
  /// so the box follows the current day again.
  int? _navigatedDay;

  /// The fetched daily stats (`'yyyy-MM-dd'` → [DailyUsageStats]), or
  /// null while the query is in flight. Cached for the box's life.
  Map<String, DailyUsageStats>? _stats;

  /// True once the query has settled.
  bool _settled = false;

  bool _requested = false;

  /// How many days back the shown day is: `0` = today, `1` = yesterday.
  int get _daysAgo => _navigatedDay ?? 0;

  /// The day being shown, for the title buttons / tests.
  int get daysAgo => _daysAgo;

  /// Today at local midnight — the anchor for the day navigation.
  DateTime get _todayStart {
    final n = _now();
    return DateTime(n.year, n.month, n.day);
  }

  /// `'yyyy-MM-dd'` bucket key for the shown day — mirrors the SQL
  /// `date(created_at/1000, 'unixepoch', 'localtime')` grouping.
  String get _dayKey {
    final d = _todayStart.subtract(Duration(days: _daysAgo));
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// The title names the shown day: Today / Yesterday / N days ago /
  /// MM-DD beyond a week.
  @override
  String get title {
    final d = _daysAgo;
    if (d == 0) return 'Today';
    if (d == 1) return 'Yesterday';
    if (d <= 7) return '$d days ago';
    final date = _todayStart.subtract(Duration(days: d));
    return '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  bool get _canGoBack => true; // calendar history is effectively unbounded
  bool get _canGoForward => _daysAgo > 0;

  /// The title buttons (`‹` previous day, `›` toward today). Home
  /// renders them after the title text and wires the taps; the `[`/`]`
  /// keys drive the same moves while the box is focused.
  @override
  List<HomeTitleButton>? get titleButtons => [
        HomeTitleButton(label: '‹', onPressed: _canGoBack ? goBack : null),
        HomeTitleButton(label: '›', onPressed: _canGoForward ? goForward : null),
      ];

  /// Step to the previous (older) day.
  void goBack() {
    _navigatedDay = _daysAgo + 1;
    notifyChanged();
  }

  /// Step toward today. Reaching today clears the override so the box
  /// tracks the current day again.
  void goForward() {
    if (!_canGoForward) return;
    final next = _daysAgo - 1;
    _navigatedDay = next <= 0 ? null : next;
    notifyChanged();
  }

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 5;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  Future<Map<String, DailyUsageStats>> _load(HomeContext ctx) {
    final override = _loaderOverride;
    if (override != null) return override(ctx);
    final fetch = ctx.dailyUsageStats;
    if (fetch == null) return Future.value(const {});
    // A year + a week so the box can walk back through any realistic
    // history; the query is a single cheap aggregate.
    return fetch(sinceDays: 371);
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    if (!_requested) {
      _requested = true;
      _load(ctx).then((stats) {
        _stats = stats;
        _settled = true;
        notifyChanged();
      });
    }

    final theme = CruxTheme.of(context);

    if (!_settled) {
      return Text(
        'loading…',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final stats = _stats?[_dayKey];
    if (stats == null || stats.isEmpty) {
      return Text(
        'no activity',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(theme, 'tokens', _fmt(stats.tokens)),
        _row(theme, 'turns', '${stats.turns}'),
        _row(theme, 'sessions', '${stats.sessions}'),
      ],
    );
  }

  Component _row(CruxThemeData theme, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label  ', style: TextStyle(color: theme.onSurfaceDim)),
        Text(value, style: TextStyle(color: theme.onSurfaceVariant)),
      ],
    );
  }

  /// Comma-group a token count for readability (e.g. `12,800`).
  static String _fmt(int n) => n.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );
}

import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../models/daily_usage_stats.dart';
import '../../../theme/crux_theme.dart';
import '../../../utils/text_width.dart';
import '../../../utils/token_format.dart';
import '../home_widgets.dart';

/// The `today` box — a day's **per-model token usage** as horizontal
/// bars, with `‹ ›` title navigation to walk the calendar.
///
/// Data source: [HomeContext.dailyUsageStats] (one SQL aggregate over
/// this workspace's messages, keyed by local calendar day, plus a
/// per-model breakdown). The box defaults to **today** (`0` days back);
/// `‹` steps to the previous day, `›` steps back toward today, and the
/// title names the day — "Today", "Yesterday", "2 days ago", …, or the
/// `MM-DD` date beyond a week.
///
/// One bar per model that spent tokens that day, longest bar first,
/// each labelled with its model id and a compact count (`12.8k`). Bars
/// scale linearly against the busiest model. More models than fit the
/// box simply scroll — every box's content lives in the grid chrome's
/// scrollview ([_BoxScrollArea] on the home screen), so an overflowing
/// chart scrolls instead of clipping.
///
/// Days whose data predates per-model tracking (or tests injecting a
/// bare [DailyUsageStats]) have an empty `byModel`; the box falls back
/// to the plain totals view rather than showing a misleading single
/// unlabeled bar.
///
/// The async load lives in the view's [State] (setState-driven), like
/// the activity heatmap's `_ActivityView` — a bare `build` +
/// `notifyChanged` would leave the box stuck on its loading hint
/// wherever nothing subscribes to [HomeWidget.onChanged].
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

  /// How many days back the shown day is: `0` = today, `1` = yesterday.
  int get _daysAgo => _navigatedDay ?? 0;

  /// The day being shown, for the title buttons / tests.
  int get daysAgo => _daysAgo;

  /// Today at local midnight — the anchor for the day navigation.
  DateTime get _todayStart {
    final n = _now();
    return DateTime(n.year, n.month, n.day);
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

  @override
  String titleFor(HomeContext ctx) {
    final s = ctx.strings;
    final d = _daysAgo;
    if (d == 0) return s.t('home.day.today');
    if (d == 1) return s.t('home.day.yesterday');
    if (d <= 7) return s.t('home.day.daysAgo', {'n': '$d'});
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

  /// The bar chart fills the box and scrolls within it — top-aligned,
  /// never vertically centered (centering an overflowing chart inside
  /// the scroll area would mis-place the first rows).
  @override
  bool get verticallyCenter => false;

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
    return _TokensView(
      loader: () => _load(ctx),
      daysAgo: _daysAgo,
      now: _now,
      strings: ctx.strings,
    );
  }
}

/// Stateful view owning the async load (setState-driven, like the
/// activity heatmap's `_ActivityView`) and the shown-day lookup.
class _TokensView extends StatefulComponent {
  final Future<Map<String, DailyUsageStats>> Function() loader;

  /// How many days back the shown day is (`0` = today).
  final int daysAgo;

  /// Injectable clock (the owner widget's).
  final DateTime Function() now;

  final Strings strings;

  const _TokensView({
    required this.loader,
    required this.daysAgo,
    required this.now,
    required this.strings,
  });

  @override
  State<_TokensView> createState() => _TokensViewState();
}

class _TokensViewState extends State<_TokensView> {
  /// The fetched daily stats (`'yyyy-MM-dd'` → [DailyUsageStats]), or
  /// null while the query is in flight. One map covers every navigable
  /// day, so day navigation only changes the lookup key, not the state.
  Map<String, DailyUsageStats>? _stats;

  /// True once the query has settled.
  bool _settled = false;

  bool _requested = false;

  @override
  void initState() {
    super.initState();
    if (_requested) return;
    _requested = true;
    component.loader().then((stats) {
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _settled = true;
      });
    });
  }

  /// `'yyyy-MM-dd'` bucket key for the shown day — mirrors the SQL
  /// `date(created_at/1000, 'unixepoch', 'localtime')` grouping.
  String get _dayKey {
    final n = component.now();
    final d = DateTime(n.year, n.month, n.day)
        .subtract(Duration(days: component.daysAgo));
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    if (!_settled) {
      return Text(
        component.strings.t('home.tokens.loading'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final stats = _stats?[_dayKey];
    if (stats == null || stats.isEmpty) {
      return Text(
        component.strings.t('home.tokens.noActivity'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    // No per-model breakdown (legacy rows / bare test fixtures):
    // plain totals beat a fake single bar.
    if (stats.byModel.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(theme, component.strings.t('home.tokens.tokens'),
              _fmt(stats.tokens)),
          _row(theme, component.strings.t('home.tokens.turns'),
              '${stats.turns}'),
          _row(theme, component.strings.t('home.tokens.sessions'),
              '${stats.sessions}'),
        ],
      );
    }

    return _ModelBars(
      stats: stats,
      theme: theme,
      strings: component.strings,
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

/// The pure rendering half — takes a settled [DailyUsageStats] and
/// paints one horizontal bar per model. Split out so tests can pump it
/// without the async hop.
class _ModelBars extends StatelessComponent {
  final DailyUsageStats stats;
  final CruxThemeData theme;
  final Strings strings;

  const _ModelBars({
    required this.stats,
    required this.theme,
    required this.strings,
  });

  /// Label column width (terminal columns). Model ids longer than this
  /// truncate with `…` — the full id lives in the session's `/model`,
  /// the bar only needs to disambiguate at a glance.
  static const _labelWidth = 14;

  /// Bar track width. Longest-bar-first ordering makes the top bar
  /// always full-width; everything else shades against it.
  static const _barWidth = 10;

  /// Models, busiest first (ties broken by id for a stable order).
  List<MapEntry<String, int>> get _sorted {
    final entries = stats.byModel.entries.toList()
      ..sort((a, b) {
        final byTokens = b.value.compareTo(a.value);
        if (byTokens != 0) return byTokens;
        return a.key.compareTo(b.key);
      });
    return entries;
  }

  @override
  Component build(BuildContext context) {
    final models = _sorted;
    // The ceiling every bar scales against: the busiest model. All
    // values are > 0 (the query drops zero rows), so no divide-by-zero.
    final ceiling = models.first.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final m in models) _bar(m.key, m.value, ceiling),
        _summary(),
      ],
    );
  }

  Component _bar(String model, int tokens, int ceiling) {
    final filled =
        ((tokens / ceiling) * _barWidth).round().clamp(0, _barWidth);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _fit(model, _labelWidth),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
        const Text(' '),
        Text(
          '█' * filled + '░' * (_barWidth - filled),
          style: TextStyle(color: theme.success),
        ),
        Text(
          ' ${formatTokensCompact(tokens)}',
          style: TextStyle(color: theme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Trailing one-liner keeping the box's non-token metrics visible
  /// (they'd otherwise vanish with the old three-row layout).
  Component _summary() {
    return Text(
      '${strings.t('home.tokens.turns')} ${stats.turns}'
      ' · '
      '${strings.t('home.tokens.sessions')} ${stats.sessions}',
      style: TextStyle(color: theme.onSurfaceDim),
    );
  }

  /// Fit [text] into [maxWidth] terminal columns, appending `…` and
  /// truncating by display width (not code units) when it doesn't fit.
  /// Measured with [stringWidth] so CJK model labels truncate honestly.
  static String _fit(String text, int maxWidth) {
    if (stringWidth(text) <= maxWidth) return padToWidth(text, maxWidth);
    var out = '';
    for (final rune in text.runes) {
      final candidate = out + String.fromCharCode(rune);
      if (stringWidth(candidate) > maxWidth - 1) break; // 1 col for `…`
      out = candidate;
    }
    return padToWidth('$out…', maxWidth);
  }
}

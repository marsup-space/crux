import 'package:nocterm/nocterm.dart';

import '../../surface_host.dart';
import '../../../i18n/strings.dart';
import '../../../models/daily_usage_stats.dart';
import '../../../services/a2ui/basic_catalog_items.dart';
import '../../../services/a2ui/models.dart';
import '../../../services/a2ui/surface_builder.dart';
import '../../../theme/crux_theme.dart';
import '../../../utils/token_format.dart';
import '../home_widgets.dart';

final _tokensSurfaceCatalog = createBasicCatalog();

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
/// **Empty-today fallback:** when the shown default day (today) has no
/// recorded activity but some earlier day does, the box seeds its
/// navigation back to the most recent day-with-activity — opening on a
/// real chart instead of a dead "暂无活动" placeholder. Seeding only
/// applies before the user navigates (`‹ ›` win immediately), and an
/// all-empty window still shows the placeholder honestly.
///
/// One bar per model that spent tokens that day, longest bar first,
/// each labelled with the model's display name and a compact count
/// (`12.8k`). Bars scale linearly against the busiest model. More
/// models than fit the box simply scroll — every box's content lives
/// in the grid chrome's scrollview ([_BoxScrollArea] on the home
/// screen), so an overflowing chart scrolls instead of clipping.
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
  }) : _now = now ?? DateTime.now,
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

  /// Seed the shown day when the stats query settles (called once by
  /// the view, right after the loader resolves). While navigation is
  /// untouched — i.e. today is still the shown default — an
  /// activity-less today falls back to the **most recent earlier day
  /// with activity**, so the box opens on the user's last working day
  /// rather than the "暂无活动" placeholder. Manual `‹ ›` navigation
  /// always wins: this never overrides a set [_navigatedDay]. An
  /// entirely empty window leaves the box on today with the honest
  /// placeholder.
  void _seedFallbackDay(Map<String, DailyUsageStats> stats) {
    if (_navigatedDay != null) return;
    final today = _todayStart;
    DateTime? latestActive;
    stats.forEach((key, s) {
      if (s.isEmpty) return;
      final day = DateTime.tryParse(
        key,
      )?.toLocal(); // bucket keys are local days
      if (day == null || day.isAfter(today)) return;
      if (latestActive == null || day.isAfter(latestActive!)) {
        latestActive = day;
      }
    });
    if (latestActive == null) return;
    // Local-midnight to local-midnight; round() absorbs DST-shifted
    // 23h/25h days instead of truncating to 0/-1.
    final gap = (today.difference(latestActive!).inHours / 24).round();
    if (gap <= 0) return; // today itself has activity — nothing to do
    _navigatedDay = gap;
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
      owner: this,
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

  /// The owning [TokensHomeWidget] — day navigation lives on it, so
  /// the loader callback can seed the fallback day there.
  final TokensHomeWidget owner;

  /// How many days back the shown day is (`0` = today).
  final int daysAgo;

  /// Injectable clock (the owner widget's).
  final DateTime Function() now;

  final Strings strings;

  const _TokensView({
    required this.loader,
    required this.owner,
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
      // Seed the shown day before the first paint of the settled data
      // (no-op when today has activity or the user already navigated).
      component.owner._seedFallbackDay(stats);
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
    final d = DateTime(
      n.year,
      n.month,
      n.day,
    ).subtract(Duration(days: component.daysAgo));
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Component build(BuildContext context) {
    if (!_settled) {
      return Text(
        component.strings.t('home.tokens.loading'),
        style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
      );
    }

    final stats = _stats?[_dayKey];
    if (stats == null || stats.isEmpty) {
      return Text(
        component.strings.t('home.tokens.noActivity'),
        style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
      );
    }

    // No per-model breakdown (legacy rows / bare test fixtures):
    // plain totals beat a fake single bar.
    if (stats.byModel.isEmpty) {
      final surface = SurfaceBuilder(surfaceId: 'home.tokens.totals')
        ..column('root', ['tokens', 'turns', 'sessions'])
        ..keyValue(
          'tokens',
          label: component.strings.t('home.tokens.tokens'),
          value: _fmt(stats.tokens),
        )
        ..keyValue(
          'turns',
          label: component.strings.t('home.tokens.turns'),
          value: '${stats.turns}',
        )
        ..keyValue(
          'sessions',
          label: component.strings.t('home.tokens.sessions'),
          value: '${stats.sessions}',
        );
      return _surface(surface.build());
    }

    final models = stats.byModel.entries.toList()
      ..sort((a, b) {
        final byTokens = b.value.compareTo(a.value);
        return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
      });
    final ceiling = models.first.value;
    final rows = models
        .map(
          (model) => <String, dynamic>{
            'label': model.key,
            'value': model.value / ceiling,
            'detail': formatTokensCompact(model.value),
          },
        )
        .toList(growable: false);
    final surface = SurfaceBuilder(surfaceId: 'home.tokens.models')
      ..column('root', ['bars', 'summary'])
      ..barList('bars', rows)
      ..text(
        'summary',
        '${component.strings.t('home.tokens.turns')} ${stats.turns}'
            ' · '
            '${component.strings.t('home.tokens.sessions')} ${stats.sessions}',
      );
    return _surface(surface.build());
  }

  Component _surface(CreateSurface declaration) => SurfaceHost(
    declaration: declaration,
    catalog: _tokensSurfaceCatalog,
    instanceKey: declaration.surfaceId,
    retainState: false,
    submitOnAction: false,
    strings: component.strings,
  );

  /// Comma-group a token count for readability (e.g. `12,800`).
  static String _fmt(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );
}

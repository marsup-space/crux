import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../theme/crux_theme.dart';
import '../../../utils/text_width.dart';
import '../home_widgets.dart';

/// One day's token total, keyed by local calendar day.
///
/// The map key is `'YYYY-MM-DD'` — the same string the SQL `date()`
/// bucket produces, so the widget can look up a rendered cell with a
/// plain format, no DateTime round-trip.
typedef DailyTokens = Map<String, int>;

/// The `activity` box — a heatmap of token usage per day, laid out for
/// the terminal rather than cloned from GitHub's web grid.
///
/// Layout: **columns are the 7 weekdays (Mon–Sun), rows are the last 4
/// weeks** — the transpose of GitHub's weeks-as-columns. A TUI is wide
/// and short, so a compact 4×7 grid reads at a glance without
/// scrolling. Each day is a 2-col block cell.
///
/// Intensity: continuous, **linear** against a ceiling equal to the
/// busiest day in the window — so the legend's "more" always means a
/// real, current maximum, and a half-peak day renders half as green.
/// (A log scale was tried first: token usage can span orders of
/// magnitude, but in practice a project's days cluster within one or
/// two, and the log compression turned the whole grid uniform green.)
/// An empty window falls back to [defaultCeiling] (100M tokens).
///
/// Data comes from [HomeContext.dailyTokenTotals]; while the query is
/// in flight the box shows a one-line hint, and when no store is wired
/// (tests / previews) it renders an empty grid. Passive box —
/// `activate` returns null.
class ActivityHomeWidget extends HomeWidget {
  /// Fallback ceiling (tokens/day) when the window has no data at
  /// all. With data, the ceiling is the busiest day in the window.
  static const defaultCeiling = 100000000;

  /// Weeks of history to render.
  static const weeks = 4;

  /// Injectable data source. Defaults to reading through the context;
  /// tests inject a fixed map.
  final Future<DailyTokens> Function(HomeContext ctx)? _loaderOverride;

  ActivityHomeWidget({Future<DailyTokens> Function(HomeContext ctx)? loader})
      : _loaderOverride = loader;

  @override
  String get id => 'activity';

  @override
  String get title => 'Activity';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.activity');

  @override
  Set<int> get supportedSpans => const {1};

  /// 4 week rows + weekday header + legend.
  @override
  int heightFor(int span) => 6;

  /// The heatmap is a fixed-width grid: a 5-col week gutter plus 7 ×
  /// 3-col day cells (26), and the per-week `total` column needs ~8
  /// more to render in full. The box holds this width and never
  /// shrinks — narrower, the grid and labels collide into an
  /// unreadable smear — so the layout keeps it rigid and lets the
  /// other boxes on its row give way instead.
  @override
  int get minColumnWidth => 34;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  Future<DailyTokens> _load(HomeContext ctx) {
    final override = _loaderOverride;
    if (override != null) return override(ctx);
    final fetch = ctx.dailyTokenTotals;
    if (fetch == null) return Future.value(const {});
    // 4 weeks + the partial current week back to its Monday.
    return fetch(sinceDays: weeks * 7 + 7);
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _ActivityView(loader: () => _load(ctx), strings: ctx.strings);
  }
}

/// Stateful view so the async totals can land after first build.
class _ActivityView extends StatefulComponent {
  final Future<DailyTokens> Function() loader;
  final Strings strings;

  const _ActivityView({required this.loader, required this.strings});

  @override
  State<_ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<_ActivityView> {
  DailyTokens _totals = const {};

  /// True once the query has settled, so the view swaps its loading
  /// hint for the grid.
  bool _settled = false;

  bool _requested = false;

  @override
  void initState() {
    super.initState();
    if (_requested) return;
    _requested = true;
    component.loader().then((totals) {
      if (!mounted) return;
      setState(() {
        _totals = totals;
        _settled = true;
      });
    });
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    if (!_settled) {
      return Text(
        component.strings.t('home.activity.counting'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }
    return _ActivityGrid(totals: _totals, theme: theme, strings: component.strings);
  }
}

/// The pure rendering half — takes a settled [DailyTokens] and paints
/// the heatmap. Split out so tests can pump it without the async hop.
class _ActivityGrid extends StatelessComponent {
  final DailyTokens totals;
  final CruxThemeData theme;
  final Strings strings;

  const _ActivityGrid({
    required this.totals,
    required this.theme,
    required this.strings,
  });

  /// Local-midnight DateTime for today.
  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// `'YYYY-MM-DD'` — mirrors the SQL `date()` bucket key.
  static String _dayKey(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// The ceiling the brightest cell maps to: the busiest day in the
  /// **rendered window** ([since] through today), so "more" is always
  /// a real, current maximum and every other day shades relative to
  /// it. The query fetches a few days more than the grid renders
  /// (whole-week headroom), and those extra days must NOT raise the
  /// ceiling — otherwise a busy day that has already scrolled off the
  /// grid would keep every visible cell pale. An empty window falls
  /// back to [ActivityHomeWidget.defaultCeiling] so the legend still
  /// has a sensible endpoint.
  int _ceilingFor(DateTime since) {
    var max = 0;
    for (final e in totals.entries) {
      final day = DateTime.parse(e.key);
      if (day.isBefore(since)) continue;
      if (e.value > max) max = e.value;
    }
    return max > 0 ? max : ActivityHomeWidget.defaultCeiling;
  }

  /// Fraction of the ceiling a token count reaches (0.0 = no tokens,
  /// 1.0 = at/above the ceiling). Linear: within one project the
  /// day-to-day spread is usually one order of magnitude or two, and
  /// there a log scale compresses every day into the dark-green end —
  /// a 500k day renders at ~80% of a 14M ceiling, so the whole grid
  /// reads as uniform green and no day stands out. Linear keeps the
  /// color proportional to the actual work: a half-peak day is half
  /// as green, and a rounding-error day honestly reads near-empty.
  static double intensityFor(int tokens, int ceiling) {
    if (tokens <= 0) return 0.0;
    return (tokens / math.max(ceiling, 1)).clamp(0.0, 1.0);
  }

  /// Continuous color for a day. Truecolor terminals (the TUI emits
  /// 24-bit RGB) get a smooth background→success gradient — no fixed
  /// step palette, so every distinct token count gets its own shade.
  /// Linear intensity means low-activity days sit very close to the
  /// empty tint — intentional: they're meant to read as "nearly
  /// nothing happened".
  Color _cellColor(double intensity) {
    if (intensity <= 0) {
      // Near-background: a hair above the box bg so empty cells read
      // as "a cell", not as missing paint.
      return Color.lerp(theme.background, theme.onSurfaceDim, 0.22)!;
    }
    return Color.lerp(theme.background, theme.success, intensity)!;
  }

  /// Compact token count for the legend: `1.5M`, `100M`, `42k`.
  static String _fmtTokens(int n) {
    if (n >= 1000000) {
      final m = n / 1000000;
      return '${m % 1 == 0 ? m.toInt() : m.toStringAsFixed(1)}M';
    }
    if (n >= 1000) {
      final k = n / 1000;
      return '${k % 1 == 0 ? k.toInt() : k.toStringAsFixed(1)}k';
    }
    return '$n';
  }

  /// Week-row total in megatokens, at most 5 chars: the most precise
  /// M-value that fits. `4.51M`, `13.1M`, `130M` (a `130.1M` would
  /// be 6 chars, so the decimals drop), and tiny-but-nonzero weeks
  /// show `0.01M` rather than rounding to a misleading `0M`.
  static String _fmtMegs(int n) {
    final m = n / 1000000;
    for (final decimals in const [2, 1, 0]) {
      final s = '${m.toStringAsFixed(decimals)}M';
      if (s.length <= 5) return s;
    }
    // >= 10000M (10G): 5 chars can't hold the M value. Compress to G
    // (`10000M` -> `10.0G`); a >= 10T week overflows 5 chars whatever
    // we do, so don't truncate the number into a wrong one.
    return '${(m / 1000).toStringAsFixed(1)}G';
  }

  /// The Monday of the week [weeksBack] weeks before [today]'s week.
  /// Week starts on Monday (ISO convention).
  static DateTime _weekStartMonday(DateTime today, int weeksBack) {
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));
    return thisMonday.subtract(Duration(days: weeksBack * 7));
  }

  /// ISO-8601 week number (1–53) for [d]. Week 1 contains the year's
  /// first Thursday.
  static int isoWeek(DateTime d) {
    final thursday = d.add(Duration(days: 4 - d.weekday));
    final jan1 = DateTime(thursday.year, 1, 1);
    return 1 + (thursday.difference(jan1).inDays ~/ 7);
  }

  /// Width (terminal columns) of one day cell, including its trailing
  /// gap. 3 cols ≈ a square at terminal aspect, small enough that the
  /// whole 7-day grid fits a span-1 box.
  static const _cellWidth = 3;

  @override
  Component build(BuildContext context) {
    final today = _today;
    final labelStyle = TextStyle(color: theme.onSurfaceDim);

    // Oldest-first: the window is [ActivityHomeWidget.weeks] full
    // weeks ending at the current week. `weeks` full Mon→Sun rows,
    // where the last row is the current week (days after today blank).
    final firstMonday =
        _weekStartMonday(today, ActivityHomeWidget.weeks - 1);

    // Ceiling from the rendered window only — never from the fetched
    // headroom days before it (see _ceilingFor).
    final ceiling = _ceilingFor(firstMonday);

    // Header: weekday initials over the 7 day-columns, padded to the
    // cell width so each sits directly over its column. The leading
    // gutter matches the week-number gutter on the rows below.
    final header = Row(
      children: [
        Text('     ', style: labelStyle), // week-number gutter
        for (final d in strings.t('home.activity.weekdays').split(','))
          Text(padToWidth(d, _cellWidth), style: labelStyle),
        // Right-aligned column header over the per-week totals.
        Expanded(
          child: Text(
            strings.t('home.activity.total'),
            textAlign: TextAlign.right,
            style: labelStyle,
          ),
        ),
      ],
    );

    // Week rows: ISO week-number gutter + 7 day cells + (space
    // permitting) that week's token total. Each cell is a block + gap
    // colored by the day's continuous intensity (log of tokens /
    // ceiling).
    final weekRows = <Component>[];
    var cursor = firstMonday;
    for (var w = 0; w < ActivityHomeWidget.weeks; w++) {
      final weekNo = isoWeek(cursor);
      final cells = <Component>[
        Text('W${weekNo.toString().padLeft(2, '0')}  ', style: labelStyle),
      ];
      var weekTotal = 0;
      for (var d = 0; d < 7; d++) {
        if (cursor.isAfter(today)) {
          cells.add(Text(' ' * _cellWidth)); // future: blank cell
        } else {
          final key = _dayKey(cursor);
          final tokens = totals[key] ?? 0;
          weekTotal += tokens;
          final intensity = intensityFor(tokens, ceiling);
          cells.add(
            Text(
              '█' * (_cellWidth - 1) + ' ',
              style: TextStyle(color: _cellColor(intensity)),
            ),
          );
        }
        cursor = cursor.add(const Duration(days: 1));
      }
      // Per-week total in M tokens, right-aligned against the box edge
      // via Expanded. Expanded shrinks to zero when the row already
      // fills the box, so the total only appears when there's spare
      // width — exactly the "if there's room" behavior.
      if (weekTotal > 0) {
        cells.add(
          Expanded(
            child: Text(
              _fmtMegs(weekTotal),
              textAlign: TextAlign.right,
              style: TextStyle(color: theme.onSurfaceVariant),
            ),
          ),
        );
      }
      weekRows.add(Row(children: cells));
    }

    // Legend: a smooth gradient ramp (5 sampled steps of the continuous
    // scale) between the real endpoints, with the ceiling labelled.
    // 1-col swatches keep it inside the span-1 width.
    final legend = Row(
      children: [
        Text(strings.t('home.activity.less'), style: labelStyle),
        for (var i = 0; i <= 4; i++)
          Text('█', style: TextStyle(color: _cellColor(i / 4))),
        Text(strings.t('home.activity.more'), style: labelStyle),
        Text('0→${_fmtTokens(ceiling)}', style: labelStyle),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        ...weekRows,
        legend,
      ],
    );
  }
}

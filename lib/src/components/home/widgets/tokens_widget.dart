import 'package:nocterm/nocterm.dart';

import '../../../theme/crux_theme.dart';
import '../../../utils/run_metrics.dart';
import '../home_widgets.dart';

/// The `tokens` box — what this run has spent so far.
///
/// Data source: [RunMetrics.instance.getSnapshot()], which is pull-only
/// (it has no `ChangeNotifier`). Per the design doc's liveness model,
/// this widget reads the snapshot **once per build** — home doesn't tick
/// for it. That's deliberate: the box answers "what have I spent *so
/// far* this run", which is meaningful at open. If it proves too static
/// in practice the plan's escape hatch is a single shared slow timer in
/// `HomeScreen`, not a per-widget timer.
///
/// Passive box — `activate` returns null; there's no primary action.
class TokensHomeWidget extends HomeWidget {
  @override
  String get id => 'tokens';

  @override
  String get title => 'Tokens';

  @override
  Set<int> get supportedSpans => const {1};

  /// Read the current snapshot. Exposed as a field so tests can inject a
  /// fixed snapshot instead of depending on the process-wide singleton.
  final RunMetricsSnapshot Function() _snapshot;

  TokensHomeWidget({RunMetricsSnapshot Function()? snapshot})
      : _snapshot = snapshot ?? (() => RunMetrics.instance.getSnapshot());

  @override
  int heightFor(int span) => 5;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  @override
  Component build(BuildContext context, HomeContext ctx, int span) {
    final theme = CruxTheme.of(context);
    final snap = _snapshot();

    if (snap.isEmpty) {
      return Text(
        'no LLM calls yet this run',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final labelStyle = TextStyle(color: theme.onSurfaceDim);
    final valueStyle = TextStyle(color: theme.onSurfaceVariant);
    final cachePct = snap.cacheHitPct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(labelStyle, valueStyle, 'turns', '${snap.turnCount}'),
        _row(
          labelStyle,
          valueStyle,
          'tokens in',
          '${_fmt(snap.totalTokensIn)}  (↑${_fmt(snap.totalPromptTokens)} prompt)',
        ),
        _row(labelStyle, valueStyle, 'tokens out', _fmt(snap.totalTokensOut)),
        _row(labelStyle, valueStyle, 'duration', _fmtDuration(snap.duration)),
        if (cachePct != null)
          _row(
            labelStyle,
            valueStyle,
            'cache hit',
            '${cachePct.toStringAsFixed(0)}%',
          ),
      ],
    );
  }

  Component _row(
    TextStyle labelStyle,
    TextStyle valueStyle,
    String label,
    String value,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label  ', style: labelStyle),
        Text(value, style: valueStyle),
      ],
    );
  }

  /// Comma-group a token count for readability (e.g. `12,800`).
  static String _fmt(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );

  static String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}

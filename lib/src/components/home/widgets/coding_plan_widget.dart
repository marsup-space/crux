import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../../../services/llm_provider.dart' show typeDisplayName;
import '../../../services/providers/coding_plan_provider.dart';
import '../../../services/providers/credit_balance_provider.dart';
import '../../../theme/crux_theme.dart';
import '../../polling_coordinator.dart';
import '../home_widgets.dart';

/// The `coding-plan` box — live usage for **every** connected provider.
///
/// Unlike the toolbar (which shows only the active session's provider),
/// this box renders one compact line per connected provider that exposes
/// a usage surface:
///
///   * **Coding plan** ([CodingPlanProvider] — MiniMax / Kimi / Zhipu):
///     `Kimi  5h 88%  7d 55%` (the 5-hour and 7-day remaining).
///   * **API credit** ([CreditBalanceProvider] — DeepSeek):
///     `DeepSeek  credit ¥110.00`.
///
/// Provider name and usage are inline on one line each, so the box stays
/// narrow (span 1). The box is live: it subscribes to every provider's
/// poll stream and re-renders on each snapshot. With no connected
/// providers it shows a compact empty state.
///
/// The whole-box action forces an immediate refresh across every
/// connected provider.
class CodingPlanHomeWidget extends HomeWidget {
  /// Injectable entry resolver for tests. Null means "read through
  /// [HomeContext]" (production). Resolved on every build so a newly
  /// added/removed provider is picked up on the next open.
  final List<ConnectedProviderUsage> Function()? entriesOverride;

  CodingPlanHomeWidget({this.entriesOverride});

  @override
  String get id => 'coding-plan';

  @override
  String get title => 'Coding plan';

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 4;

  /// A list of one-line provider rows reads top-down, not centered in a
  /// stretched box.
  @override
  bool get verticallyCenter => false;

  List<ConnectedProviderUsage> _entries(HomeContext ctx) =>
      entriesOverride?.call() ?? ctx.connectedUsageProviders();

  @override
  void Function()? activate(HomeContext ctx) {
    final entries = _entries(ctx);
    if (entries.isEmpty) return null;
    return () {
      for (final entry in entries) {
        entry.codingPlan?.refreshNow();
        entry.creditBalance?.refreshNow();
      }
    };
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _CodingPlanHomeView(entries: _entries(ctx));
  }
}

/// Stateful view so the box re-renders when any provider's poll stream
/// delivers a fresh snapshot. Subscriptions follow the same
/// initState / deactivate / activate / dispose lifecycle the `git-status`
/// box uses, so a deactivated home subtree (mid fullpane swap) never
/// receives a late stream event and trips nocterm's `setState`-on-
/// inactive assert.
class _CodingPlanHomeView extends StatefulComponent {
  final List<ConnectedProviderUsage> entries;

  const _CodingPlanHomeView({required this.entries});

  @override
  State<_CodingPlanHomeView> createState() => _CodingPlanHomeViewState();
}

class _CodingPlanHomeViewState extends State<_CodingPlanHomeView> {
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void deactivate() {
    // The `mounted` guard in [_onData] isn't enough: nocterm's
    // `mounted` stays true while the element is merely deactivated,
    // but `setState` asserts the element is active. Unsubscribing here
    // guarantees no stream event can reach this State while it's
    // deactivated.
    _unsubscribe();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _subscribe();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    _unsubscribe();
    for (final entry in component.entries) {
      final cpSub = entry.codingPlan?.codingPlanUsageStream.listen(_onData);
      if (cpSub != null) _subs.add(cpSub);
      final cbSub = entry.creditBalance?.creditBalanceStream.listen(_onData);
      if (cbSub != null) _subs.add(cbSub);
    }
  }

  void _unsubscribe() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
  }

  void _onData(dynamic _) {
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final entries = component.entries;

    if (entries.isEmpty) {
      return Text(
        'no usage data',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    // Pad the provider-name column to the widest name so the metric
    // columns line up vertically.
    var maxNameWidth = 0;
    for (final entry in entries) {
      final w = typeDisplayName(entry.name).length;
      if (w > maxNameWidth) maxNameWidth = w;
    }

    final rows = <Component>[];
    for (final entry in entries) {
      final codingPlan = entry.codingPlan;
      final creditBalance = entry.creditBalance;
      if (codingPlan != null) {
        rows.add(
          _codingPlanRow(theme, entry.name, codingPlan, maxNameWidth),
        );
      } else if (creditBalance != null) {
        rows.add(
          _creditRow(theme, entry.name, creditBalance, maxNameWidth),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  /// Inline coding-plan line: `<Name>  5h 88%  7d 55%`.
  Component _codingPlanRow(
    CruxThemeData theme,
    String name,
    CodingPlanProvider cp,
    int nameWidth,
  ) {
    final usage = cp.latestCodingPlanUsage;
    final children = <Component>[_nameText(theme, name, nameWidth)];
    if (usage == null) {
      children.add(_waiting(theme));
    } else {
      children.addAll(_window(theme, '5h', usage.intervalRemainingPct));
      children.addAll(_window(theme, '7d', usage.weeklyRemainingPct));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// Inline API-credit line: `<Name>  credit ¥110.00`.
  Component _creditRow(
    CruxThemeData theme,
    String name,
    CreditBalanceProvider cb,
    int nameWidth,
  ) {
    final balance = cb.latestCreditBalance;
    final children = <Component>[_nameText(theme, name, nameWidth)];
    if (balance == null) {
      children.add(_waiting(theme));
    } else {
      final color = balance.isAvailable ? theme.cyan : theme.warning;
      children.add(
        Text('  credit ', style: TextStyle(color: theme.onSurfaceDim)),
      );
      children.add(
        Text(
          balance.formatPrimary() ?? '—',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// Provider display-name header (e.g. `DeepSeek`, `Kimi`, `Zhipu`),
  /// padded to [width] so the metric column starts at a fixed position.
  Component _nameText(CruxThemeData theme, String name, int width) {
    return Text(
      typeDisplayName(name).padRight(width),
      style: TextStyle(
        color: theme.accent,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// One window's inline pieces: `  5h ` dim label + `88%` coloured value.
  List<Component> _window(CruxThemeData theme, String label, int pct) {
    return [
      Text('  $label ', style: TextStyle(color: theme.onSurfaceDim)),
      Text(
        '$pct%',
        style: TextStyle(
          color: _pctColor(theme, pct),
          fontWeight: FontWeight.bold,
        ),
      ),
    ];
  }

  Component _waiting(CruxThemeData theme) {
    return Text('  waiting…', style: TextStyle(color: theme.onSurfaceDim));
  }

  /// Simple remaining-percentage colour: affluent cyan above half,
  /// warning in the middle band, error once nearly exhausted. A
  /// deliberately simpler version of the toolbar's ratio-based
  /// steady-state colour — a dashboard glance doesn't need the full
  /// usage-vs-time model.
  Color _pctColor(CruxThemeData theme, int pct) {
    if (pct >= 50) return theme.cyan;
    if (pct >= 20) return theme.warning;
    return theme.error;
  }
}

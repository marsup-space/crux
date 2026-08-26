/// One local-calendar day's aggregate usage stats, for the home screen's
/// `today` box.
///
/// Computed by a single SQL aggregate over `messages JOIN sessions`
/// ([MessageStore.dailyUsageStats]), bucketed by the user's local
/// midnight.
class DailyUsageStats {
  /// Total tokens (in + out) spent that day.
  final int tokens;

  /// Number of conversation turns that day — one `role: 'user'` message
  /// per turn.
  final int turns;

  /// Number of distinct sessions that had activity that day (i.e. the
  /// sessions the user actually talked in).
  final int sessions;

  /// Tokens (in + out) spent that day, keyed by model id — only models
  /// with a nonzero total appear (the SQL groups by `messages.model` and
  /// drops empty/zero rows). Feeds the `today` box's per-model bar chart.
  /// Empty when the store predates per-model tracking or no store is
  /// wired (tests / previews) — the box then renders without bars.
  final Map<String, int> byModel;

  const DailyUsageStats({
    required this.tokens,
    this.turns = 0,
    this.sessions = 0,
    this.byModel = const {},
  });

  /// True when the day had no recorded activity at all.
  bool get isEmpty => tokens == 0 && turns == 0 && sessions == 0;

  @override
  String toString() =>
      'DailyUsageStats(tokens=$tokens, turns=$turns, sessions=$sessions, '
      'byModel=$byModel)';
}

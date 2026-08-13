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

  const DailyUsageStats({
    required this.tokens,
    this.turns = 0,
    this.sessions = 0,
  });

  /// True when the day had no recorded activity at all.
  bool get isEmpty => tokens == 0 && turns == 0 && sessions == 0;

  @override
  String toString() =>
      'DailyUsageStats(tokens=$tokens, turns=$turns, sessions=$sessions)';
}

/// Live usage snapshot from a provider's coding-plan quota API.
///
/// The plan-side MiniMax `/v1/token_plan/remains` endpoint returns an
/// array of per-model rows. The model with `model_name == "general"`
/// (text/coding quota) is the one Crux surfaces in the toolbar; video
/// and other modalities are ignored here.
///
/// Both percentage fields are 0–100, with 100 = full quota remaining.
/// Callers that want the raw count (e.g. for progress bars) can derive
/// it from the [UsageQuotaTier.limit] in the [ProviderConfig.quota]
/// table.
class CodingPlanUsage {
  /// Provider name this snapshot is for (e.g. `"minimax"`).
  final String providerName;

  /// The `model_name` field from the API row we picked (e.g. `"general"`).
  /// Useful for diagnostics and hover hints; not displayed directly.
  final String modelName;

  /// Percentage of the 5-hour rolling window remaining (0–100).
  final int intervalRemainingPct;

  /// Percentage of the weekly window remaining (0–100).
  final int weeklyRemainingPct;

  /// Time until the 5-hour window resets. Sourced from the
  /// `remains_time` field on the API row (milliseconds).
  /// `null` when the provider didn't return a countdown.
  final Duration? intervalRemains;

  /// Time until the weekly window resets. Sourced from the
  /// `weekly_remains_time` field on the API row (milliseconds).
  /// `null` when the provider didn't return a countdown.
  final Duration? weeklyRemains;

  /// When this snapshot was fetched.
  final DateTime fetchedAt;

  const CodingPlanUsage({
    required this.providerName,
    required this.modelName,
    required this.intervalRemainingPct,
    required this.weeklyRemainingPct,
    required this.fetchedAt,
    this.intervalRemains,
    this.weeklyRemains,
  });

  @override
  String toString() =>
      'CodingPlanUsage($providerName/$modelName: '
      '5h=$intervalRemainingPct% 1w=$weeklyRemainingPct%)';

  /// Format the 5h window's remaining time as a short human label
  /// (e.g. `"4h 32m"`, `"23m 15s"`, `"<1s"`). Returns `null` when
  /// the snapshot has no countdown (e.g. provider didn't return
  /// `remains_time`).
  String? formatIntervalRemains() =>
      intervalRemains == null ? null : _formatRemains(intervalRemains!);

  /// Format the weekly window's remaining time as a short human
  /// label (e.g. `"6d 4h"`, `"18h 32m"`). Returns `null` when
  /// the snapshot has no countdown.
  String? formatWeeklyRemains() =>
      weeklyRemains == null ? null : _formatRemains(weeklyRemains!);
}

/// Format a [Duration] as a compact countdown label. The pair of
/// units is chosen by magnitude so the label stays a similar width
/// for short and long windows:
///
///   * `>= 1 day`  →  `"6d 4h"`   (or `"7d"` when 0 hours left)
///   * `>= 1 hour` →  `"4h 32m"`  (or `"5h"` when 0 minutes left)
///   * `>= 1 min`  →  `"23m 15s"` (or `"32m"` when 0 seconds left)
///   * `>= 1 s`    →  `"45s"`
///   * `else`      →  `"<1s"`
String _formatRemains(Duration d) {
  if (d.isNegative) return '<1s';
  if (d.inDays >= 1) {
    final hours = d.inHours - d.inDays * 24;
    return hours > 0 ? '${d.inDays}d ${hours}h' : '${d.inDays}d';
  }
  if (d.inHours >= 1) {
    final minutes = d.inMinutes - d.inHours * 60;
    return minutes > 0 ? '${d.inHours}h ${minutes}m' : '${d.inHours}h';
  }
  if (d.inMinutes >= 1) {
    final seconds = d.inSeconds - d.inMinutes * 60;
    return seconds > 0
        ? '${d.inMinutes}m ${seconds}s'
        : '${d.inMinutes}m';
  }
  if (d.inSeconds >= 1) return '${d.inSeconds}s';
  return '<1s';
}

/// Reason a [CodingPlanUsageService] couldn't return a snapshot.
/// Kept narrow so the UI can pick a different placeholder for each.
enum CodingPlanUsageErrorKind {
  /// Provider has no `[quota]` table in its TOML config.
  notConfigured,

  /// Provider has a `[quota]` config but no API key is set.
  noApiKey,

  /// The HTTP call failed (timeout, connection refused, non-2xx, etc.).
  network,

  /// The response couldn't be parsed.
  parse,
}

class CodingPlanUsageError {
  final CodingPlanUsageErrorKind kind;
  final String message;

  const CodingPlanUsageError(this.kind, this.message);

  @override
  String toString() => 'CodingPlanUsageError(${kind.name}: $message)';
}

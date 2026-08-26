import 'dart:math' as math;

/// Compact token count for tight terminal cells: `1.5M`, `100M`, `42k`,
/// `999`. The most precise form that stays short — a `130.1M` drops its
/// decimals to fit, and tiny-but-nonzero values honestly render as
/// `0.01M`-style minimums rather than rounding to a misleading `0M`.
///
/// Shared by the home screen's token surfaces (the `activity` heatmap's
/// legend/week totals, the `today` box's per-model bars).
String formatTokensCompact(int n) {
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

/// Week/day-row total in megatokens, at most [maxChars] chars (default
/// 5): the most precise M-value that fits. `4.51M`, `13.1M`, `130M`,
/// tiny-but-nonzero weeks show `0.01M`. Beyond that compresses to G
/// (`10000M` → `10.0G`); a >= 10T row overflows whatever we do, so the
/// number is never truncated into a wrong one.
String formatMegs(int n, {int maxChars = 5}) {
  final m = n / math.max(1, 1000000);
  for (final decimals in const [2, 1, 0]) {
    final s = '${m.toStringAsFixed(decimals)}M';
    if (s.length <= maxChars) return s;
  }
  // >= 10000M (10G): can't hold the M value within [maxChars].
  return '${(m / 1000).toStringAsFixed(1)}G';
}

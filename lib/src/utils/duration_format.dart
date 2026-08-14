import '../i18n/strings.dart';

/// Format a gap between agent turns as a human-readable label.
///
/// Buckets:
///
/// * `just now` — under 30 seconds
/// * `X minutes ago` — under an hour
/// * `X hours Y minutes ago` — under a day
/// * `X days ago` (when hour/minute are zero)
/// * `X days and Y hours Z minutes ago` — multi-day
///
/// All units past "minutes" are floored from the underlying [Duration]
/// so the label is monotonic with elapsed time. Hours wrap at 24
/// (i.e. 1 day 25 hours renders as 1 day and 1 hours …, not 49
/// hours). Days and hours are both bounded to non-negative integers
/// via integer division; the time delta is always non-negative at
/// the call sites (last agent activity ≤ now), so we don't need to
/// guard against negative durations here.
String formatAgentTurnGap(Duration d, {Strings strings = kEnglishStrings}) {
  if (d.inMinutes < 1) return strings.t('chat.time.justNow');
  if (d.inMinutes < 60) {
    return strings.t('chat.time.minutesLongAgo', {'n': '${d.inMinutes}'});
  }

  if (d.inHours < 24) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (m == 0) return strings.t('chat.time.hoursLongAgo', {'n': '$h'});
    return strings.t('chat.time.hoursMinutesAgo', {'h': '$h', 'm': '$m'});
  }

  // Multi-day: cumulative breakdown via [Duration.inDays] / `.inHours % 24`
  // / `.inMinutes % 60`. So 49h30m renders as "2 days and 1 hours
  // 30 minutes" rather than the calendar-style "1 days and 25 hours
  // 30 minutes" — the cumulative split is the conventional
  // human-readable form for "X days ago" labels and matches what
  // most chat UIs do. Zero hours/minutes are kept on the line when
  // the larger unit is present, except in the all-zeros sub-hour
  // case below where the "X days ago" form reads cleaner.
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  if (hours == 0 && minutes == 0) {
    return strings.t('chat.time.daysLongAgo', {'d': '$days'});
  }
  return strings.t('chat.time.daysHoursMinutesAgo', {
    'd': '$days',
    'h': '$hours',
    'm': '$minutes',
  });
}

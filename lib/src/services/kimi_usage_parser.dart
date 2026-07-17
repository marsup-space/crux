import 'dart:convert';

import '../models/coding_plan_usage.dart';
import 'coding_plan_usage_parser.dart';

/// Parse the JSON body of a Kimi Code `/usages` response into
/// the [CodingPlanUsage] shape Crux's toolbar can render.
///
/// The Kimi platform emits a flexible shape we don't see on
/// any other provider, so this lives in its own module rather
/// than being folded into [parseCodingPlanUsageResponse]
/// (which targets MiniMax's `model_remains` array).
///
/// Kimi's shape:
///
/// ```json
/// {
///   "usage": {
///     "name": "Weekly limit",
///     "limit": 1000,
///     "used": 500,
///     "reset_at": "2025-12-30T05:24:18.443Z"
///   },
///   "limits": [
///     {
///       "name": "5h",
///       "window": { "duration": 300, "timeUnit": "MINUTE" },
///       "detail": {
///         "limit": 100,
///         "used": 20,
///         "remaining": 80,
///         "reset_at": "2025-12-23T05:24:18.443Z"
///       }
///     },
///     {
///       "name": "1w",
///       "window": { "duration": 10080, "timeUnit": "MINUTE" },
///       "detail": { ... }
///     }
///   ]
/// }
/// ```
///
/// The toolbar renders exactly two cells (the 5h short window
/// and the 1w weekly window) so we map:
///
/// * `interval` ← the `limits[]` row with the **shortest**
///   window. When the array has only one row, both cells
///   read from it.
/// * `weekly` ← the `limits[]` row with the **longest**
///   window. When the array has only one row, the same row
///   fills both cells.
/// * `modelName` ← `usage.name` (e.g. `"Weekly limit"`), used
///   for hover-hint diagnostics.
///
/// ## Field-name tolerance
///
/// Each row's `used` / `limit` / `reset_at` can also be
/// spelled:
///
/// * `remaining` (in which case `used = limit - remaining`),
/// * `resetAt` / `reset_time` / `resetTime` (camelCase or
///   snake_case — same field, different naming conventions
///   in the wild),
/// * `reset_in` / `resetIn` / `ttl` / `window` — all
///   treated as "seconds until reset" (relative durations
///   instead of absolute timestamps).
///
/// This mirrors the parser the kimi-cli `/usage` command
/// ships, so the two tools agree on the same payload
/// shapes.
///
/// When the payload has no `limits` array (or it's empty)
/// AND no `usage` block, we fall through to the generic
/// [parseCodingPlanUsageResponse] so a future API change
/// that aligns Kimi with the MiniMax shape "just works".
/// The fall-through is a clean error path — the generic
/// parser throws a clear "no model_remains / data array
/// and no flat fields" rather than silently returning
/// zeros.
CodingPlanUsage parseKimiUsageResponse(
  String body, {
  String providerName = 'kimi',
}) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Invalid JSON: ${e.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Response root is not a JSON object',
    );
  }

  // First, try the Kimi-specific `usage` + `limits` shape.
  // When absent (or no rows), fall back to the generic
  // model_remains / flat parser so a future API change that
  // aligns with MiniMax keeps working without a Crux update.
  final limitsRaw = decoded['limits'];
  if (limitsRaw is List && limitsRaw.isNotEmpty) {
    final rows = limitsRaw.whereType<Map<String, dynamic>>().toList();
    if (rows.isNotEmpty) {
      return _fromKimiLimitsShape(decoded, rows, providerName);
    }
  }
  // The summary-only `usage` block (no `limits`) is also
  // legal — render both cells from it.
  final usageRaw = decoded['usage'];
  if (usageRaw is Map<String, dynamic>) {
    return _fromKimiLimitsShape(decoded, [usageRaw], providerName);
  }

  // Fall back to the generic parser. This is a no-op when
  // the response is Kimi-specific (the generic parser would
  // throw "no model_remains / data array and no flat
  // fields"), so the user sees a clear parse error rather
  // than silent zeros.
  return parseCodingPlanUsageResponse(body, providerName: providerName);
}

/// Build a [CodingPlanUsage] from the Kimi `usage` + `limits`
/// payload. See [parseKimiUsageResponse] for the field-name
/// tolerance rules.
CodingPlanUsage _fromKimiLimitsShape(
  Map<String, dynamic> payload,
  List<Map<String, dynamic>> rows,
  String providerName,
) {
  // The top-level `usage` block is Kimi's "Weekly limit"
  // summary — it always carries the weekly numbers even
  // when `limits[]` only contains the 5h row (the common
  // shape on a freshly-issued API key). The kimi-cli
  // `/usage` command renders the summary as a separate
  // row above the limits; Crux only has two cells, so we
  // fold the summary into the weekly slot when there's
  // no explicit 1w row in `limits[]`.
  final usageBlock = payload['usage'] is Map<String, dynamic>
      ? payload['usage'] as Map<String, dynamic>
      : null;

  // Sort `limits[]` by window duration and pick the two
  // ends. Rows without a `window` field sort to the end
  // (treated as "no specific time bound") so they don't
  // grab the interval slot unless every row lacks a
  // window.
  final sorted = [...rows]
    ..sort((a, b) {
      final da = _windowSeconds(a);
      final db = _windowSeconds(b);
      // nulls last; among non-nulls, ascending.
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });

  // Interval cell = shortest window in `limits[]`. If
  // `limits[]` is empty (and we got here only because the
  // caller supplied a single-element list from the
  // top-level `usage`), the interval cell reads from
  // `usage` too — see the summary-only case below.
  final intervalRow = sorted.first;

  // Weekly cell: prefer the longest window in `limits[]`
  // when the array has more than one distinct window
  // duration, fall back to the top-level `usage` block
  // (which Kimi documents as the "Weekly limit" summary)
  // when `limits[]` has only one row, fall back to
  // duplicating the interval row only when neither is
  // available. The middle branch is the one the user
  // actually hit: real-world Kimi payloads often ship a
  // 5h row in `limits[]` plus a weekly summary in
  // `usage` — duplicating the 5h row to the weekly slot
  // is the regression that motivated this rewrite.
  final hasDistinctWindows =
      sorted.length > 1 &&
      _windowSeconds(sorted.first) != _windowSeconds(sorted.last);
  final Map<String, dynamic> weeklyRow;
  if (hasDistinctWindows) {
    weeklyRow = sorted.last;
  } else if (usageBlock != null && usageBlock != intervalRow) {
    weeklyRow = usageBlock;
  } else {
    weeklyRow = intervalRow;
  }

  final interval = _toKimiUsageRow(intervalRow);
  final weekly = _toKimiUsageRow(weeklyRow);

  final modelName = usageBlock != null
      ? (usageBlock['name']?.toString() ?? providerName)
      : providerName;

  return CodingPlanUsage(
    providerName: providerName,
    modelName: modelName,
    intervalRemainingPct: interval.remainingPct,
    weeklyRemainingPct: weekly.remainingPct,
    intervalRemains: interval.resetIn,
    weeklyRemains: weekly.resetIn,
    fetchedAt: DateTime.now(),
  );
}

/// Convert a single Kimi `limits[]` row (or the top-level
/// `usage` object) into a normalized [_KimiUsageRow]
/// carrying the percentage remaining and the time-until-
/// reset. `detail` is the conventional place for the
/// counters when the row is a `limits[]` entry; for the
/// top-level `usage` object the fields live directly on
/// the row.
_KimiUsageRow _toKimiUsageRow(Map<String, dynamic> row) {
  final detail = row['detail'] is Map<String, dynamic>
      ? row['detail'] as Map<String, dynamic>
      : row;

  final limit = _toIntOrNull(detail['limit']);
  var used = _toIntOrNull(detail['used']);
  if (used == null) {
    final remaining = _toIntOrNull(detail['remaining']);
    if (remaining != null && limit != null) {
      used = limit - remaining;
    }
  }
  final effectiveUsed = used ?? 0;
  final effectiveLimit = limit ?? 0;
  final remainingPct = effectiveLimit > 0
      ? ((effectiveLimit - effectiveUsed) * 100 / effectiveLimit)
            .clamp(0, 100)
            .toInt()
      : 0;

  return _KimiUsageRow(
    remainingPct: remainingPct,
    resetIn: _resetInDuration(detail) ?? _resetInDuration(row),
  );
}

/// Total seconds in a row's `window` field, or `null` when
/// the row has no `window` (treated as unbounded for
/// sorting).
int? _windowSeconds(Map<String, dynamic> row) {
  final window = row['window'];
  if (window is! Map<String, dynamic>) return null;
  final duration = _toIntOrNull(window['duration']);
  if (duration == null) return null;
  final unit = (window['timeUnit']?.toString() ?? '').toUpperCase();
  switch (unit) {
    case 'SECOND':
    case 'SECONDS':
      return duration;
    case 'MINUTE':
    case 'MINUTES':
      return duration * 60;
    case 'HOUR':
    case 'HOURS':
      return duration * 3600;
    case 'DAY':
    case 'DAYS':
      return duration * 86400;
    case 'WEEK':
    case 'WEEKS':
      return duration * 86400 * 7;
    case 'MONTH':
    case 'MONTHS':
      return duration * 86400 * 30;
    default:
      // Unknown unit — assume seconds so the value still
      // has a defined sort position.
      return duration;
  }
}

/// Resolve a `reset_in` / `resetIn` field (seconds) or a
/// `reset_at` / `resetAt` ISO timestamp into a [Duration]
/// until reset. Returns `null` when neither is present.
Duration? _resetInDuration(Map<String, dynamic> row) {
  // Relative seconds: `reset_in`, `resetIn`, `ttl`, `window`.
  for (final key in const ['reset_in', 'resetIn', 'ttl', 'window']) {
    final v = _toIntOrNull(row[key]);
    if (v != null && v > 0) return Duration(seconds: v);
  }
  // Absolute timestamp: `reset_at`, `resetAt`, `reset_time`,
  // `resetTime`.
  for (final key in const ['reset_at', 'resetAt', 'reset_time', 'resetTime']) {
    final v = row[key];
    if (v is String && v.isNotEmpty) {
      final d = _parseIsoReset(v);
      if (d != null) return d;
    }
  }
  return null;
}

/// Parse an ISO-8601 timestamp and return the [Duration]
/// from now until that instant. Returns `null` on parse
/// failure or if the reset time has already passed.
Duration? _parseIsoReset(String iso) {
  try {
    final dt = DateTime.parse(iso).toUtc();
    final now = DateTime.now().toUtc();
    final delta = dt.difference(now);
    return delta.isNegative ? null : delta;
  } on FormatException {
    return null;
  }
}

int? _toIntOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Internal normalized shape for a single Kimi usage row
/// after we've crunched the per-shape field-name
/// differences (used vs. remaining, reset_at vs. reset_in,
/// etc.) into a single pair of `(remainingPct, resetIn)`
/// values.
class _KimiUsageRow {
  final int remainingPct;
  final Duration? resetIn;

  const _KimiUsageRow({required this.remainingPct, required this.resetIn});
}

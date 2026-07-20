import 'dart:convert';

import '../models/coding_plan_usage.dart';

/// Parse the JSON body of a Zhipu GLM Coding Plan
/// `/api/monitor/usage/quota/limit` response into a
/// [CodingPlanUsage] shape Crux's toolbar can render.
///
/// The Zhipu platform emits a flat array under `data.limits[]`,
/// where each row carries:
///
/// * `type` — `"TOKENS_LIMIT"` for the two windows the toolbar
///   renders (5h and weekly), `"TIME_LIMIT"` for the monthly
///   MCP pool (parsed here for completeness but not displayed).
/// * `unit` — a small enum that distinguishes the rows. The
///   mapping was reverse-engineered from the Z.ai frontend
///   source (see https://pi.dev/packages/pi-glm-usage and the
///   cc-switch extractor at
///   https://github.com/farion1231/cc-switch/discussions/1038):
///
///   | unit | meaning                           |
///   |------|-----------------------------------|
///   |   3  | 5-hour rolling TOKENS_LIMIT       |
///   |   6  | weekly TOKENS_LIMIT               |
///   |   5  | monthly Web Search / Reader / Zread TIME_LIMIT |
///
/// * `percentage` — *used* quota (0–100). Crux's UI shows
///   *remaining*, so we report `100 - percentage`.
/// * `nextResetTime` — Unix-epoch milliseconds when the row
///   resets. Missing → no countdown on the toolbar.
///
/// The full response shape:
///
/// ```json
/// {
///   "code": 200,
///   "data": {
///     "limits": [
///       { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 16,
///         "nextResetTime": 1777819631597 },
///       { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 4,
///         "nextResetTime": 1778262784969 },
///       { "type": "TIME_LIMIT",    "unit": 5, "percentage": 0,
///         "nextResetTime": 1780336384978 }
///     ],
///     "level": "lite"
///   }
/// }
/// ```
///
/// The toolbar has two cells (5h, weekly), so the parser maps:
///
/// * `interval` ← the `unit == 3` TOKENS_LIMIT row.
/// * `weekly`   ← the `unit == 6` TOKENS_LIMIT row.
/// * `modelName` ← `data.level` (e.g. `"lite"`, `"pro"`,
///   `"max"`), uppercased to render in the hover hint as
///   `"ZHIPU Lite" / "ZHIPU Pro" / "ZHIPU Max"`. When the
///   `level` field is missing we fall back to the provider
///   name.
///
/// The parser tolerates the three common ways a server can
/// return a non-success body — `code != 0/200`, `data` missing,
/// or `limits` empty — and surfaces them as a clear
/// [CodingPlanUsageError] (kind = `parse`) rather than
/// silently zeroing the toolbar. If one of the two TOKENS_LIMIT
/// rows is missing, the parser falls back to 0% remaining with
/// no countdown (rather than throwing) so a partial response
/// doesn't lock the toolbar on "—".
///
/// When the upstream shape changes (e.g. a future Z.ai release
/// drops `nextResetTime` or renames `data.limits`), the parser
/// keeps the percentage read working as long as the percentage
/// field on each row keeps its name.
CodingPlanUsage parseZhipuUsageResponse(
  String body, {
  String providerName = 'zhipu',
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

  // Zhipu wraps success in `{code, data, ...}`. Be permissive:
  // a missing or non-200/0 `code` is a parse error (the body
  // shape is wrong, not just "no quota left"). A 200/0 response
  // without a `data` block is also a parse error.
  final code = decoded['code'];
  if (code is num && code != 200 && code != 0) {
    throw CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Zhipu quota API returned code=$code: '
      '${decoded['msg'] ?? decoded['message'] ?? 'unknown error'}',
    );
  }
  final data = decoded['data'];
  if (data is! Map<String, dynamic>) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Missing data block in Zhipu quota response',
    );
  }

  final limitsRaw = data['limits'];
  if (limitsRaw is! List || limitsRaw.isEmpty) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Missing or empty data.limits array',
    );
  }
  final rows = limitsRaw.whereType<Map<String, dynamic>>().toList();
  if (rows.isEmpty) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'data.limits contained no object rows',
    );
  }

  // 5h row: TOKENS_LIMIT, unit 3. Weekly row: TOKENS_LIMIT,
  // unit 6. The parser doesn't insist on `type` being exactly
  // "TOKENS_LIMIT" because a future Z.ai release that adds a
  // new tier (e.g. "TOKENS_LIMIT" for unit 7) shouldn't
  // silently hide that row from the toolbar. The `unit` number
  // is the canonical key.
  final intervalRow = _findRow(rows, type: 'TOKENS_LIMIT', unit: 3);
  final weeklyRow = _findRow(rows, type: 'TOKENS_LIMIT', unit: 6);

  final interval = _rowToSnapshot(intervalRow);
  final weekly = _rowToSnapshot(weeklyRow);

  // `level` carries the plan tier — "lite" / "pro" / "max" —
  // and is the most informative single string the toolbar can
  // surface (more useful than the provider name alone). When
  // missing, fall back to the provider name so the hover hint
  // never goes empty.
  final levelRaw = data['level']?.toString().trim();
  final modelName = (levelRaw != null && levelRaw.isNotEmpty)
      ? 'ZHIPU ${_capitalize(levelRaw)}'
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

/// Find a row in [rows] matching the given (type, unit) pair.
/// Returns `null` when no such row exists — the caller is
/// expected to handle a missing row gracefully (defaulting to
/// 0% remaining, no countdown) rather than throwing.
Map<String, dynamic>? _findRow(
  List<Map<String, dynamic>> rows, {
  required String type,
  required int unit,
}) {
  for (final r in rows) {
    if (r['type']?.toString() == type && r['unit'] is num &&
        (r['unit'] as num).toInt() == unit) {
      return r;
    }
  }
  return null;
}

/// Convert a single Zhipu `limits[]` row into a normalized
/// pair of `(remainingPct, resetIn)`. `percentage` is the
/// *used* fraction (per the API contract) so we subtract from
/// 100 to get the remaining fraction. Missing rows produce
/// `(0, null)` so the toolbar renders a clear "0% / no
/// countdown" rather than crashing.
_ZhipuUsageSnapshot _rowToSnapshot(Map<String, dynamic>? row) {
  if (row == null) return const _ZhipuUsageSnapshot();
  final percentage = row['percentage'];
  final remainingPct = percentage is num
      ? (100 - percentage).toInt().clamp(0, 100)
      : 0;
  return _ZhipuUsageSnapshot(
    remainingPct: remainingPct,
    resetIn: _resetInDuration(row),
  );
}

/// Resolve a `nextResetTime` (Unix-epoch milliseconds) into a
/// [Duration] until that instant. Returns `null` when the
/// field is missing, non-numeric, or the reset time has
/// already passed (the toolbar's format helper renders
/// negative durations as `"<1s"`, so we just skip the
/// countdown rather than showing a permanently negative
/// ticker).
Duration? _resetInDuration(Map<String, dynamic> row) {
  final v = row['nextResetTime'];
  if (v is! num) return null;
  final resetAt = DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
  final now = DateTime.now().toUtc();
  final delta = resetAt.difference(now);
  return delta.isNegative ? null : delta;
}

/// Uppercase the first character of [s]. Used to turn the
/// API's lowercase plan tier (`"lite"` / `"pro"` / `"max"`)
/// into the display form (`"Lite"` / `"Pro"` / `"Max"`).
String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Internal normalized shape for a single Zhipu usage row
/// after we've crunched the per-shape field-name differences
/// (`percentage` vs remaining, `nextResetTime` ms vs
/// duration) into a single `(remainingPct, resetIn)` pair.
class _ZhipuUsageSnapshot {
  final int remainingPct;
  final Duration? resetIn;

  const _ZhipuUsageSnapshot({
    this.remainingPct = 0,
    this.resetIn,
  });
}

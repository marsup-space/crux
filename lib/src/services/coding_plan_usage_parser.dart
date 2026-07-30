import 'dart:convert';

import '../models/coding_plan_usage.dart';

/// Parse the JSON body of a coding-plan "remains" response into a
/// [CodingPlanUsage].
///
/// The expected shape is the MiniMax `/v1/token_plan/remains`
/// endpoint:
/// ```json
/// {
///   "model_remains": [
///     {
///       "model_name": "general",
///       "current_interval_remaining_percent": 98,
///       "current_weekly_remaining_percent": 73,
///       "remains_time": 17502294,
///       "weekly_remains_time": 377502294,
///       ...
///     }
///   ]
/// }
/// ```
///
/// Designed to be shape-flexible rather than provider-flexible:
/// other coding-plan providers (Anthropic, OpenAI, etc.) might
/// use different field names. The parser handles three common
/// shapes:
///
///   * `model_remains` array (MiniMax).
///   * `data` array (the more conventional REST naming).
///   * Flat single-row object at the root.
///
/// When the response is an array, the row whose `model_name` is
/// [preferredModelName] is preferred; otherwise the first row
/// wins. MiniMax calls the coding tier `"general"`; another
/// provider might prefer `"text"`, `"code"`, or null (any).
///
/// Exposed at top level (not as a method on a service) so it
/// can be unit-tested with raw JSON strings and reused by any
/// provider's `getCodingPlanUsage()` implementation.
CodingPlanUsage parseCodingPlanUsageResponse(
  String body, {
  required String providerName,
  String? preferredModelName,
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

  // Be flexible: prefer `model_remains`, fall back to `data`,
  // fall back to a flat object.
  final dynamic rows = decoded['model_remains'] ?? decoded['data'];
  if (rows is List && rows.isNotEmpty) {
    return _pickFromRows(
      rows.cast<dynamic>(),
      providerName: providerName,
      preferredModelName: preferredModelName,
    );
  }
  if (rows == null && decoded.containsKey('interval_remaining_percent')) {
    // Flat single-row shape.
    final intervalMs = decoded['remains_time'];
    final weeklyMs = decoded['weekly_remains_time'];
    return CodingPlanUsage(
      providerName: providerName,
      modelName: decoded['model_name']?.toString() ?? 'unknown',
      intervalRemainingPct: (decoded['interval_remaining_percent'] as num)
          .toInt(),
      weeklyRemainingPct: (decoded['weekly_remaining_percent'] as num).toInt(),
      intervalRemains: intervalMs is num
          ? Duration(milliseconds: intervalMs.toInt())
          : null,
      weeklyRemains: weeklyMs is num
          ? Duration(milliseconds: weeklyMs.toInt())
          : null,
      fetchedAt: DateTime.now(),
    );
  }
  throw const CodingPlanUsageError(
    CodingPlanUsageErrorKind.parse,
    'No model_remains / data array and no flat fields',
  );
}

CodingPlanUsage _pickFromRows(
  List<dynamic> rows, {
  required String providerName,
  String? preferredModelName,
}) {
  // Prefer the row matching [preferredModelName] (e.g. "general"
  // for MiniMax's coding tier). Fall back to the first row if
  // no match.
  Map<String, dynamic>? chosen;
  if (preferredModelName != null) {
    for (final r in rows) {
      if (r is Map<String, dynamic> && r['model_name'] == preferredModelName) {
        chosen = r;
        break;
      }
    }
  }
  chosen ??= rows.first is Map<String, dynamic>
      ? rows.first as Map<String, dynamic>
      : null;
  if (chosen == null) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'model_remains contained no object rows',
    );
  }

  final interval = chosen['current_interval_remaining_percent'];
  final weekly = chosen['current_weekly_remaining_percent'];
  if (interval is! num || weekly is! num) {
    throw CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Missing current_interval_remaining_percent or '
      'current_weekly_remaining_percent in model_remains row',
    );
  }

  // Optional countdown fields, in milliseconds. Missing fields
  // silently become "no countdown" — the widget then stays on
  // the percentage readout on hover.
  final intervalRemainsMs = chosen['remains_time'];
  final weeklyRemainsMs = chosen['weekly_remains_time'];
  final intervalRemains = intervalRemainsMs is num
      ? Duration(milliseconds: intervalRemainsMs.toInt())
      : null;
  final weeklyRemains = weeklyRemainsMs is num
      ? Duration(milliseconds: weeklyRemainsMs.toInt())
      : null;

  return CodingPlanUsage(
    providerName: providerName,
    modelName: chosen['model_name']?.toString() ?? 'unknown',
    intervalRemainingPct: interval.toInt().clamp(0, 100),
    weeklyRemainingPct: weekly.toInt().clamp(0, 100),
    intervalRemains: intervalRemains,
    weeklyRemains: weeklyRemains,
    fetchedAt: DateTime.now(),
  );
}

// Layers under test:
//
//   1. `parseZhipuUsageResponse` — the Zhipu-specific JSON
//      parser for the `/api/monitor/usage/quota/limit`
//      endpoint, used by the ZhipuProvider's
//      `getCodingPlanUsage` implementation. Lives in
//      `lib/src/services/zhipu_usage_parser.dart`.
//
// The Zhipu payload is flat (`code` + `data.limits[]`),
// distinguishes the 5h / weekly rows by the row's `unit`
// number, and reports `percentage` as *used* (not remaining).
// The parser inverts that to *remaining* for the toolbar and
// surfaces a `ZHIPU Lite/Pro/Max` model name from the
// `level` field. This suite pins the four shapes the API can
// take and the four failure modes the parser must surface
// without crashing the toolbar.
import 'package:test/test.dart';

import 'package:crux/src/models/coding_plan_usage.dart';
import 'package:crux/src/services/zhipu_usage_parser.dart';

void main() {
  group('parseZhipuUsageResponse', () {
    test('reads 5h interval and weekly from the limits[] array', () {
      // The canonical "happy path" shape: 5h row at unit=3,
      // weekly row at unit=6, plus a monthly MCP TIME_LIMIT
      // row at unit=5 that the parser must ignore. The
      // timestamps are far in the future so both countdowns
      // resolve to non-null durations.
      const body = '''
{
  "code": 200,
  "data": {
    "limits": [
      {
        "type": "TOKENS_LIMIT",
        "unit": 3,
        "percentage": 16,
        "nextResetTime": 4070908800000
      },
      {
        "type": "TOKENS_LIMIT",
        "unit": 6,
        "percentage": 4,
        "nextResetTime": 4070908800000
      },
      {
        "type": "TIME_LIMIT",
        "unit": 5,
        "percentage": 0,
        "nextResetTime": 4070908800000
      }
    ],
    "level": "lite"
  }
}
''';
      final usage = parseZhipuUsageResponse(body);
      // 5h: percentage=16 used → 84% remaining.
      expect(usage.intervalRemainingPct, 84);
      // weekly: percentage=4 used → 96% remaining.
      expect(usage.weeklyRemainingPct, 96);
      // The model name surfaces the plan tier so the hover
      // hint reads "ZHIPU Lite" rather than just "zhipu".
      expect(usage.modelName, 'ZHIPU Lite');
      expect(usage.providerName, 'zhipu');
      // Both rows carry `nextResetTime` in the far future, so
      // both countdowns are non-null.
      expect(usage.intervalRemains, isNotNull);
      expect(usage.weeklyRemains, isNotNull);
    });

    test(
      'inverts percentage (used → remaining) correctly across the range',
      () {
        // A row at 100% used should map to 0% remaining (not
        // 100%); 0% used should map to 100% remaining. Without
        // the inversion the toolbar would always show "100%"
        // and the user would never see their quota drain.
        const body = '''
{
  "code": 0,
  "data": {
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 100, "nextResetTime": 4070908800000 },
      { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 0,   "nextResetTime": 4070908800000 }
    ],
    "level": "max"
  }
}
''';
        final usage = parseZhipuUsageResponse(body);
        expect(
          usage.intervalRemainingPct,
          0,
          reason: '100% used must clamp to 0% remaining, not 100%',
        );
        expect(usage.weeklyRemainingPct, 100);
        expect(usage.modelName, 'ZHIPU Max');
      },
    );

    test('picks rows by `unit`, not by array order', () {
      // The Zhipu API doesn't guarantee the order of
      // `data.limits[]`. A future tier at `unit: 5` could be
      // inserted between unit 3 and unit 6; the parser must
      // keep matching by `unit`, not by index. This guards
      // against a regression that would silently grab the
      // wrong row when the upstream reorders the array.
      const body = '''
{
  "code": 200,
  "data": {
    "limits": [
      { "type": "TIME_LIMIT",    "unit": 5, "percentage": 99, "nextResetTime": 4070908800000 },
      { "type": "TOKENS_LIMIT",  "unit": 6, "percentage": 50, "nextResetTime": 4070908800000 },
      { "type": "TOKENS_LIMIT",  "unit": 3, "percentage": 25, "nextResetTime": 4070908800000 }
    ],
    "level": "pro"
  }
}
''';
      final usage = parseZhipuUsageResponse(body);
      // 5h (unit=3): 25% used → 75% remaining.
      expect(usage.intervalRemainingPct, 75);
      // weekly (unit=6): 50% used → 50% remaining.
      // The TIME_LIMIT row at unit=5 must NOT bleed into
      // either cell.
      expect(usage.weeklyRemainingPct, 50);
      expect(usage.modelName, 'ZHIPU Pro');
    });

    test('missing TOKENS_LIMIT rows default to 0% remaining', () {
      // Defensive path: a partial response (e.g. the user is
      // on a tier that doesn't grant one of the windows)
      // shouldn't lock the toolbar on "—". Missing row →
      // 0% remaining + no countdown. The user can still see
      // the cell, just at zero.
      const body = '''
{
  "code": 200,
  "data": {
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 20, "nextResetTime": 4070908800000 }
    ],
    "level": "lite"
  }
}
''';
      final usage = parseZhipuUsageResponse(body);
      expect(
        usage.intervalRemainingPct,
        80,
        reason: 'unit=3 row present → 80% remaining (20 used)',
      );
      expect(
        usage.weeklyRemainingPct,
        0,
        reason:
            'unit=6 row missing → defaults to 0% remaining, '
            'not a crash',
      );
      expect(usage.intervalRemains, isNotNull);
      expect(usage.weeklyRemains, isNull);
    });

    test('missing `level` falls back to the provider name', () {
      // Older or differently-configured responses may omit
      // `data.level`. The model name should fall back to the
      // provider name (the only string we know is correct) so
      // the hover hint never reads empty.
      const body = '''
{
  "code": 200,
  "data": {
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 10, "nextResetTime": 4070908800000 },
      { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 10, "nextResetTime": 4070908800000 }
    ]
  }
}
''';
      final usage = parseZhipuUsageResponse(body);
      expect(
        usage.modelName,
        'zhipu',
        reason:
            'missing level → fall back to the provider name, '
            'not "ZHIPU " (with a trailing space) or empty',
      );
    });

    test('past reset times produce null countdowns', () {
      // `nextResetTime` in the past means the window has
      // already reset and the server is reporting a stale
      // value. The parser must NOT show a negative ticker
      // ("-3d 4h") on the toolbar — null is the right
      // signal for the format helper to render no countdown.
      const body = '''
{
  "code": 200,
  "data": {
    "limits": [
      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 10, "nextResetTime": 1577836800000 },
      { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 10, "nextResetTime": 1577836800000 }
    ],
    "level": "lite"
  }
}
''';
      final usage = parseZhipuUsageResponse(body);
      expect(
        usage.intervalRemains,
        isNull,
        reason: 'past reset → no countdown (not negative duration)',
      );
      expect(usage.weeklyRemains, isNull);
      // Percentages still read normally even when the
      // countdown is gone.
      expect(usage.intervalRemainingPct, 90);
    });

    group('error shapes', () {
      test('non-2xx `code` field surfaces a parse error with the message', () {
        const body = '''
{ "code": 401, "msg": "invalid api key" }
''';
        expect(
          () => parseZhipuUsageResponse(body),
          throwsA(
            isA<CodingPlanUsageError>()
                .having((e) => e.kind, 'kind', CodingPlanUsageErrorKind.parse)
                .having((e) => e.message, 'message', contains('code=401')),
          ),
        );
      });

      test('missing `data` block is a parse error', () {
        const body = '{ "code": 200 }';
        expect(
          () => parseZhipuUsageResponse(body),
          throwsA(
            isA<CodingPlanUsageError>().having(
              (e) => e.kind,
              'kind',
              CodingPlanUsageErrorKind.parse,
            ),
          ),
        );
      });

      test('empty `data.limits` is a parse error', () {
        const body = '{ "code": 200, "data": { "limits": [] } }';
        expect(
          () => parseZhipuUsageResponse(body),
          throwsA(
            isA<CodingPlanUsageError>().having(
              (e) => e.kind,
              'kind',
              CodingPlanUsageErrorKind.parse,
            ),
          ),
        );
      });

      test('non-JSON body is a parse error', () {
        expect(
          () => parseZhipuUsageResponse('not json'),
          throwsA(
            isA<CodingPlanUsageError>()
                .having((e) => e.kind, 'kind', CodingPlanUsageErrorKind.parse)
                .having((e) => e.message, 'message', contains('Invalid JSON')),
          ),
        );
      });
    });
  });
}

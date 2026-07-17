// Layers under test:
//
//   1. `parseKimiUsageResponse` — the Kimi-specific JSON
//      parser for the `/usages` endpoint, used by the
//      KimiProvider's `getCodingPlanUsage` implementation.
//      Lives in `lib/src/services/kimi_usage_parser.dart`.
//
// The Kimi platform's payload is flexible (a `usage` summary
// plus a `limits[]` array of time-windowed rows), so this
// suite covers each field-name shape the kimi-cli parser
// also tolerates — `used` vs. `remaining`, `reset_at` vs.
// `resetIn` / `reset_in`, `window.duration` in MINUTE / HOUR
// / DAY — so a Kimi API tweak that flips naming convention
// doesn't silently zero out the toolbar.
import 'package:test/test.dart';

import 'package:crux/src/models/coding_plan_usage.dart';
import 'package:crux/src/services/kimi_usage_parser.dart';

void main() {
  group('parseKimiUsageResponse', () {
    test('reads 5h interval and 1w weekly from the limits[] array', () {
      const body = '''
{
  "usage": {
    "name": "Weekly limit",
    "limit": 1000,
    "used": 500,
    "reset_at": "2099-01-01T00:00:00Z"
  },
  "limits": [
    {
      "name": "5h",
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": {
        "limit": 100,
        "used": 20,
        "remaining": 80,
        "reset_at": "2099-01-01T00:00:00Z"
      }
    },
    {
      "name": "1w",
      "window": { "duration": 10080, "timeUnit": "MINUTE" },
      "detail": {
        "limit": 1000,
        "used": 500,
        "remaining": 500,
        "reset_at": "2099-01-08T00:00:00Z"
      }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // 5h row: limit=100, used=20 → 80% remaining.
      expect(usage.intervalRemainingPct, 80);
      // 1w row: limit=1000, used=500 → 50% remaining.
      expect(usage.weeklyRemainingPct, 50);
      expect(usage.modelName, 'Weekly limit');
      expect(usage.providerName, 'kimi');
      // Both rows carry `reset_at` in the far future, so
      // both countdowns are non-null.
      expect(usage.intervalRemains, isNotNull);
      expect(usage.weeklyRemains, isNotNull);
    });

    test('picks shortest / longest windows regardless of array order', () {
      // The Kimi API doesn't guarantee window order; the
      // parser sorts by duration and picks the two ends.
      const body = '''
{
  "usage": { "name": "Weekly" },
  "limits": [
    {
      "name": "1w",
      "window": { "duration": 10080, "timeUnit": "MINUTE" },
      "detail": { "limit": 1000, "used": 250 }
    },
    {
      "name": "5h",
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "used": 50 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // Shortest = 5h row (50% remaining).
      expect(usage.intervalRemainingPct, 50);
      // Longest = 1w row (75% remaining).
      expect(usage.weeklyRemainingPct, 75);
    });

    test('single-row limits[] with no `usage` block duplicates the row', () {
      // Degenerate case: the API returns one window in
      // `limits[]` and no top-level `usage` summary. The
      // parser duplicates the interval row into the weekly
      // slot rather than zeroing it — better to show
      // "5h 80% / 1w 80%" than to crash the toolbar on a
      // missing weekly value.
      const body = '''
{
  "limits": [
    {
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "used": 20 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      expect(usage.intervalRemainingPct, 80);
      expect(usage.weeklyRemainingPct, 80);
    });

    test('single-row limits[] + top-level `usage` block: weekly from usage, '
        'not duplicated from the 5h row', () {
      // Regression: the user reported the coding-plan
      // indicator reporting the 5h value for BOTH the 5h
      // and the 1w cell. The Kimi API commonly returns
      // exactly this shape: one 5h row in `limits[]` plus
      // a top-level `usage` block (the "Weekly limit"
      // summary per Kimi's own docs and the kimi-cli
      // `/usage` command). The previous behavior used the
      // 5h row for both cells because `sorted.first ==
      // sorted.last`; the new behavior routes the weekly
      // cell to the `usage` block instead.
      const body = '''
{
  "usage": {
    "name": "Weekly limit",
    "limit": 1000,
    "used": 250,
    "reset_at": "2099-01-08T00:00:00Z"
  },
  "limits": [
    {
      "name": "5h",
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": {
        "limit": 100,
        "used": 40,
        "remaining": 60,
        "reset_at": "2099-01-01T00:00:00Z"
      }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // 5h row → 60% remaining for the interval cell.
      expect(
        usage.intervalRemainingPct,
        60,
        reason: 'interval cell reads from the limits[] 5h row',
      );
      // usage block → 75% remaining for the weekly cell
      // (NOT 60%, which is the bug the user reported).
      expect(
        usage.weeklyRemainingPct,
        75,
        reason:
            'weekly cell must read from the top-level `usage` '
            'block, not duplicate the 5h row — that duplication '
            'was the regression',
      );
      // The model name comes from the `usage` block too.
      expect(usage.modelName, 'Weekly limit');
      // Both cells should carry their own countdown, since
      // the 5h row and the usage block each had a
      // `reset_at`.
      expect(usage.intervalRemains, isNotNull);
      expect(usage.weeklyRemains, isNotNull);
    });

    test('multiple `limits[]` rows still win over the `usage` block', () {
      // When the API returns both a 5h and a 1w row in
      // `limits[]`, those two rows are the source of truth
      // for the interval/weekly cells — the `usage` block
      // is used only for the model name (and as a
      // weekly-summary hint), not for the weekly
      // percentage. This guards the precedence order so a
      // future "always prefer the usage block" patch
      // doesn't regress the 5h/1w case.
      const body = '''
{
  "usage": {
    "name": "Different weekly number",
    "limit": 9999,
    "used": 9999
  },
  "limits": [
    {
      "name": "5h",
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "used": 20 }
    },
    {
      "name": "1w",
      "window": { "duration": 10080, "timeUnit": "MINUTE" },
      "detail": { "limit": 1000, "used": 500 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // Weekly from the 1w row in limits[], not the usage
      // block — limits[] takes precedence when it has
      // multiple distinct windows.
      expect(
        usage.weeklyRemainingPct,
        50,
        reason:
            'weekly cell must read from the 1w row, not the '
            'usage block — limits[] wins when it has '
            'multiple distinct windows',
      );
      // The model name still comes from the usage block.
      expect(usage.modelName, 'Different weekly number');
    });

    test('summary-only usage block populates both cells', () {
      // Some endpoints return just the top-level `usage`
      // summary with no `limits[]` array.
      const body = '''
{
  "usage": {
    "name": "Weekly limit",
    "limit": 1000,
    "used": 100
  }
}
''';
      final usage = parseKimiUsageResponse(body);
      expect(usage.intervalRemainingPct, 90);
      expect(usage.weeklyRemainingPct, 90);
      expect(usage.modelName, 'Weekly limit');
    });

    test('derives used from remaining when used is absent', () {
      // Some Kimi payload variants report `remaining` instead
      // of `used` (consistent with OpenAI usage). The parser
      // computes used = limit - remaining.
      const body = '''
{
  "limits": [
    {
      "window": { "duration": 60, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "remaining": 25 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // 100 - 25 = 75 used → 25% remaining.
      expect(usage.intervalRemainingPct, 25);
    });

    test('tolerates camelCase resetAt and resetIn', () {
      // Different Kimi SDK revisions name the fields
      // differently. The parser accepts both snake_case and
      // camelCase so a future API naming flip doesn't zero
      // out the countdowns.
      final futureIso = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 3))
          .toIso8601String();
      final body =
          '''
{
  "limits": [
    {
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "used": 20, "resetAt": "$futureIso" }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      expect(
        usage.intervalRemains,
        isNotNull,
        reason:
            'camelCase resetAt should resolve to a non-null '
            'countdown — the parser covers the kimi-cli '
            'naming variants too',
      );
    });

    test('tolerates reset_in (relative seconds) instead of reset_at', () {
      const body = '''
{
  "limits": [
    {
      "window": { "duration": 300, "timeUnit": "MINUTE" },
      "detail": { "limit": 100, "used": 20, "reset_in": 7200 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      expect(usage.intervalRemains, const Duration(seconds: 7200));
    });

    test('handles all three time units (MINUTE, HOUR, DAY)', () {
      // The `window.timeUnit` is a free-form string in
      // practice; the parser must multiply duration by the
      // right factor regardless of which unit the API
      // emits, or rows would sort into the wrong cells.
      const body = '''
{
  "limits": [
    {
      "name": "1d",
      "window": { "duration": 1, "timeUnit": "DAY" },
      "detail": { "limit": 100, "used": 0 }
    },
    {
      "name": "5h",
      "window": { "duration": 5, "timeUnit": "HOUR" },
      "detail": { "limit": 100, "used": 50 }
    }
  ]
}
''';
      final usage = parseKimiUsageResponse(body);
      // 5h row → 50% remaining (shortest window).
      expect(usage.intervalRemainingPct, 50);
      // 1d row → 100% remaining (longest window).
      expect(usage.weeklyRemainingPct, 100);
    });

    test('throws on invalid JSON', () {
      expect(
        () => parseKimiUsageResponse('not json at all'),
        throwsA(
          isA<CodingPlanUsageError>().having(
            (e) => e.kind,
            'kind',
            CodingPlanUsageErrorKind.parse,
          ),
        ),
      );
    });

    test(
      'falls back to the generic parser when no Kimi-shaped fields are present',
      () {
        // Payload that's neither Kimi-shaped (no `usage` / no
        // `limits`) nor MiniMax-shaped (no `model_remains` /
        // no `data`) surfaces a parse error from the generic
        // parser rather than silently returning zeros.
        const body = '''
{
  "totally_unrelated": {"foo": 1}
}
''';
        expect(
          () => parseKimiUsageResponse(body),
          throwsA(isA<CodingPlanUsageError>()),
        );
      },
    );
  });
}

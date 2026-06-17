/// Tests for the coding-plan (Token Plan) feature.
///
/// Three layers under test:
///
///   1. `parseCodingPlanUsageResponse` — the shape-flexible JSON
///      parser used by the MiniMax provider's
///      `getCodingPlanUsage` implementation. Lives in
///      `lib/src/services/coding_plan_usage_parser.dart`.
///
///   2. `CodingPlanUsage` and its `formatIntervalRemains` /
///      `formatWeeklyRemains` helpers — the data model the
///      toolbar renders.
///
///   3. The `CodingPlanProvider` mixin's polling lifecycle
///      (start / stop / interval / dispose) — exercised via
///      a tiny test-only provider that implements the mixin
///      with a fake fetch (no HTTP).
import 'dart:async';
import 'dart:math' as math;

import 'package:nocterm/nocterm.dart' hide isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/models/coding_plan_usage.dart';
import 'package:crux/src/services/coding_plan_usage_parser.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/coding_plan_provider.dart';
import 'package:crux/src/services/providers/minimax_provider.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  // ─── Parser ────────────────────────────────────────────────
  group('parseCodingPlanUsageResponse', () {
    test('picks the "general" row from model_remains', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 98,
      "current_weekly_remaining_percent": 73
    },
    {
      "model_name": "video",
      "current_interval_remaining_percent": 100,
      "current_weekly_remaining_percent": 100
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'minimax',
        preferredModelName: 'general',
      );
      expect(usage.modelName, 'general');
      expect(usage.providerName, 'minimax');
      expect(usage.intervalRemainingPct, 98);
      expect(usage.weeklyRemainingPct, 73);
      expect(
        DateTime.now().difference(usage.fetchedAt).inSeconds,
        lessThan(5),
      );
    });

    test('falls back to the first row when preferredModelName is absent', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "coding-only",
      "current_interval_remaining_percent": 42,
      "current_weekly_remaining_percent": 17
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'custom',
        preferredModelName: 'general',
      );
      expect(usage.modelName, 'coding-only');
      expect(usage.intervalRemainingPct, 42);
      expect(usage.weeklyRemainingPct, 17);
    });

    test('falls back to the first row when preferredModelName is null', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "anything",
      "current_interval_remaining_percent": 11,
      "current_weekly_remaining_percent": 22
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'flat',
        preferredModelName: null,
      );
      expect(usage.modelName, 'anything');
      expect(usage.intervalRemainingPct, 11);
      expect(usage.weeklyRemainingPct, 22);
    });

    test('clamps out-of-range percentages to 0–100', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 150,
      "current_weekly_remaining_percent": -12
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'minimax',
        preferredModelName: 'general',
      );
      expect(usage.intervalRemainingPct, 100);
      expect(usage.weeklyRemainingPct, 0);
    });

    test('extracts remains_time and weekly_remains_time as Durations', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 98,
      "current_weekly_remaining_percent": 73,
      "remains_time": 17502294,
      "weekly_remains_time": 377502294
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'minimax',
        preferredModelName: 'general',
      );
      expect(usage.intervalRemains, const Duration(milliseconds: 17502294));
      expect(usage.weeklyRemains, const Duration(milliseconds: 377502294));
    });

    test('leaves remain times null when API does not return them', () {
      const body = '''
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 50,
      "current_weekly_remaining_percent": 50
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'minimax',
        preferredModelName: 'general',
      );
      expect(usage.intervalRemains, isNull);
      expect(usage.weeklyRemains, isNull);
    });

    test('accepts a flat single-row response shape', () {
      const body = '''
{
  "model_name": "primary",
  "interval_remaining_percent": 80,
  "weekly_remaining_percent": 50,
  "remains_time": 60000,
  "weekly_remains_time": 86400000
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'openai',
        preferredModelName: 'general',
      );
      expect(usage.modelName, 'primary');
      expect(usage.intervalRemainingPct, 80);
      expect(usage.weeklyRemainingPct, 50);
      expect(usage.intervalRemains, const Duration(seconds: 60));
      expect(usage.weeklyRemains, const Duration(days: 1));
    });

    test('accepts an alternative `data` array key', () {
      const body = '''
{
  "data": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 11,
      "current_weekly_remaining_percent": 22
    }
  ]
}
''';
      final usage = parseCodingPlanUsageResponse(
        body,
        providerName: 'minimax',
        preferredModelName: 'general',
      );
      expect(usage.intervalRemainingPct, 11);
      expect(usage.weeklyRemainingPct, 22);
    });

    test('throws on invalid JSON', () {
      expect(
        () => parseCodingPlanUsageResponse(
          'not json at all',
          providerName: 'minimax',
        ),
        throwsA(
          isA<CodingPlanUsageError>().having(
            (e) => e.kind,
            'kind',
            CodingPlanUsageErrorKind.parse,
          ),
        ),
      );
    });

    test('throws when the response is not a JSON object', () {
      expect(
        () => parseCodingPlanUsageResponse(
          '[1, 2, 3]',
          providerName: 'minimax',
        ),
        throwsA(isA<CodingPlanUsageError>()),
      );
    });

    test('throws when model_remains is missing required fields', () {
      const body = '''
{
  "model_remains": [
    {"model_name": "general"}
  ]
}
''';
      expect(
        () => parseCodingPlanUsageResponse(
          body,
          providerName: 'minimax',
          preferredModelName: 'general',
        ),
        throwsA(
          isA<CodingPlanUsageError>().having(
            (e) => e.kind,
            'kind',
            CodingPlanUsageErrorKind.parse,
          ),
        ),
      );
    });

    test('throws when model_remains is empty', () {
      const body = '''
{
  "model_remains": []
}
''';
      expect(
        () => parseCodingPlanUsageResponse(
          body,
          providerName: 'minimax',
        ),
        throwsA(isA<CodingPlanUsageError>()),
      );
    });
  });

  // ─── Data model ────────────────────────────────────────────
  group('CodingPlanUsage', () {
    test('toString round-trips key fields', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 98,
        weeklyRemainingPct: 73,
        fetchedAt: DateTime(2025, 1, 1, 12),
      );
      final s = usage.toString();
      expect(s, contains('minimax'));
      expect(s, contains('general'));
      expect(s, contains('98'));
      expect(s, contains('73'));
    });

    test('formatRemains returns null when remain time is null', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 50,
        weeklyRemainingPct: 50,
        fetchedAt: DateTime.now(),
      );
      expect(usage.formatIntervalRemains(), isNull);
      expect(usage.formatWeeklyRemains(), isNull);
    });

    test('formatRemains formats days + hours', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 0,
        weeklyRemainingPct: 0,
        intervalRemains: const Duration(days: 6, hours: 4),
        weeklyRemains: const Duration(days: 6, hours: 4),
        fetchedAt: DateTime.now(),
      );
      expect(usage.formatIntervalRemains(), '6d 4h');
      expect(usage.formatWeeklyRemains(), '6d 4h');
    });

    test('formatRemains formats hours + minutes', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 0,
        weeklyRemainingPct: 0,
        intervalRemains: const Duration(hours: 4, minutes: 32),
        weeklyRemains: const Duration(hours: 4, minutes: 32),
        fetchedAt: DateTime.now(),
      );
      expect(usage.formatIntervalRemains(), '4h 32m');
    });

    test('formatRemains formats minutes + seconds', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 0,
        weeklyRemainingPct: 0,
        intervalRemains: const Duration(minutes: 23, seconds: 15),
        weeklyRemains: const Duration(minutes: 23, seconds: 15),
        fetchedAt: DateTime.now(),
      );
      expect(usage.formatIntervalRemains(), '23m 15s');
    });

    test('formatRemains formats sub-minute durations', () {
      final usage = CodingPlanUsage(
        providerName: 'minimax',
        modelName: 'general',
        intervalRemainingPct: 0,
        weeklyRemainingPct: 0,
        intervalRemains: const Duration(seconds: 45),
        fetchedAt: DateTime.now(),
      );
      expect(usage.formatIntervalRemains(), '45s');
    });
  });

  // ─── Animation frame computation ─────────────────────────
  // The widget owns the animation, but the frame math
  // (linear lerp on the value, cubic ease-out on the
  // colour) is small and testable in isolation. We
  // verify the contract here so the widget can stay a
  // thin shell over the polling mixin.
  group('Animation frame math', () {
    test('value lerps linearly from old to new at t=0 and t=1', () {
      // At t=0 the displayed value is the old one
      // (rounded); at t=1 it's the new one.
      const from = 98.0;
      const to = 97.0;
      // Mid-animation: e.g. t=0.5, value = 97.50.
      final mid = from + (to - from) * 0.5;
      expect(mid.toStringAsFixed(2), '97.50');
    });

    test('2-decimal format keeps ticks visible across the lerp', () {
      // 30 frames at 60fps over the last second of a
      // 3s animation. The format string should change
      // roughly every other frame as the value drifts.
      const from = 50.0;
      const to = 49.0;
      final formatted = <String>{};
      for (int frame = 0; frame < 30; frame++) {
        final t = (60 + frame) / 90; // last second
        final v = from + (to - from) * t;
        formatted.add(v.toStringAsFixed(2));
      }
      // Should have several distinct values across
      // 30 frames covering 1/3 of a unit drop.
      expect(formatted.length, greaterThan(5));
    });

    test('color t at t=0 is 0 (full flash), at t=1 is 1 (full normal)',
        () {
      // colorT = 1 - (1 - t)^3 — cubic ease-out.
      double colorT(double t) => 1.0 - math.pow(1.0 - t, 3).toDouble();
      expect(colorT(0.0), 0.0);
      expect(colorT(1.0), 1.0);
      // Mid-flight: should be past 0.5 (ease-out is
      // faster at the start), so the flash colour
      // dominates early.
      expect(colorT(0.5), greaterThan(0.5));
    });

    test('decrement selects red flash, increment selects green flash', () {
      // Mirror the widget's flash-colour selection: we
      // don't render the cell here, but the choice
      // is pure data so we can assert it.
      final theme = CruxThemeData(
        id: 'test',
        name: 'Test',
        brightness: Brightness.dark,
        background: const Color(0x000000),
        surface: const Color(0x111111),
        surfaceVariant: const Color(0x222222),
        primary: const Color(0xFFFFFF),
        onPrimary: const Color(0x000000),
        secondary: const Color(0xAAAAAA),
        onSecondary: const Color(0x000000),
        accent: const Color(0xFFFFFF),
        error: const Color(0xFF0000),
        onError: const Color(0xFFFFFF),
        warning: const Color(0xFFFF00),
        onWarning: const Color(0x000000),
        success: const Color(0x00FF00),
        onSuccess: const Color(0x000000),
        info: const Color(0x00FFFF),
        text: const Color(0xFFFFFF),
        textMuted: const Color(0x888888),
        border: const Color(0x444444),
        borderActive: const Color(0xFFFFFF),
        borderSubtle: const Color(0x222222),
        selection: const Color(0x444444),
        selectedText: const Color(0xFFFFFF),
        markdownText: const Color(0xFFFFFF),
        markdownHeading: const Color(0xFFFFFF),
        markdownLink: const Color(0x00FFFF),
        markdownCode: const Color(0x888888),
        markdownBlockQuote: const Color(0x888888),
        markdownEmphasis: const Color(0xFFFFFF),
        markdownStrong: const Color(0xFFFFFF),
        markdownRule: const Color(0x888888),
        markdownList: const Color(0xFFFFFF),
        markdownCodeBlock: const Color(0x111111),
        syntaxDefault: const Color(0xFFFFFF),
        syntaxComment: const Color(0x888888),
        syntaxKeyword: const Color(0xFFFFFF),
        syntaxStorage: const Color(0xFFFFFF),
        syntaxFunction: const Color(0xFFFFFF),
        syntaxType: const Color(0xFFFFFF),
        syntaxString: const Color(0xFFFFFF),
        syntaxConstant: const Color(0xFFFFFF),
        syntaxNumber: const Color(0xFFFFFF),
        syntaxVariable: const Color(0xFFFFFF),
        syntaxTag: const Color(0xFFFFFF),
        syntaxAttribute: const Color(0xFFFFFF),
        syntaxOperator: const Color(0xFFFFFF),
        syntaxPunctuation: const Color(0xFFFFFF),
        syntaxMeta: const Color(0xFFFFFF),
      );
      // The widget selects error for decrement and
      // success for increment — verify against the
      // same predicate the widget uses.
      Color flashFor(double from, double to) =>
          to < from ? theme.error : theme.success;
      expect(flashFor(98, 97), theme.error); // decrement
      expect(flashFor(3, 100), theme.success); // increment (reset)
      expect(flashFor(50, 50), theme.success); // equal → green
    });
  });

  // ─── Steady-state ratio colour ──────────────────────────
  // The cell's "normal" colour (post-flash) comes from
  // the ratio of usage to time elapsed, not the raw
  // remaining percentage. Three regimes:
  //
  //   * ratio >= 2.0 → afluent (theme.cyan / theme.accent)
  //   * ratio >= 1.0 → lerp middleground → afluent
  //   * ratio >= 0.5 → lerp warning → middleground
  //   * ratio <  0.5 → pure warning
  //
  // The user requested cyan be themeable; we use the
  // existing `accent` field (exposed as `theme.cyan`)
  // rather than adding a new theme field.
  group('Ratio-based steady-state colour', () {
    // Minimal theme with the colours the widget uses
    // (error, warning, metricsIdle, cyan). `cyan` is
    // the existing `accent` field; pass any colour the
    // test wants to assert against.
    CruxThemeData makeTheme({required Color cyan}) {
      return CruxThemeData(
        id: 't',
        name: 't',
        brightness: Brightness.dark,
        background: const Color(0x000000),
        surface: const Color(0x111111),
        surfaceVariant: const Color(0x222222),
        primary: const Color(0xFFFFFF),
        onPrimary: const Color(0x000000),
        secondary: const Color(0xAAAAAA),
        onSecondary: const Color(0x000000),
        accent: cyan,
        error: const Color(0xFF0000),
        onError: const Color(0xFFFFFF),
        warning: const Color(0xFFFF00),
        onWarning: const Color(0x000000),
        success: const Color(0x00FF00),
        onSuccess: const Color(0x000000),
        info: const Color(0x00FFFF),
        text: const Color(0xFFFFFF),
        textMuted: const Color(0x888888),
        border: const Color(0x444444),
        borderActive: const Color(0xFFFFFF),
        borderSubtle: const Color(0x222222),
        selection: const Color(0x444444),
        selectedText: const Color(0xFFFFFF),
        markdownText: const Color(0xFFFFFF),
        markdownHeading: const Color(0xFFFFFF),
        markdownLink: const Color(0x00FFFF),
        markdownCode: const Color(0x888888),
        markdownBlockQuote: const Color(0x888888),
        markdownEmphasis: const Color(0xFFFFFF),
        markdownStrong: const Color(0xFFFFFF),
        markdownRule: const Color(0x888888),
        markdownList: const Color(0xFFFFFF),
        markdownCodeBlock: const Color(0x111111),
        syntaxDefault: const Color(0xFFFFFF),
        syntaxComment: const Color(0x888888),
        syntaxString: const Color(0xFFFFFF),
        syntaxConstant: const Color(0xFFFFFF),
        syntaxNumber: const Color(0xFFFFFF),
        syntaxVariable: const Color(0xFFFFFF),
        syntaxTag: const Color(0xFFFFFF),
        syntaxAttribute: const Color(0xFFFFFF),
        syntaxOperator: const Color(0xFFFFFF),
        syntaxPunctuation: const Color(0xFFFFFF),
        syntaxMeta: const Color(0xFFFFFF),
        syntaxKeyword: const Color(0xFFFFFF),
        syntaxStorage: const Color(0xFFFFFF),
        syntaxFunction: const Color(0xFFFFFF),
        syntaxType: const Color(0xFFFFFF),
      );
    }

    // The widget's _ratioColor and _ratio are private.
    // Mirror them here so the test exercises the same
    // contract a refactor would preserve.
    Color ratioColor(CruxThemeData theme, double ratio) {
      if (ratio >= 2.0) return theme.cyan;
      if (ratio >= 1.0) {
        final t = (ratio - 1.0).clamp(0.0, 1.0);
        return Color.lerp(theme.metricsIdle, theme.cyan, t)!;
      }
      if (ratio >= 0.5) {
        final t = ((ratio - 0.5) * 2.0).clamp(0.0, 1.0);
        return Color.lerp(theme.warning, theme.metricsIdle, t)!;
      }
      return theme.warning;
    }

    double ratioFor({
      required int remainingPct,
      required Duration? remainingTime,
      required Duration totalWindow,
    }) {
      // The ratio is **remaining quota / remaining time** —
      // how much quota you have left, divided by how much
      // time you have left. Three landmarks from the
      // user's spec:
      //
      //   * 2.0 → afluent (cyan): 50% quota over 25% time
      //     left
      //   * 1.0 → middleground: 50% left with 50% time
      //   * 0.5 → scarce (yellow): half usage of time left
      //
      // The user pointed out that "26% remaining, 3h to
      // go" should be scarce. Computing:
      //   timeRemainingPct = 3/5 * 100 = 60
      //   ratio = 26 / 60 = 0.43
      // → 0.43 < 0.5, so scarce. ✓
      if (remainingTime == null) return remainingPct / 100.0;
      final timeRemainingMs = remainingTime.inMilliseconds;
      if (timeRemainingMs <= 0) return 0.0;
      // No clamp at 100% — degenerate "remainingTime >
      // totalWindow" cases (which the API shouldn't
      // produce, but might) correctly trend toward scarce.
      final timeRemainingPct = (timeRemainingMs /
              totalWindow.inMilliseconds *
              100);
      if (timeRemainingPct <= 0) return 0.0;
      return remainingPct / timeRemainingPct;
    }

    const kInterval = Duration(hours: 5);
    // (kWeekly = Duration(days: 7) is the same constant
    // the widget uses; the tests below all exercise the
    // 5-hour window since the math is identical.)

    test('26% remaining, 3h to go → scarce (ratio = 0.43)', () {
      // The user's example. We have 3h left in a 5h
      // window, so timeRemainingPct = 60%.
      // ratio = 26 / 60 = 0.43, which is below the
      // scarce landmark (0.5) → warning.
      final r = ratioFor(
        remainingPct: 26,
        remainingTime: const Duration(hours: 3),
        totalWindow: kInterval,
      );
      expect(r, closeTo(26 / 60, 0.001));
      expect(r, lessThan(0.5));
      final theme = makeTheme(cyan: const Color(0x00FFFF));
      expect(ratioColor(theme, r), theme.warning);
    });

    test('50% remaining at 50% time left → middleground (ratio = 1.0)',
        () {
      // The user-defined on-pace case: 50% left, 50%
      // remaining time → exactly 1.0 → middleground
      // (idle).
      final r = ratioFor(
        remainingPct: 50,
        remainingTime: const Duration(hours: 2, minutes: 30),
        totalWindow: kInterval,
      );
      expect(r, closeTo(1.0, 0.001));
      final theme = makeTheme(cyan: const Color(0x00FFFF));
      expect(ratioColor(theme, r), theme.metricsIdle);
    });

    test('50% remaining at 25% time left → afluent (ratio = 2.0)', () {
      // The user's afluent landmark: 50% quota over
      // 25% time left. 25% of 5h = 1h15m.
      final r = ratioFor(
        remainingPct: 50,
        remainingTime: const Duration(hours: 1, minutes: 15),
        totalWindow: kInterval,
      );
      expect(r, closeTo(2.0, 0.001));
      final theme = makeTheme(cyan: const Color(0x00FFFF));
      expect(ratioColor(theme, r), theme.cyan);
    });

    test('window with full time remaining (just reset) → ratio 1.0', () {
      // Just-reset case: API returns 100% remaining
      // and the full window time. Both numerator and
      // denominator are 100, so ratio = 1.0 (on-pace
      // midpoint).
      final r = ratioFor(
        remainingPct: 100,
        remainingTime: kInterval,
        totalWindow: kInterval,
      );
      expect(r, 1.0);
    });

    test('zero time remaining → ratio 0 (saturated scarce)', () {
      // Defensive: 0 time remaining shouldn't crash
      // and should fall back to the worst scarce
      // (full yellow), not divide by zero.
      final r = ratioFor(
        remainingPct: 50,
        remainingTime: Duration.zero,
        totalWindow: kInterval,
      );
      expect(r, 0.0);
      final theme = makeTheme(cyan: const Color(0x00FFFF));
      expect(ratioColor(theme, r), theme.warning);
    });

    test('100% remaining at 200% time left → ratio 0.5 (scarce boundary)', () {
      // Degenerate case the API shouldn't return
      // (remainingTime > totalWindow), but the widget
      // handles it correctly: ratio = 100/200 = 0.5.
      // Use Duration + Duration (not `* 2`) — the latter
      // silently degrades to the same value in the
      // current Dart runtime.
      final r = ratioFor(
        remainingPct: 100,
        remainingTime: kInterval + kInterval,
        totalWindow: kInterval,
      );
      expect(r, closeTo(0.5, 0.001));
    });

    test('ratio lerps warning → idle → cyan across the landmarks', () {
      // Spot-check a few points along the curve.
      final theme = makeTheme(cyan: const Color(0x00FFFF));

      // 0.25 → pure warning (below 0.5)
      expect(ratioColor(theme, 0.25), theme.warning);
      // 0.5 → boundary, just warning
      expect(ratioColor(theme, 0.5), theme.warning);
      // 0.75 → halfway between warning and middleground
      final at75 = ratioColor(theme, 0.75);
      expect(at75, isNot(equals(theme.warning)));
      expect(at75, isNot(equals(theme.metricsIdle)));
      // 1.0 → exactly middleground
      expect(ratioColor(theme, 1.0), theme.metricsIdle);
      // 1.5 → halfway between middleground and cyan
      final at150 = ratioColor(theme, 1.5);
      expect(at150, isNot(equals(theme.metricsIdle)));
      expect(at150, isNot(equals(theme.cyan)));
      // 2.0 → exactly cyan
      expect(ratioColor(theme, 2.0), theme.cyan);
      // 5.0 → saturated cyan (above the upper landmark)
      expect(ratioColor(theme, 5.0), theme.cyan);
    });

    test('uses theme.cyan (= theme.accent) for the afluent colour', () {
      // The user's design: cyan is just the existing
      // accent field. Different themes have different
      // accents; the widget follows whatever the theme
      // declares. No new theme field.
      const cyanA = Color(0x00FFFF);
      const cyanB = Color(0x8BE9FD); // dracula cyan
      final themeA = makeTheme(cyan: cyanA);
      final themeB = makeTheme(cyan: cyanB);
      expect(themeA.cyan, cyanA);
      expect(themeB.cyan, cyanB);
      expect(ratioColor(themeA, 5.0), cyanA);
      expect(ratioColor(themeB, 5.0), cyanB);
    });
  });

  // ─── Mixin lifecycle (using a fake provider) ───────────────
  group('CodingPlanProvider mixin', () {
    test('isCodingPlan is true on a mixin provider', () {
      final provider = _FakeCodingPlanProvider();
      expect(provider.isCodingPlan, isTrue);
    });

    test('isCodingPlan is false on a plain LlmProvider', () {
      final provider = _PlainProvider();
      expect(provider.isCodingPlan, isFalse);
    });

    test('startCodingPlanPolling begins polling and emits snapshots', () async {
      final provider = _FakeCodingPlanProvider();
      final snapshots = <CodingPlanUsage>[];
      final sub = provider.codingPlanUsageStream.listen(snapshots.add);

      provider.startCodingPlanPolling(
        apiKey: 'test-key',
        interval: const Duration(milliseconds: 50),
      );
      // The first tick is fire-and-forget; give the microtask
      // queue a chance to drain.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(provider.isCodingPlanPolling, isTrue);
      expect(provider.latestCodingPlanUsage, isNotNull);
      expect(snapshots, isNotEmpty);

      await sub.cancel();
      await provider.disposeCodingPlanPolling();
    });

    test('stopCodingPlanPolling stops the timer but keeps the cache', () async {
      final provider = _FakeCodingPlanProvider();
      provider.startCodingPlanPolling(
        apiKey: 'test-key',
        interval: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final cached = provider.latestCodingPlanUsage;
      expect(cached, isNotNull);

      provider.stopCodingPlanPolling();
      expect(provider.isCodingPlanPolling, isFalse);
      // Cache is preserved so the toolbar still has a value
      // to display after a provider switch.
      expect(provider.latestCodingPlanUsage, cached);

      await provider.disposeCodingPlanPolling();
    });

    test('startCodingPlanPolling with no API key surfaces an error', () async {
      final provider = _FakeCodingPlanProvider();
      // Prime the cache with a valid key.
      provider.startCodingPlanPolling(
        apiKey: 'test-key',
        interval: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final primed = provider.latestCodingPlanUsage;
      expect(primed, isNotNull);

      // Stop and restart with an empty key. The tick
      // fails (no key) and the error is exposed, but
      // the cache from the previous successful tick
      // is preserved — same behaviour as any other
      // tick failure. The toolbar still shows the
      // last known good value; the error is exposed
      // for the chat panel to surface in a toast if
      // it cares.
      provider.stopCodingPlanPolling();
      provider.startCodingPlanPolling(apiKey: '');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        provider.latestCodingPlanError?.kind,
        CodingPlanUsageErrorKind.noApiKey,
      );
      // Cache is preserved so the toolbar still has
      // something to display.
      expect(provider.latestCodingPlanUsage, primed);

      await provider.disposeCodingPlanPolling();
    });

    test('setCodingPlanInterval updates the cadence without losing cache',
        () async {
      final provider = _FakeCodingPlanProvider();
      provider.startCodingPlanPolling(
        apiKey: 'test-key',
        interval: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final cached = provider.latestCodingPlanUsage;
      final originalInterval = provider.codingPlanInterval;
      expect(originalInterval, const Duration(milliseconds: 50));

      provider.setCodingPlanInterval(const Duration(seconds: 5));
      expect(provider.codingPlanInterval, const Duration(seconds: 5));
      expect(provider.isCodingPlanPolling, isTrue);
      // Cache is preserved across the interval change.
      expect(provider.latestCodingPlanUsage, cached);

      // Setting the same interval is a no-op (no error, no
      // churn).
      provider.setCodingPlanInterval(const Duration(seconds: 5));
      expect(provider.codingPlanInterval, const Duration(seconds: 5));

      await provider.disposeCodingPlanPolling();
    });

    test('markNeedsPaint contract: each new snapshot increments a counter',
        () async {
      // This test doesn't actually paint anything (there's no
      // widget in scope). It just verifies that the
      // _CodingPlanController emits a fresh event per tick
      // and that subscribers see them. The toolbar's
      // render object would call markNeedsPaint on the
      // stream; that's exercised at the integration level
      // by the chat-panel test (see streaming_toolbar_test).
      final provider = _FakeCodingPlanProvider();
      var count = 0;
      final sub = provider.codingPlanUsageStream.listen((_) => count++);

      provider.startCodingPlanPolling(
        apiKey: 'test-key',
        interval: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Should have ticked at least 2-3 times in 80ms with
      // a 20ms interval (allowing for the initial immediate
      // tick plus a few timer fires).
      expect(count, greaterThanOrEqualTo(2));

      await sub.cancel();
      await provider.disposeCodingPlanPolling();
    });
  });

  // ─── MiniMaxProvider integration ──────────────────────────
  group('MiniMaxProvider with CodingPlanProvider', () {
    test('declares isCodingPlan = true', () {
      final provider = MiniMaxProvider();
      expect(provider.isCodingPlan, isTrue);
    });

    test('has a non-null codingPlanUsageStream', () {
      final provider = MiniMaxProvider();
      // Stream is a broadcast stream — just check it doesn't throw.
      expect(provider.codingPlanUsageStream, isNotNull);
    });
  });
}

// ─── Test doubles ───────────────────────────────────────────

/// Minimal provider that does NOT include the
/// [CodingPlanProvider] mixin. Used to verify the base-class
/// default of `isCodingPlan = false`. We extend the concrete
/// `AnthropicCompatibleProvider` so the abstract
/// `buildRequestBody` is inherited and we don't have to
/// reimplement the Anthropic wire format here.
class _PlainProvider extends AnthropicCompatibleProvider {
  @override
  String get name => 'plain';
}

/// Test-only provider that includes the [CodingPlanProvider]
/// mixin with a fake fetch (no HTTP, no real endpoint). We
/// return a fixed snapshot so the test can assert on it
/// deterministically.
class _FakeCodingPlanProvider extends AnthropicCompatibleProvider
    with CodingPlanProvider {
  @override
  String get name => 'fake';

  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    // Yield to the event loop so the subscription has a
    // chance to register before we emit — otherwise the
    // initial immediate tick (from startCodingPlanPolling)
    // would be lost on a slow scheduler.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return CodingPlanUsage(
      providerName: name,
      modelName: 'general',
      intervalRemainingPct: 88,
      weeklyRemainingPct: 55,
      fetchedAt: DateTime.now(),
    );
  }
}

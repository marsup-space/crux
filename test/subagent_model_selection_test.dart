import 'dart:math';

import 'package:crux/src/services/subagent/subagent_manager.dart';
import 'package:test/test.dart';

void main() {
  group('pickWeighted', () {
    test(
      'excludes saturated or budget-exhausted entries represented by zero',
      () {
        const eligible = <String, int>{
          // Zero weights represent entries removed for saturation/budget.
          'codex/terra': 0,
          'budget-exhausted': 0,
          'kimi': 1,
          'zhipu/glm-5.3-flash': 1,
          'deepseek/v4-flash': 2,
        };
        final rng = Random(42);

        for (var i = 0; i < 1000; i++) {
          expect(pickWeighted(eligible, rng), isNot('codex/terra'));
        }
        expect(pickWeighted(const {}, rng), isNull);
        expect(pickWeighted(const {'saturated': 0}, rng), isNull);
      },
    );

    test('samples according to remaining-concurrency weights', () {
      const weights = <String, int>{
        'kimi': 1,
        'zhipu/glm-5.3-flash': 1,
        'deepseek/v4-flash': 2,
      };
      final counts = <String, int>{for (final model in weights.keys) model: 0};
      final rng = Random(20260312);
      const samples = 4000;

      for (var i = 0; i < samples; i++) {
        final model = pickWeighted(weights, rng)!;
        counts[model] = counts[model]! + 1;
      }

      // Expected shares are 25%, 25%, and 50%. A 5% absolute tolerance is
      // deliberately wider than normal sampling variance to avoid flakes.
      expect(counts['kimi']! / samples, closeTo(.25, .05));
      expect(counts['zhipu/glm-5.3-flash']! / samples, closeTo(.25, .05));
      expect(counts['deepseek/v4-flash']! / samples, closeTo(.50, .05));
    });
  });
}

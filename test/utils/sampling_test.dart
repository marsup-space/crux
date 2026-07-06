import 'package:test/test.dart';
import 'package:crux/src/utils/sampling.dart';

void main() {
  group('formatSamplingValue', () {
    test('whole numbers render without a decimal point', () {
      expect(formatSamplingValue(0), '0');
      expect(formatSamplingValue(1), '1');
    });

    test('trims trailing zeros after the decimal point', () {
      expect(formatSamplingValue(0.70), '0.7');
      expect(formatSamplingValue(1.00), '1');
      expect(formatSamplingValue(0.50), '0.5');
    });

    test('two-decimal precision is preserved when both decimals matter', () {
      expect(formatSamplingValue(0.55), '0.55');
      expect(formatSamplingValue(0.07), '0.07');
    });

    test('keeps the trailing zero after trimming other zeros', () {
      // 0.30 → "0.30" trims to "0.3", but should not strip the
      // lone significant zero that follows the decimal point.
      expect(formatSamplingValue(0.30), '0.3');
      expect(formatSamplingValue(0.05), '0.05');
    });

    test('does NOT clamp out-of-range values', () {
      // The chip surfaces the user's override verbatim. Clamping
      // here would silently rewrite "clamped from 1.5" to
      // "clamped from 1.0" in the toast. The formatter should be
      // a pure string conversion.
      expect(formatSamplingValue(1.5), '1.5');
      expect(formatSamplingValue(-0.2), '-0.2');
      expect(formatSamplingValue(2.0), '2');
    });

    test('rounds to two decimals via toStringAsFixed', () {
      expect(formatSamplingValue(0.123), '0.12');
      expect(formatSamplingValue(0.999), '1');
    });
  });

  group('topPForTemperature', () {
    test('endpoints match the user-specified mapping', () {
      expect(topPForTemperature(0.0), 1.0);
      expect(topPForTemperature(1.0), closeTo(0.85, 1e-9));
    });

    test('interpolates linearly in between', () {
      // 1.0 - 0.15 * 0.5 = 0.925
      expect(topPForTemperature(0.5), closeTo(0.925, 1e-9));
      // 1.0 - 0.15 * 0.7 = 0.895
      expect(topPForTemperature(0.7), closeTo(0.895, 1e-9));
    });

    test('always returns a value inside the API-valid [0.0, 1.0] window',
        () {
      for (final t in [-100.0, -1.0, 0.0, 0.5, 1.0, 2.0, 100.0]) {
        expect(topPForTemperature(t), inInclusiveRange(0.0, 1.0),
            reason: 'top_p at temp=$t must be in API window');
      }
    });

    test('is monotonically non-increasing in temperature', () {
      const samples = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0];
      double? previous;
      for (final t in samples) {
        final topP = topPForTemperature(t);
        final prev = previous;
        if (prev != null) {
          expect(topP, lessThanOrEqualTo(prev),
              reason: 'top_p must not widen as temperature rises');
        }
        previous = topP;
      }
    });
  });
}

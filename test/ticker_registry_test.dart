import 'package:crux/src/utils/ticker_registry.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('TickerRegistry', () {
    test('subscribe dispatches at the requested interval', () async {
      await testNocterm('ticker registry interval', (tester) async {
        TickerRegistry.instance.resetForTest();
        final calls = <int>[];
        TickerRegistry.instance.subscribe(
          name: 'test-a',
          interval: const Duration(milliseconds: 16),
          onTick: () => calls.add(1),
        );

        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(calls.length, 4);
      });
    });

    test('subscriber count tracks registrations', () async {
      await testNocterm('ticker registry count', (tester) async {
        TickerRegistry.instance.resetForTest();
        expect(TickerRegistry.instance.subscriberCount, 0);

        final t1 = TickerRegistry.instance.subscribe(
          name: 'a',
          interval: const Duration(milliseconds: 16),
          onTick: () {},
        );
        expect(TickerRegistry.instance.subscriberCount, 1);

        final t2 = TickerRegistry.instance.subscribe(
          name: 'b',
          interval: const Duration(milliseconds: 50),
          onTick: () {},
        );
        expect(TickerRegistry.instance.subscriberCount, 2);

        t1.cancel();
        expect(TickerRegistry.instance.subscriberCount, 1);

        t2.cancel();
        expect(TickerRegistry.instance.subscriberCount, 0);
      });
    });

    test('cancel stops further callbacks', () async {
      await testNocterm('ticker registry cancel', (tester) async {
        TickerRegistry.instance.resetForTest();
        final calls = <int>[];
        final token = TickerRegistry.instance.subscribe(
          name: 'test-cancel',
          interval: const Duration(milliseconds: 16),
          onTick: () => calls.add(1),
        );

        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final beforeCancel = calls.length;
        expect(beforeCancel, greaterThanOrEqualTo(1));

        token.cancel();
        expect(token.isActive, isFalse);

        await tester.pump(const Duration(milliseconds: 50));
        expect(calls.length, beforeCancel);
      });
    });

    test('cancel is idempotent', () async {
      await testNocterm('ticker registry cancel idempotent', (tester) async {
        TickerRegistry.instance.resetForTest();
        final token = TickerRegistry.instance.subscribe(
          name: 'test-idempotent',
          interval: const Duration(milliseconds: 16),
          onTick: () {},
        );
        token.cancel();
        token.cancel();
        token.cancel();
        expect(token.isActive, isFalse);
        expect(TickerRegistry.instance.subscriberCount, 0);
      });
    });

    test('pause stops delivery; resume restarts it', () async {
      await testNocterm('ticker registry pause', (tester) async {
        TickerRegistry.instance.resetForTest();
        final calls = <int>[];
        final token = TickerRegistry.instance.subscribe(
          name: 'test-pause',
          interval: const Duration(milliseconds: 16),
          onTick: () => calls.add(1),
        );

        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final beforePause = calls.length;
        expect(beforePause, greaterThanOrEqualTo(1));

        token.pause();
        await tester.pump(const Duration(milliseconds: 50));
        final duringPause = calls.length;
        expect(duringPause, beforePause);

        token.resume();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(calls.length, greaterThan(duringPause));

        token.cancel();
      });
    });

    test('intervals run on their requested cadence', () async {
      await testNocterm('ticker registry cadence', (tester) async {
        TickerRegistry.instance.resetForTest();
        var calls = 0;
        final token = TickerRegistry.instance.subscribe(
          name: 'test-cadence',
          interval: const Duration(milliseconds: 50),
          onTick: () => calls++,
        );

        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        token.cancel();

        expect(calls, 4);
      });
    });

    test('one scheduler frame serves multiple subscribers', () async {
      await testNocterm('ticker registry multiple', (tester) async {
        TickerRegistry.instance.resetForTest();
        int aCount = 0;
        int bCount = 0;
        int cCount = 0;

        TickerRegistry.instance.subscribe(
          name: 'multi-a',
          interval: const Duration(milliseconds: 16),
          onTick: () => aCount++,
        );
        TickerRegistry.instance.subscribe(
          name: 'multi-b',
          interval: const Duration(milliseconds: 50),
          onTick: () => bCount++,
        );
        TickerRegistry.instance.subscribe(
          name: 'multi-c',
          interval: const Duration(milliseconds: 500),
          onTick: () => cCount++,
        );

        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(aCount, 6);
        expect(bCount, greaterThanOrEqualTo(1));
        expect(bCount, lessThanOrEqualTo(2));
        expect(cCount, 0);
      });
    });

    test('a subscriber that cancels itself does not skip its siblings '
        '(regression: metrics display stopped updating when an earlier '
        'subscriber cancelled during onTick)', () async {
      await testNocterm('ticker registry self cancel', (tester) async {
        TickerRegistry.instance.resetForTest();
        int secondFired = 0;
        late final TickerToken selfCancelling;

        selfCancelling = TickerRegistry.instance.subscribe(
          name: 'self-cancelling',
          interval: const Duration(milliseconds: 16),
          onTick: () {
            selfCancelling.cancel();
          },
        );
        TickerRegistry.instance.subscribe(
          name: 'metrics-display',
          interval: const Duration(milliseconds: 16),
          onTick: () => secondFired++,
        );

        await tester.pump(const Duration(milliseconds: 16));

        expect(
          secondFired,
          greaterThan(0),
          reason:
              'Subscriber registered after a self-cancelling sibling '
              'must still receive ticks.',
        );
      });
    });
  });
}

import 'package:crux/src/components/turn_registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:test/test.dart';

void main() {
  group('TurnRegistry', () {
    test('tracks active turn identity and rejects stale ids', () {
      final registry = TurnRegistry();

      final first = registry.beginNormalTurn(1, 100);
      expect(first.kind, TurnKind.normal);
      expect(registry.isCurrent(1, 100), isTrue);
      expect(registry.isCurrent(1, 99), isFalse);

      registry.beginNormalTurn(1, 101);
      expect(registry.isCurrent(1, 100), isFalse);
      expect(registry.isCurrent(1, 101), isTrue);
    });

    test('beginning a new turn clears prior interruption state', () {
      final registry = TurnRegistry();

      registry.beginNormalTurn(1, 100);
      registry.markInterrupted(1);
      expect(registry.isInterrupted(1), isTrue);

      registry.beginNormalTurn(1, 101);
      expect(registry.isInterrupted(1), isFalse);
      expect(registry.isCurrent(1, 101), isTrue);
    });

    test('finishTurn only clears the matching active turn', () {
      final registry = TurnRegistry();

      registry.beginNormalTurn(1, 100);
      registry.finishTurn(1, 99);
      expect(registry.isCurrent(1, 100), isTrue);

      registry.finishTurn(1, 100);
      expect(registry.activeTurn(1), isNull);
    });

    test('abort signals are session scoped and drained once', () {
      final registry = TurnRegistry();
      final first = AbortSignal();
      final second = AbortSignal();

      registry.registerAbortSignal(1, first);
      registry.registerAbortSignal(1, second);

      expect(registry.takeAbortSignals(1), [first, second]);
      expect(registry.takeAbortSignals(1), isEmpty);
    });

    test('btw cancellation is consumed once', () {
      final registry = TurnRegistry();

      registry.beginBtwTurn(1, 200);
      registry.requestBtwCancel(1);

      expect(registry.consumeBtwCancel(1), isTrue);
      expect(registry.consumeBtwCancel(1), isFalse);
    });

    test('streaming guard transition flag is consumed once', () {
      final registry = TurnRegistry();

      registry.markStreamingGuardAborted(1);

      expect(registry.consumeStreamingGuardAborted(1), isTrue);
      expect(registry.consumeStreamingGuardAborted(1), isFalse);
    });

    test('clearSession removes every per-session marker', () {
      final registry = TurnRegistry();

      registry.beginNormalTurn(1, 100);
      registry.markInterrupted(1);
      registry.registerAbortSignal(1, AbortSignal());
      registry.requestBtwCancel(1);
      registry.markStreamingGuardAborted(1);

      registry.clearSession(1);

      expect(registry.activeTurn(1), isNull);
      expect(registry.isInterrupted(1), isFalse);
      expect(registry.takeAbortSignals(1), isEmpty);
      expect(registry.consumeBtwCancel(1), isFalse);
      expect(registry.consumeStreamingGuardAborted(1), isFalse);
    });
  });
}

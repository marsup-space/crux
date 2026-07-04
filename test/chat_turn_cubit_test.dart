import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/chat_turn_cubit.dart';
import 'package:crux/src/components/turn_registry.dart';
import 'package:test/test.dart';

void main() {
  group('ChatTurnCubit', () {
    blocTest<ChatTurnCubit, ChatTurnCubitState>(
      'tracks active turn lifecycle',
      build: ChatTurnCubit.new,
      act: (cubit) {
        cubit.beginTurn(
          sessionId: 1,
          turnId: 100,
          kind: TurnKind.normal,
          now: DateTime(2026),
        );
        cubit.beginModelRound(1, now: DateTime(2026, 1, 1, 0, 0, 1));
        cubit.finishModelRound(1);
        cubit.completeTurn(1, 100);
      },
      expect: () => [
        isA<ChatTurnCubitState>().having(
          (state) => state.sessionState(1).isResponding,
          'responding',
          isTrue,
        ),
        isA<ChatTurnCubitState>().having(
          (state) => state.sessionState(1).roundStreaming,
          'round streaming',
          isTrue,
        ),
        isA<ChatTurnCubitState>().having(
          (state) => state.sessionState(1).roundStreaming,
          'round streaming',
          isFalse,
        ),
        isA<ChatTurnCubitState>().having(
          (state) => state.sessionState(1).phase,
          'phase',
          ChatTurnPhase.idle,
        ),
      ],
    );

    test('stale completion does not clear a newer turn', () {
      final cubit = ChatTurnCubit();
      addTearDown(cubit.close);

      cubit.beginTurn(sessionId: 1, turnId: 100, kind: TurnKind.normal);
      cubit.beginTurn(sessionId: 1, turnId: 101, kind: TurnKind.normal);
      cubit.completeTurn(1, 100);

      expect(cubit.state.sessionState(1).turnId, 101);
      expect(cubit.state.sessionState(1).isResponding, isTrue);
    });

    test('interruptTurn records last interrupted outcome', () {
      final cubit = ChatTurnCubit();
      addTearDown(cubit.close);

      cubit.beginTurn(sessionId: 1, turnId: 100, kind: TurnKind.btw);
      cubit.interruptTurn(1);

      expect(cubit.state.sessionState(1).interrupted, isTrue);
      expect(cubit.state.sessionState(1).btwMode, isFalse);
    });
  });
}

import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/btw_cubit.dart';
import 'package:test/test.dart';

void main() {
  group('BtwCubit', () {
    blocTest<BtwCubit, BtwCubitState>(
      'chains pending turns per session and updates the last answer',
      build: BtwCubit.new,
      act: (cubit) {
        cubit.appendPendingTurn(1, 'first');
        cubit.updateLastAiText(1, 'answer');
        cubit.appendPendingTurn(2, 'other');
      },
      expect: () => [
        isA<BtwCubitState>().having(
          (state) => state.turnsFor(1).single.userText,
          'first user text',
          'first',
        ),
        isA<BtwCubitState>().having(
          (state) => state.turnsFor(1).single.aiText,
          'first answer',
          'answer',
        ),
        isA<BtwCubitState>()
            .having((state) => state.turnsFor(1), 'session 1', hasLength(1))
            .having((state) => state.turnsFor(2), 'session 2', hasLength(1)),
      ],
    );

    test('state snapshots are immutable', () {
      final cubit = BtwCubit();
      addTearDown(cubit.close);

      cubit.appendPendingTurn(1, 'question');

      expect(
        () => cubit.state
            .turnsFor(1)
            .add(const BtwTurn(userText: 'nope', aiText: '')),
        throwsUnsupportedError,
      );
    });

    test('clearTurnsFor keeps sessions isolated', () {
      final cubit = BtwCubit();
      addTearDown(cubit.close);

      cubit.appendPendingTurn(1, 'a');
      cubit.appendPendingTurn(2, 'b');
      cubit.clearTurnsFor(1);

      expect(cubit.state.turnsFor(1), isEmpty);
      expect(cubit.state.turnsFor(2).single.userText, 'b');
    });
  });
}

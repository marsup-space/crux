import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/compaction_cubit.dart';
import 'package:test/test.dart';

void main() {
  group('CompactionCubit', () {
    blocTest<CompactionCubit, CompactionCubitState>(
      'records compaction success and hysteresis window',
      build: CompactionCubit.new,
      act: (cubit) {
        cubit.beginCompaction(1);
        cubit.markCompactionSucceeded(
          sessionId: 1,
          preTokens: 120000,
          postEstimateTokens: 45000,
        );
      },
      expect: () => [
        isA<CompactionCubitState>().having(
          (state) => state.sessionState(1).isCompacting,
          'compacting',
          isTrue,
        ),
        isA<CompactionCubitState>()
            .having(
              (state) => state.sessionState(1).phase,
              'phase',
              CompactionPhase.idle,
            )
            .having(
              (state) => state.sessionState(1).turnsSinceLastCompact,
              'turns since compact',
              1,
            )
            .having(
              (state) => state.sessionState(1).lastPostEstimateTokens,
              'post estimate',
              45000,
            ),
      ],
    );

    test('advanceHysteresis resets after the third skipped turn', () {
      final cubit = CompactionCubit();
      addTearDown(cubit.close);

      cubit.markCompactionSucceeded(
        sessionId: 1,
        preTokens: 10,
        postEstimateTokens: 5,
      );
      cubit.advanceHysteresis(1);
      cubit.advanceHysteresis(1);
      expect(cubit.shouldSkipAutoCheck(1), isTrue);

      cubit.advanceHysteresis(1);
      expect(cubit.shouldSkipAutoCheck(1), isFalse);
      expect(cubit.state.sessionState(1).turnsSinceLastCompact, 0);
    });

    test('failures increment consecutive failure counter', () {
      final cubit = CompactionCubit();
      addTearDown(cubit.close);

      cubit.markCompactionFailed(1, 'boom');
      cubit.markCompactionFailed(1, 'again');

      expect(cubit.state.sessionState(1).phase, CompactionPhase.failed);
      expect(cubit.state.sessionState(1).consecutiveFailures, 2);
      expect(cubit.state.sessionState(1).lastError, 'again');
    });
  });
}

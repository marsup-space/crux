// Proves the BlocSelector<SessionCubit, SessionCubitState, String>
// pattern used by ChatToolbar._buildAuxiliaryModelButton only
// rebuilds when its selected field (auxiliaryModelShortName)
// actually changes. A different cubit mutation should NOT trigger
// a rebuild — that's the whole point of using a selector instead of
// a full BlocBuilder.

import 'package:crux/src/components/session_cubit.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import 'package:test/test.dart';

class _BuildCounter {
  var count = 0;
}

Component _buildConsumer(_BuildCounter counter, _BuildCounter otherCounter) {
  return BlocSelector<SessionCubit, SessionCubitState, String>(
    selector: (state) => state.auxiliaryModelShortName,
    builder: (context, auxShortName) {
      counter.count++;
      return Text('Aux: $auxShortName');
    },
  );
}

Component _buildUnrelated(_BuildCounter counter) {
  return BlocBuilder<SessionCubit, SessionCubitState>(
    builder: (context, state) {
      counter.count++;
      return Text('Sessions: ${state.sessions.length}');
    },
  );
}

void main() {
  test('BlocSelector rebuilds only when the selected field changes',
      () async {
    await testNocterm('selector scope', (tester) async {
      final cubit = SessionCubit();
      addTearDown(cubit.close);

      final selectorCounter = _BuildCounter();
      final unrelatedCounter = _BuildCounter();

      await tester.pumpComponent(
        BlocProvider<SessionCubit>.value(
          value: cubit,
          child: Column(
            children: [
              _buildConsumer(selectorCounter, unrelatedCounter),
              _buildUnrelated(unrelatedCounter),
            ],
          ),
        ),
      );

      final initialSelectorBuilds = selectorCounter.count;
      final initialUnrelatedBuilds = unrelatedCounter.count;

      // First pump produced the initial text on both builders.
      expect(selectorCounter.count, greaterThan(0));
      expect(unrelatedCounter.count, greaterThan(0));

      // Mutate an UNRELATED field. The selector should NOT rebuild;
      // the unrelated builder should.
      cubit.replaceSessions(
        sessions: [],
        archivedCount: 0,
        currentSessionId: null,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        selectorCounter.count,
        initialSelectorBuilds,
        reason: 'selector must not rebuild on unrelated field changes',
      );
      expect(
        unrelatedCounter.count,
        greaterThan(initialUnrelatedBuilds),
        reason: 'full BlocBuilder SHOULD rebuild on unrelated changes',
      );

      // Mutate the SELECTED field. The selector SHOULD rebuild now.
      cubit.setAuxiliaryModelShortName('MiniMax');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        selectorCounter.count,
        greaterThan(initialSelectorBuilds),
        reason: 'selector MUST rebuild when auxiliaryModelShortName changes',
      );
      expect(
        tester.terminalState,
        containsText('Aux: MiniMax'),
      );

      // Mutate the selected field to the SAME value. No rebuild.
      final beforeSameValue = selectorCounter.count;
      cubit.setAuxiliaryModelShortName('MiniMax');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        selectorCounter.count,
        beforeSameValue,
        reason: 'selector must skip rebuilds when value is unchanged',
      );
    });
  });
}

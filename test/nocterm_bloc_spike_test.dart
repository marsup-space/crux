import 'package:nocterm/nocterm.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import 'package:test/test.dart';

class SpikeCounterCubit extends Cubit<int> {
  SpikeCounterCubit() : super(0);

  void increment() => emit(state + 1);
}

class SpikeCounterView extends StatelessComponent {
  const SpikeCounterView();

  @override
  Component build(BuildContext context) {
    final cubit = context.read<SpikeCounterCubit>();
    return Column(
      children: [
        Text('Read: ${cubit.state}'),
        BlocBuilder<SpikeCounterCubit, int>(
          builder: (context, count) => Text('Count: $count'),
        ),
      ],
    );
  }
}

void main() {
  test('nocterm_bloc provider/read/builder work with local nocterm', () async {
    await testNocterm('nocterm bloc spike', (tester) async {
      final counter = SpikeCounterCubit();

      await tester.pumpComponent(
        BlocProvider.value(value: counter, child: const SpikeCounterView()),
      );

      expect(tester.terminalState, containsText('Count: 0'));

      counter.increment();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.terminalState, containsText('Count: 1'));
    });
  });
}

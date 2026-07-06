import 'package:crux/src/components/btw_bubble.dart';
import 'package:crux/src/components/streaming_cubit.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import 'package:test/test.dart';

/// Test harness that wires a [StreamingCubit] into a [BtwBubble.ai].
/// The real [BtwBubble] is stateless and takes its content directly;
/// this wrapper lets us verify that the bubble rebuilds when the cubit
/// emits new streaming content.
class _BtwStreamingBubble extends StatelessComponent {
  final StreamingCubit cubit;
  final int sessionId;

  const _BtwStreamingBubble(this.cubit, this.sessionId);

  @override
  Component build(BuildContext context) {
    return BlocBuilder<StreamingCubit, StreamingCubitState>(
      builder: (context, state) {
        final content = state.streamingContentFor(sessionId);
        return BtwBubble.ai(content: content, streaming: content.isEmpty);
      },
    );
  }
}

void main() {
  test('Btw bubble rebuilds from StreamingCubit', () async {
    await testNocterm('btw streaming bubble cubit rebuild', (tester) async {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);

      await tester.pumpComponent(
        Container(
          width: 80,
          height: 8,
          child: BlocProvider<StreamingCubit>.value(
            value: cubit,
            child: _BtwStreamingBubble(cubit, 1),
          ),
        ),
      );

      expect(tester.terminalState, containsText('btw ...'));

      cubit.appendStreamingContent(1, 'hello btw');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(tester.terminalState, containsText('hello btw'));
    });
  });
}

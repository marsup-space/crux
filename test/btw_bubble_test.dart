import 'package:crux/src/components/btw_bubble.dart';
import 'package:crux/src/components/streaming_cubit.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  test('BtwStreamingBubble rebuilds from StreamingCubit', () async {
    await testNocterm('btw streaming bubble cubit rebuild', (tester) async {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);

      await tester.pumpComponent(
        Container(
          width: 80,
          height: 8,
          child: BtwStreamingBubble(streamingCubit: cubit, sessionId: 1),
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

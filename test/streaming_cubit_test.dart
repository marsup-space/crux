import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/streaming_cubit.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:test/test.dart';

void main() {
  group('StreamingCubit', () {
    blocTest<StreamingCubit, StreamingCubitState>(
      'keeps content and reasoning isolated per session',
      build: StreamingCubit.new,
      act: (cubit) {
        cubit.appendStreamingContent(1, 'A');
        cubit.appendStreamingContent(2, 'B');
        cubit.appendStreamingReasoning(1, 'ra');
        cubit.appendStreamingReasoning(2, 'rb');
        cubit.appendStreamingContent(1, 'A2');
      },
      verify: (cubit) {
        expect(cubit.state.streamingContentFor(1), 'AA2');
        expect(cubit.state.streamingContentFor(2), 'B');
        expect(cubit.state.streamingReasoningFor(1), 'ra');
        expect(cubit.state.streamingReasoningFor(2), 'rb');
      },
    );

    test('waiting state is cleared by streaming deltas', () {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);
      final start = DateTime(2026, 1, 1, 12);

      cubit.beginWaitingForModel(1, now: start);
      expect(
        cubit.state.waitingForModelSeconds(
          1,
          now: start.add(const Duration(milliseconds: 1500)),
        ),
        1.5,
      );

      cubit.appendStreamingContent(1, 'hello');
      expect(cubit.state.waitingForModelSeconds(1), isNull);
      expect(cubit.state.streamingContentFor(1), 'hello');
    });

    test('tool-use chunks accumulate by index and preserve later ids', () {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);

      cubit.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: '',
          name: '',
          inputDelta: '{"filePath":"lib/a.dart"',
        ),
      );
      cubit.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: 'call_1',
          name: 'read',
          inputDelta: ',"limit":20}',
        ),
      );

      final calls = cubit.state.streamingToolCallsFor(1);
      expect(calls, hasLength(1));
      expect(calls.single.callId, 'call_1');
      expect(calls.single.name, 'read');
      expect(calls.single.accumulatedInputJson, contains('"limit":20'));
      expect(cubit.state.streamingToolInputTokensFor(1), greaterThan(0));
    });

    test('executing tools replace streaming buffers and can finish', () {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);
      final start = DateTime(2026, 1, 1, 12);

      cubit.appendStreamingContent(1, 'old');
      cubit.beginExecutingTools(1, const [
        ExecutingToolCall(
          callId: 'call_bash',
          name: 'bash',
          inputPreview: 'sleep 1',
        ),
      ], now: start);

      expect(cubit.state.streamingContentFor(1), isEmpty);
      expect(cubit.state.executingToolCallsFor(1).single.name, 'bash');
      expect(
        cubit.state.executingToolsSeconds(
          1,
          now: start.add(const Duration(seconds: 2)),
        ),
        2.0,
      );

      cubit.finishExecutingTools(1);
      expect(cubit.state.executingToolsSeconds(1), isNull);
      expect(cubit.state.executingToolCallsFor(1), isEmpty);
    });

    test('streaming guard abort annotates the matching tool call', () {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);

      cubit.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: 'call_1',
          name: 'bash',
          inputDelta: '{"cmd":"',
        ),
      );
      cubit.markStreamingToolCallAborted(
        1,
        index: 0,
        callId: 'call_1',
        name: 'bash',
        reason: 'too long',
        abortedInputTokensEstimate: 42,
      );

      expect(cubit.state.hasStreamingToolAbort(1), isTrue);
      expect(
        cubit.state.streamingToolCallsFor(1).single.abortInfo?.reason,
        'too long',
      );
    });

    test('clearStreamingFor only clears the targeted session', () {
      final cubit = StreamingCubit();
      addTearDown(cubit.close);

      cubit.appendStreamingContent(1, 'one');
      cubit.appendStreamingContent(2, 'two');
      cubit.beginWaitingForModel(2, now: DateTime(2026));

      cubit.clearStreamingFor(2);

      expect(cubit.state.streamingContentFor(1), 'one');
      expect(cubit.state.streamingContentFor(2), isEmpty);
      expect(cubit.state.waitingForModelSeconds(2), isNull);
    });

    blocTest<StreamingCubit, StreamingCubitState>(
      'toggles context bar hover flag',
      build: StreamingCubit.new,
      act: (cubit) {
        cubit.setContextBarHovered(true);
        cubit.setContextBarHovered(false);
      },
      expect: () => [
        isA<StreamingCubitState>().having(
          (state) => state.contextBarHovered,
          'hovered',
          isTrue,
        ),
        isA<StreamingCubitState>().having(
          (state) => state.contextBarHovered,
          'hovered',
          isFalse,
        ),
      ],
    );
  });
}

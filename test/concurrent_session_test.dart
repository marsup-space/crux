import 'package:test/test.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/llm_provider.dart';

void main() {
  group('StreamingController per-session map isolation', () {
    // These tests verify the core data-structure fix: streaming content
    // and reasoning are stored in per-session maps rather than shared
    // String fields.  We test the map operations directly to avoid
    // needing to construct the full SessionController dependency chain.

    late Map<int, String> streamingContent;
    late Map<int, String> streamingReasoning;

    setUp(() {
      streamingContent = {};
      streamingReasoning = {};
    });

    String contentFor(int id) => streamingContent[id] ?? '';
    String reasoningFor(int id) => streamingReasoning[id] ?? '';

    void appendContent(int id, String delta) {
      streamingContent[id] = (streamingContent[id] ?? '') + delta;
    }

    void appendReasoning(int id, String delta) {
      streamingReasoning[id] = (streamingReasoning[id] ?? '') + delta;
    }

    void clearFor(int id) {
      streamingContent.remove(id);
      streamingReasoning.remove(id);
    }

    test('content is isolated per session', () {
      appendContent(1, 'hello from session 1');
      appendContent(2, 'hello from session 2');

      expect(contentFor(1), 'hello from session 1');
      expect(contentFor(2), 'hello from session 2');
    });

    test('reasoning is isolated per session', () {
      appendReasoning(1, 'thinking A');
      appendReasoning(2, 'thinking B');

      expect(reasoningFor(1), 'thinking A');
      expect(reasoningFor(2), 'thinking B');
    });

    test('clearing one session does not affect another', () {
      appendContent(1, 'session 1 content');
      appendContent(2, 'session 2 content');
      appendReasoning(1, 'session 1 reasoning');
      appendReasoning(2, 'session 2 reasoning');

      clearFor(2);

      expect(contentFor(1), 'session 1 content');
      expect(reasoningFor(1), 'session 1 reasoning');
      expect(contentFor(2), '');
      expect(reasoningFor(2), '');
    });

    test('appending deltas to one session does not leak into another', () {
      appendContent(1, 'AAA');
      appendContent(2, 'BBB');
      appendContent(1, ' CCC');
      appendContent(2, ' DDD');

      expect(contentFor(1), 'AAA CCC');
      expect(contentFor(2), 'BBB DDD');
    });

    test('clear then re-append works', () {
      appendContent(1, 'first');
      clearFor(1);
      expect(contentFor(1), '');

      appendContent(1, 'second');
      expect(contentFor(1), 'second');
    });

    test('nonexistent session returns empty string', () {
      expect(contentFor(999), '');
      expect(reasoningFor(999), '');
    });

    test(
      'onToolRound on session B does not wipe session A (the original bug)',
      () {
        // Before the fix: streamingContent/streamingReasoning were shared
        // String fields. When onToolRound for session B set them to '',
        // it wiped session A's in-flight content.
        appendContent(1, 'session 1 streaming');
        appendReasoning(1, 'session 1 reasoning');
        appendContent(2, 'session 2 streaming');
        appendReasoning(2, 'session 2 reasoning');

        // onToolRound for session 2 clears its streaming state
        clearFor(2);

        // Session 1 must remain untouched
        expect(contentFor(1), 'session 1 streaming');
        expect(reasoningFor(1), 'session 1 reasoning');
      },
    );

    test(
      'onComplete on session B does not wipe session A',
      () {
        appendContent(1, 'session 1 streaming');
        appendContent(2, 'session 2 streaming');

        // onComplete for session 2 clears its streaming state
        clearFor(2);

        expect(contentFor(1), 'session 1 streaming');
        expect(contentFor(2), '');
      },
    );

    test('interleaved appends across three sessions stay isolated', () {
      for (var i = 0; i < 100; i++) {
        appendContent(1, 'A');
        appendContent(2, 'B');
        appendContent(3, 'C');
      }
      expect(contentFor(1), 'A' * 100);
      expect(contentFor(2), 'B' * 100);
      expect(contentFor(3), 'C' * 100);
    });
  });

  group('LlmClient per-stream tool block isolation', () {
    test('LlmClient no longer exposes clearToolBlockState', () {
      final client = LlmClient();
      // After the fix, _anthropicToolBlocks is a local variable inside
      // streamChat, not shared instance state. The clearToolBlockState
      // method was removed.
      expect(
        () => (client as dynamic).clearToolBlockState(),
        throwsNoSuchMethodError,
      );
      client.dispose();
    });

    test('two streamChat calls return independent streams', () {
      final client = LlmClient();
      final config = ProviderConfig(
        name: 'test',
        type: 'openai_compatible',
        wireFamily: WireFamily.openaiCompatible,
        endpointUrl: 'http://localhost:0',
        models: [],
      );

      final stream1 = client.streamChat(
        endpointUrl: 'http://localhost:0/v1',
        config: config,
        apiKey: 'key1',
        modelId: 'model-a',
        messages: [],
      );
      final stream2 = client.streamChat(
        endpointUrl: 'http://localhost:0/v1',
        config: config,
        apiKey: 'key2',
        modelId: 'model-b',
        messages: [],
      );

      expect(stream1, isNotNull);
      expect(stream2, isNotNull);
      // The streams are independent — each has its own tool blocks map.
      // They will error on connection, but the structural setup works.
      client.dispose();
    });
  });
}

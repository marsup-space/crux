import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/storage/storage.dart';

void main() {
  group('thinking signatures', () {
    test('parses Anthropic signature deltas', () {
      final chunk = contentBlockDeltaToChunk({
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'signed-thinking'},
      }, <int, ({String callId, String name})>{});

      expect(chunk?.reasoningSignatureDelta, 'signed-thinking');
    });

    test('replays signed thinking before a final assistant response', () {
      final messages = [
        Message(
          id: 1,
          sessionId: 1,
          role: 'ai',
          content: 'final answer',
          reasoningContent: 'private reasoning',
          reasoningSignature: 'signed-thinking',
        ),
      ];

      final wireMessages = ChatService.buildApiMessages(
        messages,
        WireFamily.anthropicCompatible,
      );
      final content = wireMessages.single['content'] as List<dynamic>;

      expect(content.first, {
        'type': 'thinking',
        'thinking': 'private reasoning',
        'signature': 'signed-thinking',
      });
      expect(content.last, {'type': 'text', 'text': 'final answer'});
    });

    test('replays signed thinking with tool calls and results', () {
      final messages = [
        Message(
          id: 1,
          sessionId: 1,
          role: 'tool_call',
          content: '',
          reasoningContent: 'need a tool',
          reasoningSignature: 'signed-tool-thinking',
          toolCalls: const [
            ToolCallData(
              callId: 'call_1',
              name: 'read',
              input: {'filePath': 'README.md'},
            ),
          ],
        ),
        Message(
          id: 2,
          sessionId: 1,
          role: 'tool',
          content: 'contents',
          toolCallId: 'call_1',
        ),
      ];

      final wireMessages = ChatService.buildApiMessages(
        messages,
        WireFamily.anthropicCompatible,
      );
      final assistantContent = wireMessages.first['content'] as List<dynamic>;
      final resultContent = wireMessages.last['content'] as List<dynamic>;

      expect(assistantContent.first['type'], 'thinking');
      expect(assistantContent.first['signature'], 'signed-tool-thinking');
      expect(assistantContent.last['type'], 'tool_use');
      expect(resultContent.single['type'], 'tool_result');
    });

    test('persists reasoning signatures', () async {
      final database = CruxDatabase.forTesting(NativeDatabase.memory());
      final store = SessionStore(database);
      addTearDown(database.close);

      final session = await store.create(title: 'test');
      await store.addMessage(
        session.id,
        role: 'ai',
        content: 'answer',
        reasoningContent: 'reasoning',
        reasoningSignature: 'persisted-signature',
      );

      final messages = await store.getMessages(session.id);
      expect(messages.single.reasoningSignature, 'persisted-signature');
    });
  });

  group('usage accounting', () {
    test('reads OpenAI cached tokens from prompt_tokens_details', () {
      final chunk = openAiUsageToChunk({
        'prompt_tokens': 1365,
        'completion_tokens': 239,
        'prompt_tokens_details': {'cached_tokens': 114},
      });

      expect(chunk.promptTokens, 1365);
      expect(chunk.promptCacheHitTokens, 114);
      expect(chunk.promptCacheMissTokens, 1251);
      expect(chunk.completionTokens, 239);
    });

    test('uses MiniMax final Anthropic input and cache counts', () {
      final usage = AnthropicUsageAccumulator()
        ..apply({
          'input_tokens': 0,
          'output_tokens': 0,
          'cache_creation_input_tokens': 0,
          'cache_read_input_tokens': 1365,
        })
        ..apply({
          'input_tokens': 1251,
          'output_tokens': 264,
          'cache_creation_input_tokens': 0,
          'cache_read_input_tokens': 114,
        }, isFinal: true);

      final chunk = usage.toChunk();
      expect(chunk.promptTokens, 1365);
      expect(chunk.promptCacheHitTokens, 114);
      expect(chunk.promptCacheMissTokens, 1251);
      expect(chunk.completionTokens, 264);
      expect(
        (chunk.promptCacheHitTokens! / chunk.promptTokens! * 100).round(),
        8,
      );
    });

    test('counts uncached Anthropic input as cache misses', () {
      final usage = AnthropicUsageAccumulator()
        ..apply({'input_tokens': 100, 'output_tokens': 20});

      final chunk = usage.toChunk();
      expect(chunk.promptTokens, 100);
      expect(chunk.promptCacheHitTokens, 0);
      expect(chunk.promptCacheMissTokens, 100);
    });

    test(
      'keeps an earlier positive cache count over a final placeholder zero',
      () {
        final usage = AnthropicUsageAccumulator()
          ..apply({'input_tokens': 20, 'cache_read_input_tokens': 100})
          ..apply({
            'output_tokens': 30,
            'cache_read_input_tokens': 0,
          }, isFinal: true);

        final chunk = usage.toChunk();
        expect(chunk.promptTokens, 120);
        expect(chunk.promptCacheHitTokens, 100);
        expect(chunk.promptCacheMissTokens, 20);
      },
    );
  });
}

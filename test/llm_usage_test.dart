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

    test('carries reasoning_content on assistant messages for the Responses '
        'API wire (DeepSeek pass-back requirement)', () {
      // Regression for the 400 "The reasoning_text in the thinking
      // mode must be passed back to the API." For WireFamily
      // .responsesApi the IR must keep the assistant's CoT so
      // DeepSeekProvider.buildRequestBody can emit `reasoning` input
      // items on tool-call rounds.
      final messages = [
        Message(
          id: 1,
          sessionId: 1,
          role: 'ai',
          content: 'final answer',
          reasoningContent: 'private reasoning',
        ),
        Message(
          id: 2,
          sessionId: 1,
          role: 'tool_call',
          content: '',
          reasoningContent: 'need a tool',
          toolCalls: const [
            ToolCallData(
              callId: 'call_1',
              name: 'read',
              input: {'filePath': 'README.md'},
            ),
          ],
        ),
        Message(
          id: 3,
          sessionId: 1,
          role: 'tool',
          content: 'contents',
          toolCallId: 'call_1',
        ),
      ];

      final wireMessages = ChatService.buildApiMessages(
        messages,
        WireFamily.responsesApi,
      );

      // Plain assistant turn keeps its reasoning.
      expect(wireMessages[0], {
        'role': 'assistant',
        'content': 'final answer',
        'reasoning_content': 'private reasoning',
      });
      // Tool-call assistant turn keeps its reasoning alongside tool_calls.
      final toolTurn = wireMessages[1];
      expect(toolTurn['role'], 'assistant');
      expect(toolTurn['reasoning_content'], 'need a tool');
      expect(toolTurn['tool_calls'], hasLength(1));
      // Tool result is a plain tool message, untouched.
      expect(wireMessages[2], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'contents',
      });
    });

    test('omits reasoning_content for the Responses API wire when the turn '
        'had no CoT', () {
      final wireMessages = ChatService.buildApiMessages([
        Message(id: 1, sessionId: 1, role: 'ai', content: 'plain answer'),
      ], WireFamily.responsesApi);
      expect(wireMessages.single, {
        'role': 'assistant',
        'content': 'plain answer',
      });
    });

    test('renders compaction summaries as user context', () {
      final wireMessages = ChatService.buildApiMessages([
        Message(
          id: 1,
          sessionId: 1,
          role: 'compaction',
          content: '## Goal\n- Continue the refactor.',
          meta: '{"status":"complete"}',
        ),
      ], WireFamily.openaiCompatible);

      expect(wireMessages.single['role'], 'user');
      // Clean markdown header — no XML wrapper, no "treat this as
      // the only context" prose preamble.
      expect(
        wireMessages.single['content'],
        contains('## Compacted history (from earlier in this session)'),
      );
      expect(wireMessages.single['content'], contains('Continue the refactor'));
    });

    test('only the LATEST compaction is emitted on the wire', () {
      // Two complete compactions in history. The latest's content
      // already chains the prior one (chain accumulation in
      // _buildCompactionPreview), so emitting both on the wire
      // would double-count the older section. The wire layer must
      // emit only the latest.
      final wireMessages = ChatService.buildApiMessages([
        Message(
          id: 1,
          sessionId: 1,
          role: 'compaction',
          content: 'compact #1 body',
          meta: '{"status":"complete"}',
        ),
        Message(
          id: 2,
          sessionId: 1,
          role: 'compaction',
          content: 'compact #1 body\n\n---\n\ncompact #2 delta',
          meta: '{"status":"complete"}',
        ),
      ], WireFamily.openaiCompatible);

      // Exactly one user-role compaction block.
      final compactionBlocks = wireMessages
          .where(
            (m) =>
                m['role'] == 'user' &&
                (m['content'] as String).startsWith('## Compacted history'),
          )
          .toList();
      expect(
        compactionBlocks,
        hasLength(1),
        reason: 'N compactions in storage → 1 block on wire',
      );

      // The emitted block is the latest (compact #2's chain).
      expect(compactionBlocks.single['content'], contains('compact #2 delta'));
      expect(compactionBlocks.single['content'], contains('compact #1 body'));
    });

    test('skips in-progress compaction placeholders in model context', () {
      final wireMessages = ChatService.buildApiMessages([
        Message(
          id: 1,
          sessionId: 1,
          role: 'compaction',
          content: 'Compacting context...',
          meta: '{"status":"compacting"}',
        ),
      ], WireFamily.openaiCompatible);

      expect(wireMessages, isEmpty);
    });

    test('persists reasoning signatures', () async {
      final database = CruxDatabase.forTesting(NativeDatabase.memory());
      final store = SessionStore(database);
      addTearDown(database.close);

      final session = await store.create(title: 'test');
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'answer',
        reasoningContent: 'reasoning',
        reasoningSignature: 'persisted-signature',
      );

      final messages = await store.messageStore.getMessages(session.id);
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

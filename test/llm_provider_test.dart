import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/install_slug.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/deepseek_provider.dart';
import 'package:crux/src/services/providers/minimax_provider.dart';
import 'package:crux/src/services/providers/openai_compatible_provider.dart';

void main() {
  // Minimal user/system messages used across the test cases.
  final userMsg = [
    {'role': 'user', 'content': 'hi'},
  ];
  final systemAndUser = [
    {'role': 'system', 'content': 'be brief'},
    {'role': 'user', 'content': 'hi'},
  ];

  group('AnthropicCompatibleProvider', () {
    final provider = AnthropicCompatibleProvider();

    group('thinking = enabled (default, with effort)', () {
      test('emits enabled + budget_tokens, plus output_config.effort', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'high'});
        expect(body['thinking']['budget_tokens'], isNotNull);
      });

      test('maps reasoning "normal" (Crux preset) to wire "medium"', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['output_config'], {'effort': 'medium'});
      });

      test('passes reasoning "max" through verbatim', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['output_config'], {'effort': 'max'});
      });

      test('uses provided thinkingBudget instead of the 10000 default', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 32000,
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 32000,
        });
      });
    });

    group('thinking = disabled', () {
      test('omits thinking and output_config fields entirely', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'high',
        );
        expect(body.containsKey('thinking'), isFalse);
        expect(body.containsKey('output_config'), isFalse);
      });
    });

    group('system message handling', () {
      test('promotes a system message to the top-level `system` array with cache_control', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          systemAndUser,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        final system = body['system'] as List;
        expect(system, hasLength(1));
        expect(system.first['type'], 'text');
        expect(system.first['text'], 'be brief');
        expect(system.first['cache_control'], {'type': 'ephemeral'});
        final chat = body['messages'] as List;
        expect(chat, hasLength(1));
        expect(chat.first['role'], 'user');
      });
    });

    group('prompt cache breakpoints', () {
      test('adds cache_control to the last tool definition', () {
        final tools = [
          {
            'name': 'read',
            'description': 'Read a file',
            'parameters': {'type': 'object'},
          },
          {
            'name': 'write',
            'description': 'Write a file',
            'parameters': {'type': 'object'},
          },
        ];
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          tools: tools,
        );
        final toolsList = body['tools'] as List;
        expect(toolsList, hasLength(2));
        expect(toolsList.first.containsKey('cache_control'), isFalse);
        expect(toolsList.last['cache_control'], {'type': 'ephemeral'});
      });

      test('adds cache_control to the last message content block (string)', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
        );
        final chat = body['messages'] as List;
        expect(chat, hasLength(1));
        final content = chat.first['content'] as List;
        expect(content, hasLength(1));
        expect(content.first['type'], 'text');
        expect(content.first['text'], 'hi');
        expect(content.first['cache_control'], {'type': 'ephemeral'});
      });

      test('adds cache_control to the last block of array content', () {
        final messages = [
          {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'},
              {'type': 'tool_result', 'tool_use_id': 't2', 'content': 'done'},
            ],
          },
        ];
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          messages,
          thinkingMode: 'enabled',
        );
        final chat = body['messages'] as List;
        final content = chat.first['content'] as List;
        expect(content, hasLength(2));
        expect(content.first.containsKey('cache_control'), isFalse);
        expect(content.last['cache_control'], {'type': 'ephemeral'});
      });

      test('does not mutate the original messages list', () {
        final original = [
          {'role': 'user', 'content': 'hi'},
        ];
        provider.buildRequestBody(
          'claude-sonnet-4-6',
          original,
          thinkingMode: 'enabled',
        );
        expect(original.first['content'], 'hi');
      });
    });

    group('mapEffort', () {
      test('renames Crux "normal" to wire "medium"', () {
        expect(provider.mapEffort('normal'), 'medium');
        expect(provider.mapEffort('medium'), 'medium');
      });

      test('passes low/high/max through verbatim', () {
        expect(provider.mapEffort('low'), 'low');
        expect(provider.mapEffort('high'), 'high');
        expect(provider.mapEffort('max'), 'max');
      });

      test('null and unknown values default to "medium"', () {
        expect(provider.mapEffort(null), 'medium');
        expect(provider.mapEffort(''), 'medium');
        expect(provider.mapEffort('extreme'), 'medium');
      });
    });

    test('ignores userId — not part of Anthropic wire format', () {
      final body = provider.buildRequestBody(
        'claude-sonnet-4-6',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-42',
      );
      expect(body.containsKey('user_id'), isFalse);
    });

    test('inherits base reasoningPresets (off, low, normal, high, max)', () {
      final presets = provider.reasoningPresetsFor('claude-sonnet-4-6');
      final low = presets.firstWhere((p) => p.internalValue == 'low');
      expect(low.displayLabel, 'low');
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'normal');
    });
  });

  group('OpenAICompatibleProvider', () {
    final provider = OpenAICompatibleProvider();

    test('reasoningPresets inherit from base (normal → normal, not adaptive)', () {
      final presets = provider.reasoningPresetsFor('deepseek-v4-pro');
      final low = presets.firstWhere((p) => p.internalValue == 'low');
      expect(low.displayLabel, 'low');
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'normal');
    });

    test('includes user_id in body when userId is provided', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-42',
      );
      expect(body['user_id'], 'abc123-42');
    });

    test('omits user_id when userId is null', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
      );
      expect(body.containsKey('user_id'), isFalse);
    });
  });

  group('DeepSeekProvider', () {
    final provider = DeepSeekProvider();

    test('reasoningPresets inherit from base (normal → normal, not adaptive)', () {
      final presets = provider.reasoningPresetsFor('deepseek-v4-pro');
      final low = presets.firstWhere((p) => p.internalValue == 'low');
      expect(low.displayLabel, 'low');
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'normal');
    });

    test('inherits user_id from OpenAICompatibleProvider', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-7',
      );
      expect(body['user_id'], 'abc123-7');
    });

    test('passes "high" through unchanged (DeepSeek accepts it as-is)', () {
      expect(provider.mapEffort('high'), 'high');
    });
  });

  group('OpenAICompatibleProvider.sanitizeMessages (tool_call ↔ tool pairing)', () {
    // The OpenAI Chat Completions protocol requires every tool_call
    // on an assistant message to be followed by a matching
    // role: 'tool' message (matched on tool_call_id). The sanitizer
    // on OpenAICompatibleProvider repairs orphan tool_calls —
    // typically caused by switching the session model from a
    // provider using the Anthropic wire family to one using the
    // OpenAI wire family mid-conversation, or by a mid-round
    // interruption that left a tool_call row without its results.
    final provider = OpenAICompatibleProvider();

    Map<String, dynamic> toolCall(String id) => {
          'id': id,
          'type': 'function',
          'function': {'name': 'x', 'arguments': '{}'},
        };

    test('returns the original list reference when pairing is already valid', () {
      // The well-formed fast path: a complete assistant→tool chain
      // returns the same list reference, no allocation.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [toolCall('call_a'), toolCall('call_b')],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
        {'role': 'tool', 'tool_call_id': 'call_b', 'content': 'r2'},
        {'role': 'assistant', 'content': 'done'},
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('drops orphan tool_calls from an assistant message whose tool '
        'results were never persisted (mid-round interrupt)', () {
      // Regression: a tool_call row was persisted but the round was
      // interrupted before the addToolRound transaction wrote the
      // tool result rows. The next request sees a dangling
      // tool_calls array. OpenAI rejects this with a 400.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': 'I will call a tool',
          'tool_calls': [toolCall('call_a')],
        },
        {'role': 'user', 'content': 'try again'},
      ];
      final out = provider.sanitizeMessages(messages);
      // The text content is preserved; tool_calls is removed (no
      // surviving entries).
      expect(out, hasLength(3));
      expect(out[1]['role'], 'assistant');
      expect(out[1]['content'], 'I will call a tool');
      expect(out[1].containsKey('tool_calls'), isFalse);
    });

    test('drops only the orphan entries when some tool_calls have responses '
        'and others do not', () {
      // Mid-round interrupt in the middle of a multi-call round: A
      // got a response, B did not. Keep A's response, drop B from
      // the assistant's tool_calls, and let the user message that
      // interrupted the round stand on its own.
      final messages = [
        {'role': 'user', 'content': 'do both'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [toolCall('call_a'), toolCall('call_b')],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
        {'role': 'user', 'content': 'actually just give me the first result'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(4));
      expect(out[1]['tool_calls'], hasLength(1));
      expect(out[1]['tool_calls'][0]['id'], 'call_a',
          reason: 'only call_a should survive');
      // call_a's tool response is preserved.
      expect(out[2]['tool_call_id'], 'call_a');
      // The interrupting user message is preserved.
      expect(out[3]['content'], 'actually just give me the first result');
    });

    test('drops orphan tool messages that have no preceding assistant '
        'tool_call with a matching id', () {
      // A tool message landed in the history without a matching
      // tool_call — e.g. an external write or a corrupted round.
      // OpenAI rejects tool messages that don't follow a matching
      // assistant tool_call.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {'role': 'tool', 'tool_call_id': 'call_x', 'content': 'r'},
        {'role': 'user', 'content': 'do something else'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(2));
      expect(out[0]['content'], 'do it');
      expect(out[1]['content'], 'do something else');
    });

    test('drops tool messages with a null tool_call_id', () {
      // Malformed tool row — has the role but no call id. There's
      // no way to associate it with an assistant tool_call, so
      // it's always orphan.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {'role': 'tool', 'content': 'orphan result'},
        {'role': 'user', 'content': 'next'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(2));
      expect(out.where((m) => m['role'] == 'tool'), isEmpty);
    });

    test('preserves well-formed tool flow even with intervening system '
        'messages', () {
      // System messages don't terminate a tool flow — only user
      // and tool_call-free assistant messages do. (The OpenAI spec
      // allows system messages to appear anywhere; in Crux they're
      // hoisted to a separate `system` field by buildRequestBody,
      // so the only system messages in the messages list are
      // legitimate interleavings.)
      final messages = [
        {'role': 'system', 'content': 'be brief'},
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [toolCall('call_a')],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('does not mutate the original message maps', () {
      // The sanitizer must produce new map instances for any row
      // it modifies, so callers that hold references to the
      // pre-sanitize maps don't see surprise mutations across
      // requests.
      final originalAssistant = {
        'role': 'assistant',
        'content': 'text',
        'tool_calls': [toolCall('call_a'), toolCall('call_b')],
      };
      final messages = [
        {'role': 'user', 'content': 'do it'},
        originalAssistant,
        // No tool responses — both tool_calls are orphan.
      ];
      final out = provider.sanitizeMessages(messages);
      expect(identical(out[1], originalAssistant), isFalse,
          reason: 'modified rows must be a fresh map');
      expect(originalAssistant['tool_calls'], hasLength(2),
          reason: 'original must not be mutated in place');
    });
  });

  group('LlmProvider.sanitizeMessages (default no-op)', () {
    test('returns the original list reference when no modifications are made',
        () {
      // The default implementation must be a true no-op so the
      // common case (provider that doesn't need sanitization)
      // allocates nothing when LlmClient invokes the hook per
      // request.
      final p = OpenAICompatibleProvider();
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
      ];
      expect(identical(p.sanitizeMessages(messages), messages), isTrue);
    });
  });

  group('DeepSeekProvider.sanitizeMessages', () {
    final provider = DeepSeekProvider();

    test('returns the original list reference when no assistant messages '
        'need backfilling', () {
      // All assistant messages already carry a reasoning_content
      // field (e.g. the conversation was started under DeepSeek),
      // so the sanitizer should be a true no-op — same list
      // reference, no allocation.
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': 'hello',
          'reasoning_content': 'the user said hi, I will greet them',
        },
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('backfills reasoning_content: "" on assistant messages that lack '
        'the field', () {
      // Regression for the "reasoning context must be passed back"
      // 400 from DeepSeek when switching the session model
      // mid-conversation from a non-DeepSeek provider.
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'}, // M3-produced
        {'role': 'user', 'content': 'how are you?'},
        {
          'role': 'assistant',
          'content': 'good',
          // already backfilled, must be left alone
          'reasoning_content': 'I was asked how I am',
        },
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(4));
      expect(out[0]['reasoning_content'], isNull,
          reason: 'user messages are not touched');
      expect(out[1]['role'], 'assistant');
      expect(out[1]['content'], 'hello');
      expect(out[1]['reasoning_content'], '',
          reason: 'missing field is backfilled with empty string');
      expect(out[2]['reasoning_content'], isNull,
          reason: 'user messages are not touched');
      expect(out[2]['content'], 'how are you?');
      expect(out[3]['reasoning_content'], 'I was asked how I am',
          reason: 'pre-existing value is preserved');
    });

    test('treats explicit null the same as a missing key', () {
      // `m['reasoning_content'] == null` covers both the
      // "key absent" case (Dart returns null for missing keys)
      // and the "key present with null value" case. Both should
      // be backfilled — otherwise a future refactor that
      // explicitly nulls the field would silently regress this
      // fix.
      final messages = [
        {
          'role': 'assistant',
          'content': 'hello',
          'reasoning_content': null,
        },
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out.single['reasoning_content'], '');
    });

    test('preserves tool_calls on assistant messages that get backfilled',
        () {
      // The wire-format emitter for `tool_call`-role history
      // messages produces a map with `role`, `content`, and
      // `tool_calls` (OpenAI shape) — no `reasoning_content`.
      // Sanitizing must not drop the `tool_calls` array. This
      // matters most for DeepSeek's tool-call turns, which is
      // exactly the case the docs say is the strictest about
      // reasoning_content being present.
      final messages = [
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'read',
                'arguments': '{"path": "/tmp/a"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': 'file contents',
        },
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out[0]['reasoning_content'], '');
      expect(out[0]['tool_calls'], hasLength(1));
      expect(out[0]['tool_calls'][0]['id'], 'call_1');
      expect(out[1]['reasoning_content'], isNull,
          reason: 'tool messages are not assistant messages');
    });

    test('does not mutate the original message maps', () {
      // Sanitizer must produce new map instances for the rows it
      // modifies, otherwise downstream callers (e.g. cache-key
      // computation, log diffing) that hold a reference to the
      // pre-sanitize map would see surprising mutations across
      // requests.
      final originalAssistant = {'role': 'assistant', 'content': 'hello'};
      final messages = [
        {'role': 'user', 'content': 'hi'},
        originalAssistant,
      ];
      final out = provider.sanitizeMessages(messages);
      expect(identical(out[1], originalAssistant), isFalse,
          reason: 'modified rows must be a fresh map');
      expect(originalAssistant.containsKey('reasoning_content'), isFalse,
          reason: 'original map must not be mutated in place');
    });

    test('composes the inherited pairing fix with the reasoning_content '
        'backfill (full M3→DeepSeek switch)', () {
      // Real-world scenario the user reported: a session was started
      // under MiniMax (Anthropic wire), executed a tool round, and
      // the user then switched the active model to DeepSeek
      // (OpenAI-compatible wire). The history Crux serializes for
      // DeepSeek looks like:
      //   - user
      //   - assistant {tool_calls: [A, B], content: null}  ← no
      //     reasoning_content (Anthropic wire used a thinking
      //     content block, not this field)
      //   - tool {tool_call_id: A}                        ← no
      //     tool response for B (B's tool was interrupted or
      //     the round aborted before its result was written)
      //   - user
      //
      // Two things must be repaired before the request is valid:
      //   1. The orphan `call_b` must be dropped from the
      //      assistant's `tool_calls` (OpenAI protocol requires
      //      every tool_call to be responded to immediately).
      //   2. `reasoning_content: ''` must be backfilled on every
      //      assistant message (DeepSeek protocol requirement
      //      when in thinking mode and a prior turn had tool
      //      calls).
      //
      // The DeepSeek sanitizer runs both — pairing via the
      // inherited OpenAICompatibleProvider implementation, then
      // backfill on the result.
      final messages = [
        {'role': 'user', 'content': 'do both'},
        {
          'role': 'assistant',
          'content': 'calling both tools',
          'tool_calls': [
            {
              'id': 'call_a',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{"p":"/a"}'},
            },
            {
              'id': 'call_b',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{"p":"/b"}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'contents of a'},
        {'role': 'user', 'content': 'just give me a for now'},
      ];
      final out = provider.sanitizeMessages(messages);
      // 4 messages: user, repaired-assistant, tool A, user.
      expect(out, hasLength(4));
      // The assistant's tool_calls is now just [A]; B is gone.
      final assistant = out[1];
      expect(assistant['tool_calls'], hasLength(1));
      expect(assistant['tool_calls'][0]['id'], 'call_a');
      // The text content is preserved.
      expect(assistant['content'], 'calling both tools');
      // And — crucially — reasoning_content has been backfilled
      // on this repaired row, matching what a DeepSeek-produced
      // assistant message would look like.
      expect(assistant['reasoning_content'], '',
          reason: 'DeepSeek-specific backfill runs after the inherited pairing fix');
      // call_a's tool response is preserved verbatim.
      expect(out[2]['tool_call_id'], 'call_a');
      expect(out[2]['content'], 'contents of a');
      // The interrupting user message is preserved.
      expect(out[3]['content'], 'just give me a for now');
    });
  });

  group('MiniMaxProvider', () {
    final provider = MiniMaxProvider();

    group('M3 model — adaptive thinking, can disable', () {
      test('normal effort emits thinking: {type: adaptive} with no budget_tokens',
          () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['thinking'], {'type': 'adaptive'});
        // AI SDK unit test contract: budget_tokens is intentionally
        // absent for adaptive thinking.
        expect(body['thinking'].containsKey('budget_tokens'), isFalse);
        expect(body['output_config'], {'effort': 'medium'});
      });

      test('low effort emits thinking: {type: enabled} with budget_tokens',
          () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'low',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'low'});
      });

      test('high effort emits thinking: {type: enabled} with budget_tokens', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'high'});
      });

      test('max effort emits thinking: {type: enabled} with budget_tokens', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'max'});
      });

      test('thinking = disabled omits the thinking and output_config fields',
          () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'high',
        );
        expect(body.containsKey('thinking'), isFalse);
        expect(body.containsKey('output_config'), isFalse);
      });

      test('uses provided thinkingBudget instead of the 10000 default', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 8000,
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 8000,
        });
      });

      test('reuses the base mapEffort — single source of truth for the mapping',
          () {
        // Sanity: M3's wire-shape behavior should be driven by the
        // shared helper, not a duplicated switch. We invoke both
        // implementations and assert they agree on the full preset grid.
        final base = AnthropicCompatibleProvider();
        for (final effort in ['low', 'normal', 'medium', 'high', 'max', null]) {
          final body = provider.buildRequestBody(
            'MiniMax-M3',
            userMsg,
            thinkingMode: 'enabled',
            reasoningEffort: effort,
          );
          final expected = base.mapEffort(effort);
          // All efforts always produce output_config.effort.
          expect(
            body['output_config'],
            {'effort': expected},
            reason: 'effort=$effort should map to wire $expected',
          );
          // normal → adaptive, others → enabled + budget.
          if (effort == 'normal') {
            expect(
              body['thinking'],
              {'type': 'adaptive'},
              reason: 'effort=normal should use adaptive thinking',
            );
          } else {
            expect(
              body['thinking']['type'],
              'enabled',
              reason: 'effort=$effort should use enabled thinking',
            );
          }
        }
      });
    });

    group('M2.x model — thinking always on, no adaptive, cannot disable', () {
      test('normal effort emits thinking: {type: enabled} (NOT adaptive)',
          () {
        // M2.x has no adaptive mode — the model would reject or
        // ignore `{type: "adaptive"}`. Fall back to enabled +
        // budget, like the other budget-driven presets.
        final body = provider.buildRequestBody(
          'MiniMax-M2.7',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'medium'});
      });

      test('high effort emits thinking: {type: enabled} with budget_tokens',
          () {
        final body = provider.buildRequestBody(
          'MiniMax-M2.5',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'high'});
      });

      test('max effort emits thinking: {type: enabled} with budget_tokens',
          () {
        final body = provider.buildRequestBody(
          'MiniMax-M2',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'max'});
      });

      test('thinking = disabled is IGNORED — M2.x always emits enabled', () {
        // Per the MiniMax docs: "对于 M2.x 模型，thinking 无法关闭；
        // 即使传入 `thinking: {type: 'disabled'}`，thinking 仍会保持
        // 开启." We must not honour the user's off toggle for M2.x.
        final body = provider.buildRequestBody(
          'MiniMax-M2.7',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 10000,
        });
        expect(body['output_config'], {'effort': 'high'});
      });

      test('uses provided thinkingBudget for M2.x', () {
        final body = provider.buildRequestBody(
          'MiniMax-M2.1-highspeed',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 8000,
        );
        expect(body['thinking'], {
          'type': 'enabled',
          'budget_tokens': 8000,
        });
      });
    });

    test('uses bearer auth (vs the base class\'s anthropicApiKey)', () {
      expect(provider.authStyle, AuthStyle.bearer);
    });

    test('inherits cache_control on system, tools, and messages', () {
      final tools = [
        {
          'name': 'bash',
          'description': 'Run a command',
          'parameters': {'type': 'object'},
        },
      ];
      final body = provider.buildRequestBody(
        'MiniMax-M3',
        systemAndUser,
        thinkingMode: 'enabled',
        reasoningEffort: 'high',
        tools: tools,
      );
      // System: array with cache_control on last block
      final system = body['system'] as List;
      expect(system.last['cache_control'], {'type': 'ephemeral'});
      // Tools: cache_control on last tool
      final toolsList = body['tools'] as List;
      expect(toolsList.last['cache_control'], {'type': 'ephemeral'});
      // Messages: cache_control on last content block
      final chat = body['messages'] as List;
      final content = chat.last['content'] as List;
      expect(content.last['cache_control'], {'type': 'ephemeral'});
    });

    test('reasoningPresetsFor M3 maps normal → adaptive, others stay identity',
        () {
      // Adaptive is an M3-only feature. The UI shows the
      // `adaptive` label (renamed from `normal`) only when the
      // active model is M3. The labels come from minimax.toml's
      // [models.reasoning_labels] — not hardcoded.
      const m3ModelLabels = {
        'low': 'disabled',
        'normal': 'adaptive',
        'high': 'disabled',
        'max': 'disabled',
      };
      final presets = provider.reasoningPresetsFor(
        'MiniMax-M3',
        modelLabels: m3ModelLabels,
      );
      // low/high/max are disabled — only normal (as "adaptive") and off remain.
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'adaptive');
      // Disabled entries are removed from the list.
      expect(presets.where((p) => p.internalValue == 'low'), isEmpty);
      expect(presets.where((p) => p.internalValue == 'high'), isEmpty);
      expect(presets.where((p) => p.internalValue == 'max'), isEmpty);
    });

    test('reasoningPresetsFor M2.x shows normal → normal (no adaptive label)',
        () {
      // M2.x doesn't support adaptive thinking, so the rename
      // would be misleading. Show `normal` as `normal` and let
      // the wire format (enabled + budget) do the work.
      for (final modelId in [
        'MiniMax-M2',
        'MiniMax-M2.1',
        'MiniMax-M2.1-highspeed',
        'MiniMax-M2.5',
        'MiniMax-M2.5-highspeed',
        'MiniMax-M2.7',
        'MiniMax-M2.7-highspeed',
      ]) {
        final presets = provider.reasoningPresetsFor(modelId);
        final low = presets.firstWhere((p) => p.internalValue == 'low');
        expect(
          low.displayLabel,
          'low',
          reason: '$modelId: low should be identity',
        );
        final normal = presets.firstWhere((p) => p.internalValue == 'normal');
        expect(
          normal.displayLabel,
          'normal',
          reason: '$modelId: normal should NOT be relabeled "adaptive"',
        );
        final high = presets.firstWhere((p) => p.internalValue == 'high');
        expect(
          high.displayLabel,
          'high',
          reason: '$modelId: high should be identity',
        );
        final max = presets.firstWhere((p) => p.internalValue == 'max');
        expect(
          max.displayLabel,
          'max',
          reason: '$modelId: max should be identity',
        );
      }
    });
  });

  group('InstallSlug', () {
    test('produces a non-empty slug matching DeepSeek user_id regex', () {
      final slug = InstallSlug.slug;
      expect(slug, isNotEmpty);
      expect(RegExp(r'^[a-zA-Z0-9\-_]+$').hasMatch(slug), isTrue);
      expect(slug.length, 12);
    });
  });
}
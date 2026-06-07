import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/llm_provider.dart';
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
        userId: 'crux-session-42',
      );
      expect(body.containsKey('user_id'), isFalse);
    });
  });

  group('OpenAICompatibleProvider', () {
    final provider = OpenAICompatibleProvider();

    test('includes user_id in body when userId is provided', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'crux-session-42',
      );
      expect(body['user_id'], 'crux-session-42');
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

    test('inherits user_id from OpenAICompatibleProvider', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'crux-session-7',
      );
      expect(body['user_id'], 'crux-session-7');
    });

    test('maps effort "high" to wire "xhigh"', () {
      expect(provider.mapEffort('high'), 'xhigh');
    });
  });

  group('MiniMaxProvider (adaptive thinking quirk)', () {
    final provider = MiniMaxProvider();

    test('emits thinking: {type: adaptive} with no budget_tokens', () {
      final body = provider.buildRequestBody(
        'MiniMax-M3',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'high',
      );
      expect(body['thinking'], {'type': 'adaptive'});
      // AI SDK unit test contract: budget_tokens is intentionally absent
      // for adaptive thinking.
      expect(body['thinking'].containsKey('budget_tokens'), isFalse);
    });

    test('emits output_config.effort for the active preset', () {
      final body = provider.buildRequestBody(
        'MiniMax-M3',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'normal',
      );
      expect(body['output_config'], {'effort': 'medium'});
    });

    test('passes "high" and "max" through verbatim', () {
      final high = provider.buildRequestBody(
        'MiniMax-M3',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'high',
      );
      expect(high['output_config'], {'effort': 'high'});

      final max = provider.buildRequestBody(
        'MiniMax-M3',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
      );
      expect(max['output_config'], {'effort': 'max'});
    });

    test('thinking = disabled omits the thinking and output_config fields', () {
      final body = provider.buildRequestBody(
        'MiniMax-M3',
        userMsg,
        thinkingMode: 'disabled',
        reasoningEffort: 'high',
      );
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('output_config'), isFalse);
    });

    test('falls back to enabled + budget_tokens when thinkingBudget is set',
        () {
      // The MiniMax model line currently advertises adaptive thinking, but
      // a future non-adaptive model can opt into the legacy shape by
      // passing a non-null thinkingBudget. Verify the fallback works.
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

    test('uses bearer auth (vs the base class\'s anthropicApiKey)', () {
      expect(provider.authStyle, AuthStyle.bearer);
    });

    test('reuses the base mapEffort — single source of truth for the mapping',
        () {
      // Sanity: MiniMax's wire-shape behavior should be driven by the
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
        expect(
          body['output_config'],
          {'effort': expected},
          reason: 'effort=$effort should map to wire $expected',
        );
      }
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
  });
}

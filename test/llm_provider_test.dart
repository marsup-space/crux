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

    test('maps effort "high" to wire "xhigh"', () {
      expect(provider.mapEffort('high'), 'xhigh');
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
      // active model is M3.
      final presets = provider.reasoningPresetsFor('MiniMax-M3');
      final low = presets.firstWhere((p) => p.internalValue == 'low');
      expect(low.displayLabel, 'low');
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'adaptive');
      final high = presets.firstWhere((p) => p.internalValue == 'high');
      expect(high.displayLabel, 'high');
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
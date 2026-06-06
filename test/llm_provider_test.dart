import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/services/providers/minimax_provider.dart';

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
      test('promotes a system message to the top-level `system` field', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          systemAndUser,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['system'], 'be brief');
        final chat = body['messages'] as List;
        expect(chat, hasLength(1));
        expect(chat.first['role'], 'user');
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
  });
}

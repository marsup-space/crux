import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/providers/credit_balance_provider.dart';
import 'package:crux/src/services/providers/mimo_provider.dart';
import 'package:crux/src/services/llm_provider.dart';

void main() {
  final userMsg = [
    {'role': 'user', 'content': 'hi'},
  ];

  group('MimoProvider', () {
    final provider = MimoProvider();

    test('registers as "mimo" with OpenAI-compatible wire and bearer auth', () {
      final resolved = resolveProvider('mimo');
      expect(resolved.provider, isA<MimoProvider>());
      expect(resolved.wire, WireFamily.openaiCompatible);
      expect(resolved.authStyle, AuthStyle.bearer);
    });

    test('appears in knownProviderTypes and typeDisplayName', () {
      expect(knownProviderTypes(), contains('mimo'));
      expect(typeDisplayName('mimo'), 'MiMo');
    });

    test('removes reasoning_effort from the wire body', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
      );
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('emits thinking.type enabled when thinking is on', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
      );
      expect(body['thinking'], {'type': 'enabled'});
    });

    test('emits thinking.type disabled when thinking is off', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'disabled',
        reasoningEffort: 'max',
      );
      expect(body['thinking'], {'type': 'disabled'});
      // No reasoning_effort even in this branch.
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    group('temperature / top_p pinning', () {
      test('thinking enabled: pins temp=1.0 and top_p=0.95 regardless of caller', () {
        for (final callerTemp in const [0.0, 0.5, 0.7, 1.0]) {
          for (final callerTopP in const [0.85, 0.9, 0.95, 1.0]) {
            final body = provider.buildRequestBody(
              'mimo-v2.5-pro',
              userMsg,
              thinkingMode: 'enabled',
              temperature: callerTemp,
              topP: callerTopP,
            );
            expect(
              body['temperature'],
              1.0,
              reason: 'caller temp $callerTemp should be replaced',
            );
            expect(
              body['top_p'],
              0.95,
              reason: 'caller top_p $callerTopP should be replaced',
            );
          }
        }
      });

      test('thinking disabled: honors caller temperature and top_p', () {
        final body = provider.buildRequestBody(
          'mimo-v2.5-pro',
          userMsg,
          thinkingMode: 'disabled',
          temperature: 0.2,
          topP: 0.9,
        );
        expect(body['temperature'], 0.2);
        expect(body['top_p'], 0.9);
      });
    });

    test('forcedTemperature is pinned at 1.0', () {
      // The toolbar renders a fixed "T:1" chip because MiMo's
      // thinking-enabled models ignore any custom temperature.
      expect(provider.forcedTemperature, 1.0);
    });

    test('passes model id and messages through unchanged', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
      );
      expect(body['model'], 'mimo-v2.5-pro');
      expect(body['messages'], userMsg);
    });

    test('inherits OpenAI-compatible tool and stream shape', () {
      final tools = [
        {
          'name': 'read',
          'description': 'Read a file',
          'parameters': {'type': 'object'},
        },
      ];
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
        tools: tools,
        maxTokens: 4096,
      );
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
      expect(body['max_completion_tokens'], 4096);
      final bodyTools = body['tools'] as List;
      expect(bodyTools, hasLength(1));
      expect(bodyTools.first['type'], 'function');
      expect(bodyTools.first['function']['name'], 'read');
    });

    test('omits user_id when not provided', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
      );
      expect(body.containsKey('user_id'), isFalse);
    });

    test('includes user_id when provided', () {
      final body = provider.buildRequestBody(
        'mimo-v2.5-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'user-42',
      );
      expect(body['user_id'], 'user-42');
    });

    test('does not expose a credit-balance surface (no key-auth API)', () {
      // MiMo's inference API has no balance endpoint; the provider
      // must not claim one or the toolbar would poll a 404. See
      // the class doc for the verification trail.
      expect(provider.isCreditBalance, isFalse);
      expect(provider, isNot(isA<CreditBalanceProvider>()));
    });
  });
}

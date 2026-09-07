import 'dart:convert';

import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/services/codex_oauth.dart';
import 'package:crux/src/services/providers/codex_provider.dart';
import 'package:test/test.dart';

void main() {
  group('CodexProvider', () {
    final provider = CodexProvider();

    test('migrates retired ChatGPT Codex aliases to GPT-5.6 Sol', () {
      expect(provider.canonicalModelId('gpt-5.5-codex'), 'gpt-5.6-sol');
      expect(provider.canonicalModelId('gpt-5.6-codex'), 'gpt-5.6-sol');
      expect(provider.canonicalModelId('gpt-5.6-terra'), 'gpt-5.6-terra');
    });

    test('exposes subscription usage but not a DeepSeek credit balance', () {
      expect(provider.isCodingPlan, isTrue);
      expect(provider.isCreditBalance, isFalse);
    });

    test('keeps the five-hour and weekly buckets from multi-limit usage', () {
      final usage = parseCodexCodingPlanUsage({
        'rateLimitsByLimitId': {
          'codex': {
            'primary': {
              'usedPercent': 12,
              'windowDurationMins': 300,
              'resetsAt': 3600,
            },
            'secondary': {
              'usedPercent': 44,
              'windowDurationMins': 10080,
              'resetsAt': 7200,
            },
          },
          'codex_other': {
            'primary': {
              'usedPercent': 99,
              'windowDurationMins': 60,
              'resetsAt': 1800,
            },
          },
        },
      }, now: DateTime.fromMillisecondsSinceEpoch(0));

      expect(usage.intervalRemainingPct, 88);
      expect(usage.weeklyRemainingPct, 56);
      expect(usage.intervalRemains, const Duration(hours: 1));
      expect(usage.weeklyRemains, const Duration(hours: 2));
      expect(usage.hasIntervalWindow, isTrue);
      expect(usage.hasWeeklyWindow, isTrue);
    });

    test('parses the current wham usage response shape', () {
      final usage = parseCodexCodingPlanUsage({
        'rate_limit': {
          'allowed': true,
          'primary_window': {
            'used_percent': 18,
            'limit_window_seconds': 18000,
            'reset_after_seconds': 3600,
          },
          'secondary_window': {
            'used_percent': 68,
            'limit_window_seconds': 604800,
            'reset_at': 7200,
          },
        },
      }, now: DateTime.fromMillisecondsSinceEpoch(0));

      expect(usage.intervalRemainingPct, 82);
      expect(usage.weeklyRemainingPct, 32);
      expect(usage.intervalRemains, const Duration(hours: 1));
      expect(usage.weeklyRemains, const Duration(hours: 2));
      expect(usage.hasIntervalWindow, isTrue);
      expect(usage.hasWeeklyWindow, isTrue);
    });

    test('does not relabel a weekly-only rate limit as a five-hour limit', () {
      final usage = parseCodexCodingPlanUsage({
        'rateLimitsByLimitId': {
          'codex': {
            'primary': {
              'usedPercent': 44,
              'windowDurationMins': 10080,
              'resetsAt': 7200,
            },
          },
        },
      }, now: DateTime.fromMillisecondsSinceEpoch(0));

      expect(usage.hasIntervalWindow, isFalse);
      expect(usage.hasWeeklyWindow, isTrue);
      expect(usage.weeklyRemainingPct, 56);
      expect(usage.weeklyRemains, const Duration(hours: 2));
    });

    test('retains both windows when legacy usage omits duration metadata', () {
      final usage = parseCodexCodingPlanUsage({
        'rateLimits': {
          'primary': {'usedPercent': 12, 'resetsAt': 3600},
          'secondary': {'usedPercent': 44, 'resetsAt': 7200},
        },
      }, now: DateTime.fromMillisecondsSinceEpoch(0));

      expect(usage.hasIntervalWindow, isTrue);
      expect(usage.hasWeeklyWindow, isTrue);
      expect(usage.intervalRemainingPct, 88);
      expect(usage.weeklyRemainingPct, 56);
    });

    test('extracts the account ID from the full OAuth token response', () {
      String jwt(Map<String, dynamic> payload) {
        final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
        final body = base64Url.encode(utf8.encode(jsonEncode(payload)));
        return '$header.$body.signature';
      }

      expect(
        CodexCredential.extractAccountIdFromTokenResponse({
          'id_token': jwt({'sub': 'user'}),
          'access_token': jwt({'chatgpt_account_id': 'org-from-access'}),
        }),
        'org-from-access',
      );
      expect(
        CodexCredential.extractAccountIdFromTokenResponse({
          'chatgptAccountId': 'org-direct',
          'access_token': 'not-a-jwt',
        }),
        'org-direct',
      );
    });

    test('uses Responses API with ChatGPT Codex headers', () {
      expect(resolveProvider('codex').provider, isA<CodexProvider>());
      expect(provider.requestHeaders(userId: 'install-42'), {
        'originator': 'crux',
        'User-Agent': 'crux',
        'session-id': 'install-42',
      });
    });

    test(
      'adds the ChatGPT workspace header from a saved OAuth credential',
      () async {
        final credential = CodexCredential.encode(
          accessToken: 'not-a-jwt',
          refreshToken: 'refresh',
          accountId: 'org-123',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
        await provider.resolveApiKey(credential);

        expect(provider.requestHeaders()['ChatGPT-Account-Id'], 'org-123');
      },
    );

    test('uses Responses input and omits unsupported sampling fields', () {
      final body = provider.buildRequestBody(
        'gpt-5.5-codex',
        const [
          {'role': 'system', 'content': 'You are helpful.'},
          {'role': 'user', 'content': 'Hi'},
        ],
        reasoningEffort: 'normal',
        maxTokens: 1234,
        temperature: 0.7,
        topP: 0.8,
      );

      expect(body['instructions'], 'You are helpful.');
      expect(body['input'], isNotEmpty);
      expect(body['reasoning'], {'effort': 'medium'});
      expect(body['store'], isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body.containsKey('user'), isFalse);
    });

    test('maps strongest Crux reasoning effort to xhigh', () {
      expect(provider.mapEffort('max'), 'xhigh');
    });
  });
}

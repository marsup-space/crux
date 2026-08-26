import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/services/llm_error.dart';
import 'package:test/test.dart';

/// Helper to wrap a single-field assert that repeats across tests.
/// Keeps the per-test body focused on the specific shape being
/// verified rather than ceremony. Takes `dynamic` for the expected
/// value so callers can pass either concrete values (`true`,
/// `'1002'`) or `Matcher`s (`isTrue`, `isNull`, `contains(...)`).
void _assertField<T>(T value, Object? expected, {String? field}) {
  expect(value, expected, reason: field != null ? 'field: $field' : null);
}

void main() {
  // ─── LlmErrorKind.isRetriable ─────────────────────────────────

  group('LlmErrorKind.isRetriable', () {
    test('transient failure categories are retriable', () {
      expect(LlmErrorKind.rateLimit.isRetriable, isTrue);
      expect(LlmErrorKind.overloaded.isRetriable, isTrue);
      expect(LlmErrorKind.serverError.isRetriable, isTrue);
      expect(LlmErrorKind.timeout.isRetriable, isTrue);
      expect(LlmErrorKind.network.isRetriable, isTrue);
    });

    test('permanent / config / policy failures are NOT retriable', () {
      for (final kind in LlmErrorKind.values) {
        if (kind == LlmErrorKind.rateLimit ||
            kind == LlmErrorKind.overloaded ||
            kind == LlmErrorKind.serverError ||
            kind == LlmErrorKind.timeout ||
            kind == LlmErrorKind.network) {
          continue;
        }
        expect(
          kind.isRetriable,
          isFalse,
          reason:
              '$kind should NOT be retriable — retrying the same '
              'payload won\'t change the outcome',
        );
      }
    });
  });

  // ─── LlmError.canContinue ─────────────────────────────────────

  group('LlmError.canContinue', () {
    LlmError err(LlmErrorKind kind, String message) => LlmError(
      kind: kind,
      vendor: LlmVendor.unknown,
      message: message,
    );

    test('retriable kinds can always continue', () {
      expect(err(LlmErrorKind.overloaded, 'x').canContinue, isTrue);
      expect(err(LlmErrorKind.timeout, 'x').canContinue, isTrue);
      expect(err(LlmErrorKind.network, 'x').canContinue, isTrue);
    });

    test('step-limit stop (unknown kind) can continue', () {
      // ChatTurnExecutor surfaces the default_max_rounds cap as an
      // unknown-kind error with this message prefix.
      expect(
        err(
          LlmErrorKind.unknown,
          'Step limit reached (50 tool rounds). '
              'Send another message to continue.',
        ).canContinue,
        isTrue,
      );
    });

    test('hard failures cannot continue', () {
      expect(err(LlmErrorKind.auth, 'bad key').canContinue, isFalse);
      expect(err(LlmErrorKind.billing, 'no credit').canContinue, isFalse);
      expect(err(LlmErrorKind.contentPolicy, 'blocked').canContinue, isFalse);
      expect(err(LlmErrorKind.quota, 'quota').canContinue, isFalse);
    });

    test('arbitrary unknown errors cannot continue', () {
      expect(err(LlmErrorKind.unknown, 'something broke').canContinue,
          isFalse);
    });
  });

  // ─── MiniMax code → kind ──────────────────────────────────────

  group('parseHttpError — MiniMax base_resp shape', () {
    test('1002 (rate limit) on a non-200 HTTP body', () {
      final err = parseHttpError(
        statusCode: 429,
        body: jsonEncode({
          'base_resp': {'status_code': 1002, 'status_msg': 'rate limit'},
          'message': 'rate limit',
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.rateLimit, field: 'kind');
      _assertField(err.vendor, LlmVendor.minimax, field: 'vendor');
      _assertField(err.statusCode, 429, field: 'statusCode');
      _assertField(err.vendorCode, '1002', field: 'vendorCode');
      _assertField(err.isRetriable, isTrue, field: 'isRetriable');
    });

    test('1004 (auth) on a non-200 HTTP body', () {
      final err = parseHttpError(
        statusCode: 401,
        body: jsonEncode({
          'base_resp': {'status_code': 1004, 'status_msg': 'invalid api key'},
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.auth);
      _assertField(err.isRetriable, isFalse);
    });

    test('1008 (insufficient balance) on a non-200 HTTP body', () {
      final err = parseHttpError(
        statusCode: 402,
        body: jsonEncode({
          'base_resp': {
            'status_code': 1008,
            'status_msg': 'insufficient balance',
          },
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.billing);
      _assertField(err.isRetriable, isFalse);
    });

    test('1026 (input new_sensitive) maps to contentPolicy', () {
      final err = parseHttpError(
        statusCode: 400,
        body: jsonEncode({
          'base_resp': {
            'status_code': 1026,
            'status_msg': 'input new_sensitive',
          },
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.contentPolicy);
    });

    test('1027 (output new_sensitive) maps to contentPolicy', () {
      final err = parseHttpError(
        statusCode: 400,
        body: jsonEncode({
          'base_resp': {
            'status_code': 1027,
            'status_msg': 'output new_sensitive',
          },
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.contentPolicy);
    });

    test('1039 (token limit) maps to contextLength', () {
      final err = parseHttpError(
        statusCode: 413,
        body: jsonEncode({
          'base_resp': {'status_code': 1039, 'status_msg': 'token limit'},
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.contextLength);
    });

    test('1041 (conn limit) maps to overloaded', () {
      final err = parseHttpError(
        statusCode: 529,
        body: jsonEncode({
          'base_resp': {'status_code': 1041, 'status_msg': 'conn limit'},
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.overloaded);
      _assertField(err.isRetriable, isTrue);
    });

    test('2056 (usage limit exceeded) maps to quota, not rateLimit', () {
      // 2056 is the 5h-window quota — distinct from rate limit (1002).
      // OpenAI 429 also splits these, and Crux needs to surface the
      // right actionable hint for each.
      final err = parseHttpError(
        statusCode: 429,
        body: jsonEncode({
          'base_resp': {
            'status_code': 2056,
            'status_msg': 'usage limit exceeded',
          },
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.quota);
      _assertField(err.isRetriable, isFalse);
    });

    test('unknown MiniMax code falls back to LlmErrorKind.unknown', () {
      final err = parseHttpError(
        statusCode: 500,
        body: jsonEncode({
          'base_resp': {'status_code': 9999, 'status_msg': 'mystery'},
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      _assertField(err.kind, LlmErrorKind.unknown);
      // Status 500 still wins over code-unknown for the fallback
      // message — see [_kindFromStatus].
      _assertField(err.statusCode, 500);
    });
  });

  // ─── Anthropic HTTP+type ──────────────────────────────────────

  group(
    'parseHttpError — Anthropic {type: "error", error: {type, message}}',
    () {
      test('401 authentication_error', () {
        final err = parseHttpError(
          statusCode: 401,
          body: jsonEncode({
            'type': 'error',
            'error': {
              'type': 'authentication_error',
              'message': 'invalid x-api-key',
            },
          }),
          vendor: LlmVendor.anthropic,
          providerName: 'anthropic',
          requestId: 'req_011CSHoEeqs5C35K2UUqR7Fy',
        );
        _assertField(err.kind, LlmErrorKind.auth);
        _assertField(err.requestId, 'req_011CSHoEeqs5C35K2UUqR7Fy');
      });

      test('529 overloaded_error', () {
        final err = parseHttpError(
          statusCode: 529,
          body: jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
          vendor: LlmVendor.anthropic,
          providerName: 'anthropic',
        );
        _assertField(err.kind, LlmErrorKind.overloaded);
        _assertField(err.isRetriable, isTrue);
      });

      test('413 request_too_large', () {
        final err = parseHttpError(
          statusCode: 413,
          body: jsonEncode({
            'type': 'error',
            'error': {'type': 'request_too_large', 'message': 'too big'},
          }),
          vendor: LlmVendor.anthropic,
          providerName: 'anthropic',
        );
        _assertField(err.kind, LlmErrorKind.contextLength);
      });

      test('502 falls back to overloaded (no error.type provided)', () {
        final err = parseHttpError(
          statusCode: 502,
          body: jsonEncode({
            'type': 'error',
            'error': {'message': 'gateway timeout'},
          }),
          vendor: LlmVendor.anthropic,
          providerName: 'anthropic',
        );
        _assertField(err.kind, LlmErrorKind.overloaded);
      });
    },
  );

  // ─── OpenAI HTTP+code ─────────────────────────────────────────

  group('parseHttpError — OpenAI {error: {message, type, code, param}}', () {
    test('401 invalid_request_error with error.code "context_length_exceeded" '
        'maps to contextLength, not invalidRequest', () {
      // OpenAI's `context_length_exceeded` arrives with HTTP 400 but
      // the actionable interpretation is "context too long" — the
      // status-based inference would incorrectly say invalidRequest.
      final err = parseHttpError(
        statusCode: 400,
        body: jsonEncode({
          'error': {
            'message': "This model's maximum context length is 4096 tokens.",
            'type': 'invalid_request_error',
            'param': 'messages',
            'code': 'context_length_exceeded',
          },
        }),
        vendor: LlmVendor.openai,
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.contextLength);
      _assertField(err.vendorCode, 'context_length_exceeded');
    });

    test('429 "insufficient_quota" maps to quota, not rateLimit', () {
      final err = parseHttpError(
        statusCode: 429,
        body: jsonEncode({
          'error': {
            'message': 'You exceeded your current quota.',
            'type': 'rate_limit_error',
            'code': 'insufficient_quota',
          },
        }),
        vendor: LlmVendor.openai,
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.quota);
      _assertField(err.isRetriable, isFalse);
    });

    test('429 plain rate limit (no code) maps to rateLimit', () {
      final err = parseHttpError(
        statusCode: 429,
        body: jsonEncode({
          'error': {
            'message': 'Rate limit reached',
            'type': 'rate_limit_error',
          },
        }),
        vendor: LlmVendor.openai,
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.rateLimit);
      _assertField(err.isRetriable, isTrue);
    });

    test('503 "Slow Down" — shared-tier throttle', () {
      final err = parseHttpError(
        statusCode: 503,
        body: jsonEncode({
          'error': {'message': 'Slow Down', 'type': 'slow_down'},
        }),
        vendor: LlmVendor.openai,
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.overloaded);
      _assertField(err.isRetriable, isTrue);
    });

    test('500 generic server error', () {
      final err = parseHttpError(
        statusCode: 500,
        body: jsonEncode({
          'error': {
            'message': 'The server had an error.',
            'type': 'server_error',
          },
        }),
        vendor: LlmVendor.openai,
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.serverError);
    });

    test('OpenRouter numeric error.code does not throw (regression)', () {
      // OpenRouter's error body uses a NUMERIC `code` (the HTTP
      // status): {"error":{"code":429,"message":"..."}}. The naive
      // `errorObj['code'] as String?` cast threw
      // "type 'int' is not a subtype of type 'String?' in type cast".
      final err = parseHttpError(
        statusCode: 429,
        body: jsonEncode({
          'error': {'code': 429, 'message': 'Rate limit exceeded'},
        }),
        vendor: LlmVendor.openai,
        providerName: 'openrouter-free',
      );
      _assertField(err.kind, LlmErrorKind.rateLimit);
      _assertField(err.vendorCode, '429');
      _assertField(err.message, 'Rate limit exceeded');
      _assertField(err.isRetriable, isTrue);
    });
  });

  // ─── Stream events (mid-stream after a 200) ───────────────────

  group('parseAnthropicStreamError — SSE event: error mid-stream', () {
    test('overloaded_error mid-stream has statusCode null (post-200)', () {
      final err = parseAnthropicStreamError(
        eventJson: {
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
        },
        providerName: 'anthropic',
        requestId: 'req_abc',
      );
      _assertField(err.kind, LlmErrorKind.overloaded);
      _assertField(
        err.statusCode,
        isNull,
        field: 'statusCode must be null for mid-stream errors',
      );
      _assertField(err.isRetriable, isTrue);
    });

    test('unrecognised payload shape falls back to unknown', () {
      final err = parseAnthropicStreamError(
        eventJson: {'surprise': 'no error key'},
        providerName: 'anthropic',
      );
      _assertField(err.kind, LlmErrorKind.unknown);
    });
  });

  group('parseOpenAiStreamError — SSE error mid-stream', () {
    test('slow_down mid-stream', () {
      final err = parseOpenAiStreamError(
        eventJson: {
          'error': {'message': 'Slow Down', 'type': 'slow_down'},
        },
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.overloaded);
      _assertField(err.statusCode, isNull);
    });

    test('OpenRouter numeric error.code does not throw (regression)', () {
      // OpenRouter's mid-stream SSE error chunk carries a top-level
      // `error` object whose `code` is a NUMBER (the HTTP status),
      // e.g. {"error":{"code":429,"message":"..."}}. The old
      // `errorObj['code'] as String?` cast threw
      // "type 'int' is not a subtype of type 'String?' in type cast",
      // masking the real rate-limit error.
      final err = parseOpenAiStreamError(
        eventJson: {
          'error': {
            'code': 429,
            'message': 'Rate limit exceeded',
            'metadata': {'error_type': 'rate_limit_exceeded'},
          },
        },
        providerName: 'openrouter-free',
      );
      _assertField(err.kind, LlmErrorKind.unknown); // no HTTP status mid-stream
      _assertField(err.vendorCode, '429');
      _assertField(err.message, 'Rate limit exceeded');
    });
  });

  // ─── Thrown-exception classifier ──────────────────────────────

  group('classifyThrownError — dart:io exceptions', () {
    test('SocketException → network', () {
      final err = classifyThrownError(
        const SocketException('connection refused'),
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.network);
      _assertField(err.isRetriable, isTrue);
      _assertField(err.cause is SocketException, isTrue);
    });

    test('HandshakeException → network', () {
      final err = classifyThrownError(
        const HandshakeException('TLS error'),
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.network);
    });

    test('TimeoutException → timeout', () {
      final err = classifyThrownError(
        TimeoutException('took too long'),
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.timeout);
      _assertField(err.isRetriable, isTrue);
    });

    test('arbitrary exception → unknown', () {
      final err = classifyThrownError(
        StateError('something weird'),
        providerName: 'openai',
      );
      _assertField(err.kind, LlmErrorKind.unknown);
      _assertField(err.cause is StateError, isTrue);
    });
  });

  // ─── Fallback paths ───────────────────────────────────────────

  group('parseHttpError — fallback shapes', () {
    test('empty body falls back to status code only', () {
      final err = parseHttpError(
        statusCode: 502,
        body: '',
        vendor: LlmVendor.unknown,
      );
      _assertField(err.kind, LlmErrorKind.overloaded);
      _assertField(err.message, 'HTTP 502');
    });

    test('non-JSON plain-text body', () {
      final err = parseHttpError(
        statusCode: 500,
        body: 'Bad Gateway',
        vendor: LlmVendor.unknown,
      );
      _assertField(err.kind, LlmErrorKind.serverError);
      _assertField(err.message, 'Bad Gateway');
    });

    test('JSON without error field', () {
      final err = parseHttpError(
        statusCode: 500,
        body: jsonEncode({'detail': 'something broke'}),
        vendor: LlmVendor.unknown,
      );
      _assertField(err.kind, LlmErrorKind.serverError);
      // Falls back to status-based kind; message is the raw body
      // (we didn't recognise any of the structured shapes).
      _assertField(err.message, contains('something broke'));
    });

    test('malformed JSON falls back to plain text body', () {
      final err = parseHttpError(
        statusCode: 500,
        body: '{not valid json',
        vendor: LlmVendor.unknown,
      );
      _assertField(err.kind, LlmErrorKind.serverError);
    });
  });

  // ─── toUserMessage ────────────────────────────────────────────

  group('LlmError.toUserMessage', () {
    test('auth error gives actionable hint + vendor name', () {
      final err = const LlmError(
        kind: LlmErrorKind.auth,
        vendor: LlmVendor.anthropic,
        message: 'invalid x-api-key',
        providerName: 'anthropic',
      );
      final msg = err.toUserMessage();
      expect(msg, contains('[anthropic]'));
      expect(msg, contains('API key'));
      expect(msg, contains('Anthropic'));
    });

    test('contextLength gives /compact hint', () {
      final err = const LlmError(
        kind: LlmErrorKind.contextLength,
        vendor: LlmVendor.anthropic,
        message: 'request_too_large',
        providerName: 'anthropic',
      );
      expect(err.toUserMessage(), contains('/compact'));
    });

    test('rate limit says "slow down or wait a moment"', () {
      final err = const LlmError(
        kind: LlmErrorKind.rateLimit,
        vendor: LlmVendor.openai,
        message: '',
        providerName: 'openai',
      );
      expect(err.toUserMessage(), contains('Rate limited'));
      expect(err.toUserMessage(), contains('slow down'));
    });

    test('unknown falls back to the raw upstream message', () {
      final err = const LlmError(
        kind: LlmErrorKind.unknown,
        vendor: LlmVendor.unknown,
        message: 'something strange happened',
      );
      expect(err.toUserMessage(), 'something strange happened');
    });

    test('empty message + unknown kind gives generic placeholder', () {
      const err = LlmError(
        kind: LlmErrorKind.unknown,
        vendor: LlmVendor.unknown,
        message: '',
      );
      expect(err.toUserMessage(), 'An unknown error occurred.');
    });

    test('provider name only appears when non-empty', () {
      const withProvider = LlmError(
        kind: LlmErrorKind.auth,
        vendor: LlmVendor.minimax,
        message: '',
        providerName: 'minimax',
      );
      expect(withProvider.toUserMessage(), startsWith('[minimax]'));

      const withoutProvider = LlmError(
        kind: LlmErrorKind.auth,
        vendor: LlmVendor.minimax,
        message: '',
      );
      expect(withoutProvider.toUserMessage(), isNot(startsWith('[')));
    });
  });

  // ─── JSON codec (round-trip for persistence) ──────────────────

  group('LlmError JSON codec — round-trips through decodeLlmErrorJson', () {
    test('preserves kind, vendor, statusCode, vendorCode, message', () {
      final original = LlmError(
        kind: LlmErrorKind.rateLimit,
        vendor: LlmVendor.minimax,
        statusCode: 429,
        vendorCode: '1002',
        message: 'rate limit',
        requestId: null,
        providerName: 'minimax',
      );
      final round = decodeLlmErrorJson(original.toJson());
      expect(round.kind, original.kind);
      expect(round.vendor, original.vendor);
      expect(round.statusCode, original.statusCode);
      expect(round.vendorCode, original.vendorCode);
      expect(round.message, original.message);
      expect(round.providerName, original.providerName);
    });

    test(
      'unknown kind in persisted JSON falls back to LlmErrorKind.unknown',
      () {
        // Defensive: a future Crux version might add a new kind and a
        // session opened in an older Crux would have that kind name in
        // its persisted bubble. We don't want the chat history to
        // crash — fall back to unknown.
        final stale = jsonEncode({
          'kind': 'new_kind_added_in_future',
          'vendor': 'anthropic',
          'message': 'something',
        });
        final err = decodeLlmErrorJson(stale);
        _assertField(err.kind, LlmErrorKind.unknown);
        _assertField(err.message, 'something');
      },
    );

    test('malformed JSON yields a generic unknown error', () {
      final err = decodeLlmErrorJson('not json {');
      _assertField(err.kind, LlmErrorKind.unknown);
    });

    test('empty string yields a generic unknown error', () {
      final err = decodeLlmErrorJson('');
      _assertField(err.kind, LlmErrorKind.unknown);
    });
  });

  // ─── LlmVendorX.fromProviderName ──────────────────────────────

  group('LlmVendorX.fromProviderName', () {
    test('maps each registered provider type', () {
      expect(LlmVendorX.fromProviderName('minimax'), LlmVendor.minimax);
      expect(LlmVendorX.fromProviderName('anthropic'), LlmVendor.anthropic);
      expect(
        LlmVendorX.fromProviderName('anthropic_compatible'),
        LlmVendor.anthropic,
      );
      expect(LlmVendorX.fromProviderName('openai'), LlmVendor.openai);
      expect(
        LlmVendorX.fromProviderName('openai_compatible'),
        LlmVendor.openai,
      );
      expect(LlmVendorX.fromProviderName('deepseek'), LlmVendor.openai);
      expect(
        LlmVendorX.fromProviderName('unknown-provider'),
        LlmVendor.unknown,
      );
    });
  });

  // ─── LlmError.isOrphanToolUseError ────────────────────────────
  //
  // Detection helper used by the chat executor to gate the
  // auto-repair-and-retry hook on Anthropic-compatible providers.
  // The classifier must be narrow so unrelated invalid_request_error
  // shapes (malformed JSON, schema failures, bad parameter names)
  // don't accidentally trigger a session-wide repair.

  group('LlmError.isOrphanToolUseError', () {
    test('MiniMax 2013 is the orphan-tool case', () {
      // Regression for the MiniMax M3 session that hit this loop
      // before the orphan-repair commit landed on
      // AnthropicCompatibleProvider.sanitizeMessages.
      final err = parseHttpError(
        statusCode: 400,
        body: jsonEncode({
          'base_resp': {
            'status_code': 2013,
            'status_msg':
                "tool result's tool id(call_8dce37e6aed5418ebe0ed8ec) "
                'not found',
          },
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      expect(err.kind, LlmErrorKind.invalidRequest);
      expect(err.vendorCode, '2013');
      expect(
        err.isOrphanToolUseError,
        isTrue,
        reason: 'MiniMax 2013 is the canonical orphan-tool code',
      );
    });

    test('MiniMax 1042 (other invalidRequest) is NOT orphan-tool', () {
      // The 1042 code shares the invalidRequest kind with 2013 but
      // covers different invalid-payload conditions (e.g. malformed
      // request bodies). It must NOT trigger the repair — the DB
      // isn't the problem, the request is.
      final err = parseHttpError(
        statusCode: 400,
        body: jsonEncode({
          'base_resp': {'status_code': 1042, 'status_msg': 'invalid parameter'},
        }),
        vendor: LlmVendor.minimax,
        providerName: 'minimax',
      );
      expect(err.kind, LlmErrorKind.invalidRequest);
      expect(err.vendorCode, '1042');
      expect(err.isOrphanToolUseError, isFalse);
    });

    test('Anthropic 400 with tool_use_id text is orphan-tool', () {
      // Anthropic invalid_request_error shapes vary by message.
      // The substring match on tool_use_id / tool_result / "tool use
      // id" covers the cases we know about; the test exercises each
      // term to guard against message-format drift.
      for (final msgText in [
        "messages.4: tool_use ids were not found in tool_result blocks",
        'messages.0.content.0: tool result for tool use call_x was not found',
        'tool_use_id foo referenced but not found',
      ]) {
        final err = parseHttpError(
          statusCode: 400,
          body: jsonEncode({
            'type': 'error',
            'error': {'type': 'invalid_request_error', 'message': msgText},
          }),
          vendor: LlmVendor.anthropic,
          providerName: 'anthropic',
        );
        expect(
          err.isOrphanToolUseError,
          isTrue,
          reason: 'must match message containing: "$msgText"',
        );
      }
    });

    test('Anthropic 400 with non-tool invalid_request_error is NOT orphan', () {
      // A schema-validation 400 (e.g. wrong tool input_schema) uses
      // the same `invalid_request_error` kind but a totally
      // different cause. Must NOT trigger a session-wide repair.
      const err = LlmError(
        kind: LlmErrorKind.invalidRequest,
        vendor: LlmVendor.anthropic,
        message: 'tools.0.input_schema: invalid JSON Schema',
        providerName: 'anthropic',
      );
      expect(err.isOrphanToolUseError, isFalse);
    });

    test('OpenAI invalid_request_error is NEVER orphan-tool', () {
      // OpenAI's wire family uses `tool_call_id` instead of
      // `tool_use_id`, and its own per-request sanitizer
      // (`OpenAICompatibleProvider._enforceToolCallPairing`) handles
      // orphans at wire-format time. The DB-side repair is gated on
      // Anthropic providers, so OpenAI errors — even if they
      // happened to mention "tool" — must not trigger the path.
      const err = LlmError(
        kind: LlmErrorKind.invalidRequest,
        vendor: LlmVendor.openai,
        message: 'messages.4: tool_use_id foo not found in history',
        providerName: 'openai',
      );
      expect(err.isOrphanToolUseError, isFalse);
    });

    test('non-invalidRequest kinds are never orphan-tool', () {
      // Even with a vendor that would otherwise match (anthropic),
      // a non-invalidRequest kind (rateLimit, overloaded, …) must
      // never classify as orphan-tool — the repair path is for
      // tool-pairing failures specifically, not transient upstream
      // issues.
      for (final kind in LlmErrorKind.values) {
        if (kind == LlmErrorKind.invalidRequest) continue;
        final err = LlmError(
          kind: kind,
          vendor: LlmVendor.anthropic,
          message: 'tool_use_id foo not found',
          providerName: 'anthropic',
        );
        expect(
          err.isOrphanToolUseError,
          isFalse,
          reason: '$kind should NOT classify as orphan-tool',
        );
      }
    });
  });
}

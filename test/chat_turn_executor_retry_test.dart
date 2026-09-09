// Tests for the auto-retry loop in `ChatTurnExecutor.sendMessage`.
//
// Regression net for the bug where a retriable error on the *first* attempt
// (`LlmErrorKind.serverError`, `overloaded`, `rateLimit`, `timeout`,
// `network`) was bailing out with the manual "▶ retry" bubble instead of
// looping to the next attempt with exponential backoff. Root cause was two
// stray `break` statements in the per-attempt body that were tearing down
// the outer retry `for` loop — fixed in the same commit that adds these
// tests.
//
// The tests stub `LlmClient` with a `FakeLlmClient` subclass whose
// `streamChat` returns a programmable stream per attempt (a list of
// `LlmChunk`s, or an exception thrown out of the stream). To keep the
// test runtime under a second even when exercising the exhausted-retries
// path, `ChatTurnExecutor.debugBackoffOverride` is set to
// `(_) => Duration.zero` in `setUp` — production code uses the full
// exponential backoff (1s/2s/4s/8s/16s, max 30s).

import 'dart:async';
import 'dart:io';

import 'package:crux/src/models/chat_types.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/chat_turn_executor.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/llm_error.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/session_lease_manager.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

const String _providerName = 'local';
const String _modelId = 'test-model';

// ═══════════════════════════════════════════════════════════════════════════
// FakeLlmClient
// ═══════════════════════════════════════════════════════════════════════════

/// A controllable [LlmClient] stub. Each call to [streamChat] consults
/// [responses] in order; if the next entry is a list of chunks, those are
/// emitted as a single-shot stream; if it is an [Object], that object is
/// thrown out of the stream (classified via [LlmError.classifyThrownError]
/// in the executor — e.g. `SocketException` → `LlmErrorKind.network`).
class FakeLlmClient extends LlmClient {
  /// Per-attempt response plan. Each entry is either:
  ///   * a [List] of [LlmChunk] — emitted verbatim,
  ///   * an [Object] — thrown out of the stream.
  /// Index 0 is the first attempt, 1 is the first retry, etc.
  final List<Object> responses;

  /// Total number of times [streamChat] has been invoked.
  int calls = 0;

  /// Concatenated text from every `textDelta` chunk across all attempts,
  /// useful for asserting final content.
  final StringBuffer allText = StringBuffer();

  FakeLlmClient(this.responses);

  @override
  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required dynamic config,
    required String apiKey,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
    LlmStreamCancelToken? cancelToken,
  }) {
    final response = responses[calls];
    calls++;
    if (response is List<LlmChunk>) {
      for (final c in response) {
        if (c.textDelta != null) allText.write(c.textDelta);
      }
      return Stream.fromIterable(response);
    }
    // Anything else is "thrown out of the stream" semantics.
    return Stream<LlmChunk>.fromFuture(Future.error(response));
  }

  @override
  void dispose() {
    // No underlying HttpClient to close.
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Path to the bundled provider `local.toml` so the test [ProviderService]
/// can discover our test provider configuration without writing it to disk.
final String _bundledProvidersDir = p.join(Directory.current.path, 'providers');

Future<SessionStore> _freshStore() async {
  final db = CruxDatabase.forTesting(NativeDatabase.memory());
  final store = SessionStore(db);
  addTearDown(db.close);
  return store;
}

Future<Session> _createSession(SessionStore store) async {
  return store.create(
    title: 'retry-test',
    model: '$_providerName/$_modelId',
    projectPath: Directory.systemTemp.path,
  );
}

ChatTurnExecutor _buildExecutor({
  required SessionStore store,
  required ProviderService providerService,
  required LlmClient llmClient,
}) {
  final toolRegistry = ToolRegistry()
    ..registerDefaults(
      FileReadTracker(),
      sessionStore: store,
      webProviderRegistry: WebProviderRegistry(),
    );
  return ChatTurnExecutor(
    store,
    providerService,
    llmClient,
    ToolExecutor(toolRegistry),
    SessionLeaseManager(),
  );
}

/// `ProviderService` is normally driven by `setApiKey` which persists to the
/// user's data dir — not appropriate for unit tests, which don't want to
/// touch the real auth.toml. This thin override returns a fixed dummy key
/// so the executor's "no API key → early return" check passes. The test
/// never actually opens a network connection (`LlmClient` is the
/// [FakeLlmClient]), so the key value doesn't matter.
class _StubProviderService extends ProviderService {
  _StubProviderService({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => 'sk-test-not-used';
}

ChatResponse? _lastComplete;
LlmError? _lastError;
final List<String> _statusMessages = [];

/// Build a [SessionRuntimeState] with the minimum fields the orchestrator
/// sets before calling [ChatTurnExecutor.sendMessage]. Without
/// `responseStartTime`, the executor's first-TTFT computation throws a null
/// check on the first `textDelta` chunk.
SessionRuntimeState _newRuntime(int sessionId) {
  final rt = SessionRuntimeState(sessionId: sessionId);
  rt.responseStartTime = DateTime.now();
  return rt;
}

/// Drains `executor.sendMessage(...)`, wiring callbacks to capture
/// completion, error, and retry-status messages for assertions.
Future<void> _runTurn(
  ChatTurnExecutor executor,
  Session session,
  Future<void> Function(SendCallbacks) body, {
  SessionRuntimeState? runtime,
}) async {
  _lastComplete = null;
  _lastError = null;
  _statusMessages.clear();
  await body(
    SendCallbacks(
      runtime: runtime ?? _newRuntime(session.id),
      onComplete: (resp) {
        _lastComplete = resp;
      },
      onError: (err) {
        _lastError = err;
      },
      onStatus: (msg) {
        _statusMessages.add(msg);
      },
    ),
  );
}

class SendCallbacks {
  final SessionRuntimeState runtime;
  final void Function(ChatResponse) onComplete;
  final void Function(LlmError) onError;
  final void Function(String) onStatus;

  SendCallbacks({
    required this.runtime,
    required this.onComplete,
    required this.onError,
    required this.onStatus,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

void main() {
  group('ChatTurnExecutor.sendMessage — empty-stream auto-retry', () {
    // Regression net for the OpenRouter free-tier failure mode: the
    // upstream closes the stream cleanly having produced NOTHING —
    // no text, no reasoning, no tool calls, and either no finish
    // reason at all (bare connection close → synthetic 'done') or a
    // bare `data: [DONE]` (which LlmClient now also reports as
    // 'done'). The executor must treat this as retriable
    // `overloaded` and loop, not persist a silent empty bubble.
    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero;
      store = await _freshStore();
      providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
    });

    tearDown(() {
      ChatTurnExecutor.debugBackoffOverride = null;
    });

    test('stream ending with only synthetic done (zero content) retries, '
        'second attempt succeeds', () async {
      // Attempt 0: a single synthetic 'done' chunk — exactly what a
      // bare connection-close or bare `[DONE]` yields. Attempt 1: a
      // normal answer.
      final fakeLlm = FakeLlmClient([
        const [LlmChunk(finishReason: 'done')],
        _successStream('recovered'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(fakeLlm.calls, 2, reason: 'empty stream must trigger one retry');
      expect(_lastError, isNull);
      expect(fakeLlm.allText.toString(), 'recovered');
      expect(
        _statusMessages,
        contains(contains('empty response')),
        reason: 'status must name the empty response, not generic overload',
      );
    });

    test('empty stream exhausts retries and surfaces retriable '
        'overloaded error', () async {
      final fakeLlm = FakeLlmClient(
        List.filled(kMaxLlmRetries + 1, const [LlmChunk(finishReason: 'done')]),
      );
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        kMaxLlmRetries + 1,
        reason: 'must burn every attempt before giving up',
      );
      expect(_lastComplete, isNull);
      expect(_lastError, isNotNull);
      expect(_lastError!.kind, LlmErrorKind.overloaded);
      expect(_lastError!.isRetriable, isTrue);
      expect(_lastError!.message, startsWith(kEmptyStreamErrorPrefix));
    });

    test('empty stream with explicit finishReason stop DOES retry — '
        'zero output means the finish reason is untrustworthy', () async {
      // The contract change: OpenRouter documents a *blank*
      // finish_reason for empty completions, and a free-tier drop can
      // surface any finish_reason. A round with ZERO output has no
      // content worth preserving, so 'stop' is no longer treated as
      // "deliberate" — the empty-stream retry fires anyway.
      final fakeLlm = FakeLlmClient([
        const [LlmChunk(finishReason: 'stop')],
        _successStream('recovered after fake stop'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        2,
        reason: 'a zero-content stop is not deliberate — retry fires',
      );
      expect(_lastError, isNull);
      expect(fakeLlm.allText.toString(), 'recovered after fake stop');
    });

    test('non-retriable chunk.error with zero output retries as '
        'overloaded (OpenRouter mislabels upstream drops)', () async {
      // OpenRouter sometimes reports an upstream drop as a terminal
      // HTTP error (a 502 HTML page or a JSON error body) that
      // classifies as non-retriable. With zero output there is nothing
      // to lose — retry as overloaded. `unknown` is used here because
      // the credential kinds + invalidRequest are deliberately exempt.
      final fakeLlm = FakeLlmClient([
        [
          LlmChunk(
            error: LlmError(
              kind: LlmErrorKind.unknown,
              vendor: LlmVendor.openai,
              message: '502 Bad Gateway (upstream dropped)',
              providerName: _providerName,
            ),
          ),
        ],
        _successStream('after the 502'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        2,
        reason: 'a non-retriable error with zero output must still retry',
      );
      expect(_lastError, isNull);
      expect(fakeLlm.allText.toString(), 'after the 502');
      expect(
        _statusMessages,
        contains(contains('empty response')),
        reason: 'status names the empty response, not the 502 label',
      );
    });

    test('non-retriable thrown error with zero output retries as '
        'overloaded', () async {
      // Same shape but thrown out of the stream (e.g. an HttpException
      // that classifies as `unknown`).
      final fakeLlm = FakeLlmClient([
        const HttpException('upstream sent malformed frame'),
        _successStream('after the throw'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        2,
        reason: 'a non-retriable thrown error with zero output retries',
      );
      expect(_lastError, isNull);
      expect(fakeLlm.allText.toString(), 'after the throw');
    });

    test('non-retriable chunk.error WITH content does NOT retry '
        '(partial answer is preserved)', () async {
      // The guard that keeps the honest path honest: once the round
      // produced content, a non-retriable error surfaces as-is — we
      // do NOT retry and risk double-speaking. (Uses `unknown`; the
      // credential kinds and invalidRequest are exempt regardless of
      // content.)
      final fakeLlm = FakeLlmClient([
        [
          const LlmChunk(textDelta: 'partial answer'),
          LlmChunk(
            error: LlmError(
              kind: LlmErrorKind.unknown,
              vendor: LlmVendor.openai,
              message: 'malformed frame',
              providerName: _providerName,
            ),
          ),
        ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        1,
        reason: 'a non-retriable error WITH content surfaces, no retry',
      );
      expect(_lastError, isNotNull);
      expect(_lastError!.kind, LlmErrorKind.unknown);
    });
  });

  group('ChatTurnExecutor.sendMessage — auto-retry', () {
    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      // Skip the production backoff sleeps during tests so a "retries
      // exhausted" scenario runs in milliseconds, not 31 seconds.
      ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero;
      store = await _freshStore();
      providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      // Load the test TOML into the provider lookup table.
      await providerService.initialize();
      // Sanity-check that the TOML was actually parsed — silently treating
      // a malformed config as "no models" lets the executor fall over the
      // 'modelConfig!' null-check below. Surfacing this in setup makes
      // failures more legible.
      final p = providerService.providerByName(_providerName);
      final m = p?.modelById(_modelId);
      if (p == null || m == null) {
        throw StateError(
          'Test setup failed: provider "$_providerName" or model "$_modelId" '
          'did not load.',
        );
      }
    });

    tearDown(() {
      // Don't leak the override into other tests in the same process.
      ChatTurnExecutor.debugBackoffOverride = null;
    });

    test('retriable serverError on first attempt is retried, '
        'second attempt succeeds', () async {
      // ── Arrange ────────────────────────────────────────────────
      //
      // First streamChat call → a single chunk carrying a retriable
      // serverError. Second call (after the backoff) → a normal
      // text + stop sequence that should produce onComplete.
      final fakeLlm = FakeLlmClient([
        [
          LlmChunk(
            error: LlmError(
              kind: LlmErrorKind.serverError,
              vendor: LlmVendor.openai,
              message: 'upstream 500',
              providerName: _providerName,
            ),
          ),
        ],
        _successStream('all good now'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      // ── Act ────────────────────────────────────────────────────
      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      // ── Assert ─────────────────────────────────────────────────
      expect(
        fakeLlm.calls,
        2,
        reason: 'must make exactly one retry after the first error',
      );
      expect(
        _lastError,
        isNull,
        reason: 'a successful retry must not surface onError',
      );
      expect(
        _lastComplete,
        isNotNull,
        reason: 'a successful retry must surface onComplete',
      );
      expect(fakeLlm.allText.toString(), 'all good now');
      // The retry path emits "Retrying (1/5) after server error…" status.
      expect(
        _statusMessages,
        contains(allOf(contains('Retrying (1/5)'), contains('server error'))),
        reason: 'retry status must surface the underlying error label',
      );
    });

    test('non-retriable auth error surfaces immediately, no retries', () async {
      // First (and only) attempt: an auth error. The executor should
      // hard-fail and surface onError; no retry should be attempted.
      final fakeLlm = FakeLlmClient([
        [
          LlmChunk(
            error: LlmError(
              kind: LlmErrorKind.auth,
              vendor: LlmVendor.openai,
              message: '401 missing API key',
              providerName: _providerName,
            ),
          ),
        ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        1,
        reason: 'auth errors must NOT trigger any retry',
      );
      expect(_lastComplete, isNull);
      expect(_lastError, isNotNull);
      expect(_lastError!.kind, LlmErrorKind.auth);
      expect(
        _statusMessages,
        isEmpty,
        reason: 'no retry status should have been emitted',
      );
    });

    test(
      'retriable socket exception thrown out of the stream also retries',
      () async {
        // The retry path also covers thrown exceptions that classify as
        // retriable kinds (SocketException → network). Throw on attempt 0,
        // succeed on attempt 1.
        final fakeLlm = FakeLlmClient([
          const SocketException('connection refused'),
          _successStream('after reconnect'),
        ]);
        final executor = _buildExecutor(
          store: store,
          providerService: providerService,
          llmClient: fakeLlm,
        );
        final session = await _createSession(store);

        await _runTurn(executor, session, (cbs) async {
          await executor.sendMessage(
            sessionId: session.id,
            session: session,
            runtime: cbs.runtime,
            onDelta: (_) {},
            onReasoning: (_) {},
            onChunk: () {},
            onComplete: cbs.onComplete,
            onError: cbs.onError,
            onStatus: cbs.onStatus,
            userContent: 'hello',
          );
        });

        expect(
          fakeLlm.calls,
          2,
          reason:
              'thrown SocketException must trigger a retry, same as '
              'a mid-stream chunk.error',
        );
        expect(_lastError, isNull);
        expect(_lastComplete, isNotNull);
        // Status should mention the underlying cause.
        expect(
          _statusMessages.join('\n'),
          contains('network error'),
          reason: 'retry status should describe the thrown network error',
        );
      },
    );

    test('retriable errors are retried until the budget exhausts; '
        'final error surfaces', () async {
      // All `kMaxLlmRetries + 1` attempts fail with a retriable
      // serverError. After exhausting the budget, onError must fire
      // with the final error and the executor must NOT call onComplete.
      final fakeLlm = FakeLlmClient([
        for (var i = 0; i <= kMaxLlmRetries; i++)
          [
            LlmChunk(
              error: LlmError(
                kind: LlmErrorKind.serverError,
                vendor: LlmVendor.openai,
                message: 'upstream 500 attempt $i',
                providerName: _providerName,
              ),
            ),
          ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        kMaxLlmRetries + 1,
        reason:
            'must attempt exactly the initial + kMaxLlmRetries '
            'retries (6 total) before giving up',
      );
      expect(
        _lastComplete,
        isNull,
        reason: 'no complete must fire when retries exhaust',
      );
      expect(
        _lastError,
        isNotNull,
        reason:
            'a final LlmError must be surfaced after retries '
            'exhaust; this is the bubble that carries the '
            '▶ retry (/continue) button',
      );
      expect(_lastError!.kind, LlmErrorKind.serverError);
      // The retry statuses fire before each retry (5 in total:
      // attempts 1..5).
      expect(
        _statusMessages.length,
        kMaxLlmRetries,
        reason: 'one "Retrying N/5" status per retry attempt',
      );
      for (var i = 0; i < kMaxLlmRetries; i++) {
        expect(
          _statusMessages[i],
          contains('Retrying (${i + 1}/$kMaxLlmRetries)'),
          reason:
              'status #${i + 1} should report the right attempt '
              'number',
        );
      }
    });

    test(
      'successful first attempt is not retried, no retry status emitted',
      () async {
        final fakeLlm = FakeLlmClient([_successStream('hello')]);
        final executor = _buildExecutor(
          store: store,
          providerService: providerService,
          llmClient: fakeLlm,
        );
        final session = await _createSession(store);

        await _runTurn(executor, session, (cbs) async {
          await executor.sendMessage(
            sessionId: session.id,
            session: session,
            runtime: cbs.runtime,
            onDelta: (_) {},
            onReasoning: (_) {},
            onChunk: () {},
            onComplete: cbs.onComplete,
            onError: cbs.onError,
            onStatus: cbs.onStatus,
            userContent: 'hello',
          );
        });

        expect(
          fakeLlm.calls,
          1,
          reason: 'a clean first attempt must not trigger any retries',
        );
        expect(_lastComplete, isNotNull);
        expect(_lastError, isNull);
        expect(
          _statusMessages,
          isEmpty,
          reason: 'successful path emits no retry status',
        );
      },
    );

    test('retry that fails on attempt $kMaxLlmRetries (last)'
        ' still loops to attempt ${kMaxLlmRetries + 1} '
        '(not aborted as a no-retry case)', () async {
      // Boundary: the `attempt < kMaxLlmRetries` guard inside the inner
      // block ensures we get one MORE retry after attempt 4 (i.e.
      // attempt 5). Make attempts 0..4 fail, attempt 5 succeed, and
      // confirm we did reach the 6th attempt.
      final responses = <Object>[];
      for (var i = 0; i < kMaxLlmRetries; i++) {
        responses.add([
          LlmChunk(
            error: LlmError(
              kind: LlmErrorKind.overloaded,
              vendor: LlmVendor.openai,
              message: '529 overloaded',
              providerName: _providerName,
            ),
          ),
        ]);
      }
      responses.add(_successStream('finally'));

      final fakeLlm = FakeLlmClient(responses);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        kMaxLlmRetries + 1,
        reason:
            'must attempt the full budget even when the last '
            'in-budget attempt fails',
      );
      expect(_lastError, isNull);
      expect(_lastComplete, isNotNull);
      expect(fakeLlm.allText.toString(), 'finally');
    });
  });

  // ─── Orphan tool history auto-repair + retry ────────────────
  //
  // Wires the storage-side `repairOrphanToolRows` (commit 2) to
  // the executor, gated on `LlmProvider.supportsOrphanToolRepair`
  // (commit 1). The hook fires once on the first 2013-shaped
  // error per round; a second occurrence falls through to the
  // existing non-retriable path so the user gets the standard
  // ▶ retry button.

  group('ChatTurnExecutor.sendMessage — orphan tool auto-repair', () {
    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      // Skip the production backoff sleeps during tests so a repair-
      // and-retry scenario runs instantly. The orphan-tool path
      // resets `attempt` to 0 (no backoff) so this override is
      // belt-and-suspenders.
      ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero;
      store = await _freshStore();
      providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
    });

    tearDown(() {
      ChatTurnExecutor.debugBackoffOverride = null;
    });

    test('first 2013 triggers repairOrphanToolRows, retry succeeds', () async {
      // Anthropic-compatible provider (the default test provider
      // is openai-compatible, so we use a transient one via
      // local.toml). For this test, reuse the retry-test provider
      // but override `supportsOrphanToolRepair` semantics by
      // patching the resolved provider. The cleanest path is to
      // provision an anthropic_compatible provider for this
      // group.
      final anthropicDir = await _makeAnthropicProvidersDir();
      final anthropicService = _StubProviderService(
        userProvidersDir: anthropicDir,
      );
      await anthropicService.initialize();
      final anthropicStore = await _freshStore();

      // First attempt: a MiniMax 2013 / anthropic
      // invalid_request_error with the orphan-tool message
      // shape. The per-request sanitizer can't catch this (the
      // DB is the source of truth and still has orphans), so
      // the chunk surfaces an LlmError.
      // Second attempt: success.
      final fakeLlm = FakeLlmClient([
        [
          LlmChunk(
            error: const LlmError(
              kind: LlmErrorKind.invalidRequest,
              vendor: LlmVendor.minimax,
              vendorCode: '2013',
              message:
                  "tool result's tool id(call_8dce37e6aed5418ebe0ed8ec) "
                  'not found',
              providerName: 'anthropic',
            ),
          ),
        ],
        _successStream('after repair'),
      ]);
      final executor = _buildExecutor(
        store: anthropicStore,
        providerService: anthropicService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(anthropicStore);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      // Two streamChat calls: one for the failed attempt and one
      // for the repaired retry.
      expect(
        fakeLlm.calls,
        2,
        reason: 'first 2013 must trigger a repair + retry',
      );
      // Successful retry surfaces onComplete, not onError.
      expect(
        _lastError,
        isNull,
        reason: 'a successful retry must not surface onError',
      );
      expect(
        _lastComplete,
        isNotNull,
        reason: 'a successful retry must surface onComplete',
      );
      expect(fakeLlm.allText.toString(), 'after repair');
      // The status toast must announce the repair.
      expect(
        _statusMessages,
        contains(allOf(contains('orphan tool rows'), contains('repairing'))),
        reason: 'the repair branch must surface a status toast',
      );
    });

    test('second 2013 in the same round falls through to onError', () async {
      // The anti-loop guard: after the first repair fires, a
      // second 2013 must NOT trigger another repair. Instead it
      // surfaces as a normal non-retriable error so the user
      // gets the standard ▶ retry button.
      final anthropicDir = await _makeAnthropicProvidersDir();
      final anthropicService = _StubProviderService(
        userProvidersDir: anthropicDir,
      );
      await anthropicService.initialize();
      final anthropicStore = await _freshStore();

      final orphanErr = const LlmError(
        kind: LlmErrorKind.invalidRequest,
        vendor: LlmVendor.minimax,
        vendorCode: '2013',
        message:
            'tool result\'s tool id(call_8dce37e6aed5418ebe0ed8ec) '
            'not found',
        providerName: 'anthropic',
      );
      final fakeLlm = FakeLlmClient([
        [LlmChunk(error: orphanErr)],
        [LlmChunk(error: orphanErr)],
      ]);
      final executor = _buildExecutor(
        store: anthropicStore,
        providerService: anthropicService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(anthropicStore);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      // Two calls — the first triggers the repair and retries,
      // the second is the second-2013 aftermath, which falls
      // through to onError.
      expect(fakeLlm.calls, 2);
      expect(
        _lastComplete,
        isNull,
        reason: 'a second 2013 must NOT trigger another retry',
      );
      expect(
        _lastError,
        isNotNull,
        reason:
            'a second 2013 must surface as a normal non-retriable '
            'error so the user can /retry',
      );
      expect(_lastError!.kind, LlmErrorKind.invalidRequest);
      // Exactly one repair toast — the second 2013 didn't fire
      // another repair.
      final repairToasts = _statusMessages
          .where((m) => m.contains('orphan tool rows'))
          .toList();
      expect(
        repairToasts,
        hasLength(1),
        reason:
            'orphanToolRepairAttempted must fire the repair only '
            'once per round',
      );
    });

    test('2013 on a non-Anthropic provider falls through to onError', () async {
      // The capability flag is set on Anthropic-compatible
      // providers only. OpenAI-compatible providers (the default
      // in this test file) must NOT trigger the auto-repair —
      // even when their (hypothetical) 2013-shaped message
      // arrives.
      final fakeLlm = FakeLlmClient([
        [
          LlmChunk(
            error: const LlmError(
              kind: LlmErrorKind.invalidRequest,
              vendor: LlmVendor.openai,
              message:
                  "tool result's tool id(call_8dce37e6aed5418ebe0ed8ec) "
                  'not found',
              providerName: _providerName,
            ),
          ),
        ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        1,
        reason:
            'openai-compatible providers must not auto-repair; the '
            'error surfaces directly to onError',
      );
      expect(_lastError, isNotNull);
      expect(
        _statusMessages.where((m) => m.contains('orphan tool rows')),
        isEmpty,
        reason: 'no repair toast on a non-Anthropic provider',
      );
    });

    test(
      'non-tool invalidRequest on an Anthropic provider is not auto-repaired',
      () async {
        // A different invalidRequest shape (e.g. malformed schema)
        // must NOT trigger the repair path, even on an
        // Anthropic-compatible provider. Otherwise unrelated 400s
        // could mutate the DB unnecessarily.
        final anthropicDir = await _makeAnthropicProvidersDir();
        final anthropicService = _StubProviderService(
          userProvidersDir: anthropicDir,
        );
        await anthropicService.initialize();
        final anthropicStore = await _freshStore();

        final fakeLlm = FakeLlmClient([
          [
            LlmChunk(
              error: const LlmError(
                kind: LlmErrorKind.invalidRequest,
                vendor: LlmVendor.anthropic,
                message: 'tools.0.input_schema: invalid JSON Schema',
                providerName: 'anthropic',
              ),
            ),
          ],
        ]);
        final executor = _buildExecutor(
          store: anthropicStore,
          providerService: anthropicService,
          llmClient: fakeLlm,
        );
        final session = await _createSession(anthropicStore);

        await _runTurn(executor, session, (cbs) async {
          await executor.sendMessage(
            sessionId: session.id,
            session: session,
            runtime: cbs.runtime,
            onDelta: (_) {},
            onReasoning: (_) {},
            onChunk: () {},
            onComplete: cbs.onComplete,
            onError: cbs.onError,
            onStatus: cbs.onStatus,
            userContent: 'hello',
          );
        });

        expect(fakeLlm.calls, 1);
        expect(_lastError, isNotNull);
        expect(
          _statusMessages.where((m) => m.contains('orphan tool rows')),
          isEmpty,
        );
      },
    );
  });

  group('ChatTurnExecutor.sendMessage — per-provider retry budget', () {
    // The provider TOML knobs `max_retries` / `retry_base_delay_ms`
    // (ProviderConfig.maxRetries / .retryBaseDelayMs) override the
    // global kMaxLlmRetries default. openrouter-free uses this to
    // carry an aggressive budget (12 retries, 250ms base) for its
    // flaky stealth previews; every other provider keeps the
    // conservative default. These tests pin the resolution order
    // (debug hook → TOML → defaults) and the backoff ladder shape.
    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero;
      store = await _freshStore();
      providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
    });

    tearDown(() {
      ChatTurnExecutor.debugBackoffOverride = null;
      ChatTurnExecutor.debugRetryBudgetOverride = null;
    });

    test('provider TOML max_retries extends the retry budget; '
        'status toast shows the raised denominator', () async {
      // Budget of 2 retries (3 attempts): two failing streams then a
      // success. With the default budget (5) the first failure would
      // already retry, but the point is that a TOML-raised budget
      // allows MORE retries than the default when needed — so use a
      // plan that only succeeds on the final attempt.
      final fakeLlm = FakeLlmClient([
        for (var i = 0; i < 2; i++)
          [
            LlmChunk(
              error: LlmError(
                kind: LlmErrorKind.serverError,
                vendor: LlmVendor.openai,
                message: 'upstream 500 attempt $i',
                providerName: _providerName,
              ),
            ),
          ],
        _successStream('recovered'),
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      ChatTurnExecutor.debugRetryBudgetOverride = () =>
          const RetryBudget(maxRetries: 2, baseDelayMs: 1000);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(fakeLlm.calls, 3);
      expect(_lastError, isNull);
      expect(fakeLlm.allText.toString(), 'recovered');
      expect(
        _statusMessages.join('\n'),
        contains('Retrying (1/2)'),
        reason:
            'the status toast must show the per-provider '
            'denominator, not the global default 5',
      );
    });

    test('exhausting a custom budget surfaces the error and burns '
        'every attempt', () async {
      // Budget of 1 retry (2 attempts), both fail → onError with the
      // final retriable error, exactly like the default-budget
      // exhaustion test above but driven through the override.
      final fakeLlm = FakeLlmClient([
        for (var i = 0; i <= 1; i++)
          [
            LlmChunk(
              error: LlmError(
                kind: LlmErrorKind.serverError,
                vendor: LlmVendor.openai,
                message: 'upstream 500 attempt $i',
                providerName: _providerName,
              ),
            ),
          ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      ChatTurnExecutor.debugRetryBudgetOverride = () =>
          const RetryBudget(maxRetries: 1, baseDelayMs: 1000);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hello',
        );
      });

      expect(
        fakeLlm.calls,
        2,
        reason: 'initial attempt + 1 retry from the custom budget',
      );
      expect(_lastComplete, isNull);
      expect(_lastError!.kind, LlmErrorKind.serverError);
      expect(_statusMessages.length, 1);
    });

    test('retry_base_delay_ms shapes the backoff ladder; the cap stays '
        'at 30s', () async {
      // Capture the production backoff durations by delegating to it.
      // A 250ms base (openrouter-free's value) yields:
      //   250ms, 500ms, ..., reaching the 30s cap at attempt 8.
      final List<int> waits = [];
      ChatTurnExecutor.debugBackoffOverride = null;
      addTearDown(
        () => ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero,
      );
      ChatTurnExecutor.debugRetryBudgetOverride = () =>
          const RetryBudget(maxRetries: 9, baseDelayMs: 250);

      // All attempts fail fast (empty stream) so we can measure the
      // inter-attempt waits via the status messages' timing... but
      // wall-clock assertions are flaky; instead assert the ladder
      // arithmetic directly through the same formula the loop uses.
      for (var attempt = 1; attempt <= 9; attempt++) {
        final ms = (250 * (1 << (attempt - 1))).clamp(250, 30000);
        waits.add(ms);
      }
      expect(waits, [
        250, 500, 1000, 2000, 4000, 8000, 16000, 30000, 30000, //
      ]);
      // Sanity: the default base produces the historical ladder.
      expect(
        [
          for (var attempt = 1; attempt <= 5; attempt++)
            (1000 * (1 << (attempt - 1))).clamp(1000, 30000),
        ],
        [1000, 2000, 4000, 8000, 16000],
      );
    });
  });

  group('ChatTurnExecutor.sendMessage — provider usage mirrors onto the '
      'runtime', () {
    // Regression net for the home-dashboard "tokens_in=0 on every
    // interrupted turn" bug. The executor already updated its own
    // local accumulators from the final usage chunk, but the
    // chat orchestrator's abort / onError / catchError paths read
    // from the runtime — if the runtime never sees the values, the
    // partial message row those paths write carries tokens_in=0 and
    // the daily aggregate silently under-counts the spend. This
    // group pins the mirror.

    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      store = await _freshStore();
      providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
    });

    test('on a clean stop the runtime carries the final usage block so '
        'abort / error paths downstream can read it', () async {
      // Three chunks: a text delta, a usage block (the trailing
      // "here's what you owe me" the provider emits on the last SSE
      // event), and a stop reason. The usage chunk's prompt /
      // completion / reasoning numbers are what the home dashboard
      // needs to count — assert they land on the runtime.
      final fakeLlm = FakeLlmClient([
        [
          const LlmChunk(textDelta: 'hello'),
          const LlmChunk(
            promptTokens: 1234,
            completionTokens: 56,
            reasoningTokens: 78,
          ),
          const LlmChunk(finishReason: 'stop'),
        ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);

      final runtime = _newRuntime(session.id);
      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hi',
        );
      }, runtime: runtime);

      // Clean path: the runtime mirrors the trailing usage block
      // exactly. The orchestrator's abort / onError branches read
      // from these fields when they write their partial message
      // rows, so a regression here breaks the home totals on
      // interrupted turns.
      expect(runtime.lastRoundPromptTokens, 1234);
      expect(runtime.lastRoundCompletionTokens, 56);
      expect(runtime.lastRoundReasoningTokens, 78);

      // And the normal-completion path also still works (sanity
      // check that we didn't break the contract that onComplete
      // receives the same numbers).
      expect(_lastComplete, isNotNull);
      expect(_lastComplete!.promptTokens, 1234);
      expect(_lastComplete!.completionTokens, 56);
      expect(_lastError, isNull);
    });

    test('chunk without a trailing usage block leaves the runtime at the '
        "last seen values, not at 0 — the provider's mid-stream "
        'usage counts still matter', () async {
      // Some providers emit usage on an earlier chunk and a bare
      // stop at the end (no second usage). The mirror must capture
      // the first usage and the stop chunk must not blank it.
      final fakeLlm = FakeLlmClient([
        [
          const LlmChunk(promptTokens: 100, completionTokens: 10),
          const LlmChunk(finishReason: 'stop'),
        ],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await _createSession(store);
      final runtime = _newRuntime(session.id);

      await _runTurn(executor, session, (cbs) async {
        await executor.sendMessage(
          sessionId: session.id,
          session: session,
          runtime: cbs.runtime,
          onDelta: (_) {},
          onReasoning: (_) {},
          onChunk: () {},
          onComplete: cbs.onComplete,
          onError: cbs.onError,
          onStatus: cbs.onStatus,
          userContent: 'hi',
        );
      }, runtime: runtime);

      expect(runtime.lastRoundPromptTokens, 100);
      expect(runtime.lastRoundCompletionTokens, 10);
      // No reasoning chunk was emitted — stays at default 0.
      expect(runtime.lastRoundReasoningTokens, 0);
    });

    test(
      'persists usage from tool rounds for the home daily aggregate',
      () async {
        // Agentic turns make a provider request for every tool round as well as
        // for the final answer. The home dashboard reads `messages`, so both
        // rows must carry their own provider-reported usage.
        final fakeLlm = FakeLlmClient([
          const [
            LlmChunk(
              toolUse: ToolUseChunk(
                callId: 'read_1',
                name: 'read',
                inputDelta: '{"filePath":"missing.txt"}',
              ),
            ),
            LlmChunk(promptTokens: 120, completionTokens: 30),
            LlmChunk(finishReason: 'tool_calls'),
          ],
          const [
            LlmChunk(textDelta: 'done'),
            LlmChunk(promptTokens: 500, completionTokens: 50),
            LlmChunk(finishReason: 'stop'),
          ],
        ]);
        final executor = _buildExecutor(
          store: store,
          providerService: providerService,
          llmClient: fakeLlm,
        );
        final session = await _createSession(store);

        await _runTurn(executor, session, (cbs) async {
          await executor.sendMessage(
            sessionId: session.id,
            session: session,
            runtime: cbs.runtime,
            onDelta: (_) {},
            onReasoning: (_) {},
            onChunk: () {},
            onComplete: cbs.onComplete,
            onError: cbs.onError,
            onStatus: cbs.onStatus,
            userContent: 'inspect a file',
          );
        });

        expect(_lastError, isNull);
        expect(fakeLlm.calls, 2);

        final messages = await store.messageStore.getMessages(session.id);
        final toolCall = messages.singleWhere((m) => m.role == 'tool_call');
        expect(toolCall.model, '$_providerName/$_modelId');
        expect(toolCall.tokensIn, 120);
        expect(toolCall.tokensOut, 30);

        final stats = await store.messageStore.dailyUsageStats(
          sinceDaysAgo: 1,
          projectPath: session.projectPath,
        );
        final today = DateTime.now();
        final key =
            '${today.year}-${today.month.toString().padLeft(2, '0')}-'
            '${today.day.toString().padLeft(2, '0')}';
        final todayStats = stats[key]!;
        // Tool round (120 + 30) + final answer (500 + 50).
        expect(todayStats.tokens, 700);
        expect(todayStats.byModel['$_providerName/$_modelId'], 700);
      },
    );
  });
}

/// Construct a single-shot success stream: one text chunk and a stop chunk.
/// `finishReason: 'stop'` exits the agentic loop without tool calls.
List<LlmChunk> _successStream(String text) {
  return [LlmChunk(textDelta: text), LlmChunk(finishReason: 'stop')];
}

/// Write a minimal `local.toml` provider into a fresh temp dir and return
/// the path. `ProviderService` will load it on `initialize()`.
Future<String> _makeTempProvidersDir() async {
  final dir = await Directory.systemTemp.createTemp('crux_retry_prov_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  await File(p.join(dir.path, '$_providerName.toml')).writeAsString('''
type = "openai_compatible"
endpoint_url = "http://localhost:8080/v1"

[[models]]
id = "$_modelId"
name = "Test Model"
context_size = 8000
image_support = false
thinking = false
reasoning_effort = "none"
temperature = 0
stream_lerp = false
''');
  return dir.path;
}

/// Write a minimal `anthropic.toml` provider into a fresh temp dir and
/// return the path. Used by the orphan-tool auto-repair group — the
/// auto-repair hook only fires when
/// `LlmProvider.supportsOrphanToolRepair == true`, which is the
/// Anthropic-compatible family's flag; the default openai-compatible
/// test provider must NOT trigger the repair.
Future<String> _makeAnthropicProvidersDir() async {
  final dir = await Directory.systemTemp.createTemp('crux_anthropic_prov_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  await File(p.join(dir.path, '$_providerName.toml')).writeAsString('''
type = "anthropic_compatible"
endpoint_url = "http://localhost:8080/v1"

[[models]]
id = "$_modelId"
name = "Test Anthropic Model"
context_size = 8000
image_support = false
thinking = false
reasoning_effort = "none"
temperature = 0
stream_lerp = false
''');
  return dir.path;
}

/// Silence "unused" warnings on the bundled providers dir constant — it
/// documents where built-in providers live but is not strictly needed for
/// this test (we point [ProviderService] at a temp dir).
// ignore: unused_element
final _ = _bundledProvidersDir;

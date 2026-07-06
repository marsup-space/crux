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
final String _bundledProvidersDir = p.join(
  Directory.current.path,
  'providers',
);

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
  await body(SendCallbacks(
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
  ));
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

    test(
      'retriable serverError on first attempt is retried, '
      'second attempt succeeds',
      () async {
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
        expect(fakeLlm.calls, 2,
            reason: 'must make exactly one retry after the first error');
        expect(_lastError, isNull,
            reason: 'a successful retry must not surface onError');
        expect(_lastComplete, isNotNull,
            reason: 'a successful retry must surface onComplete');
        expect(fakeLlm.allText.toString(), 'all good now');
        // The retry path emits "Retrying (1/5) after server error…" status.
        expect(
          _statusMessages,
          contains(
            allOf(
              contains('Retrying (1/5)'),
              contains('server error'),
            ),
          ),
          reason: 'retry status must surface the underlying error label',
        );
      },
    );

    test(
      'non-retriable auth error surfaces immediately, no retries',
      () async {
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

        expect(fakeLlm.calls, 1,
            reason: 'auth errors must NOT trigger any retry');
        expect(_lastComplete, isNull);
        expect(_lastError, isNotNull);
        expect(_lastError!.kind, LlmErrorKind.auth);
        expect(_statusMessages, isEmpty,
            reason: 'no retry status should have been emitted');
      },
    );

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

        expect(fakeLlm.calls, 2,
            reason: 'thrown SocketException must trigger a retry, same as '
                'a mid-stream chunk.error');
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

    test(
      'retriable errors are retried until the budget exhausts; '
      'final error surfaces',
      () async {
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

        expect(fakeLlm.calls, kMaxLlmRetries + 1,
            reason: 'must attempt exactly the initial + kMaxLlmRetries '
                'retries (6 total) before giving up');
        expect(_lastComplete, isNull,
            reason: 'no complete must fire when retries exhaust');
        expect(_lastError, isNotNull,
            reason: 'a final LlmError must be surfaced after retries '
                'exhaust; this is the bubble that carries the '
                '▶ retry (/continue) button');
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
            reason: 'status #${i + 1} should report the right attempt '
                'number',
          );
        }
      },
    );

    test(
      'successful first attempt is not retried, no retry status emitted',
      () async {
        final fakeLlm = FakeLlmClient([
          _successStream('hello'),
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

        expect(fakeLlm.calls, 1,
            reason: 'a clean first attempt must not trigger any retries');
        expect(_lastComplete, isNotNull);
        expect(_lastError, isNull);
        expect(_statusMessages, isEmpty,
            reason: 'successful path emits no retry status');
      },
    );

    test(
      'retry that fails on attempt $kMaxLlmRetries (last)'
      ' still loops to attempt ${kMaxLlmRetries + 1} '
      '(not aborted as a no-retry case)',
      () async {
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

        expect(fakeLlm.calls, kMaxLlmRetries + 1,
            reason: 'must attempt the full budget even when the last '
                'in-budget attempt fails');
        expect(_lastError, isNull);
        expect(_lastComplete, isNotNull);
        expect(fakeLlm.allText.toString(), 'finally');
      },
    );
  });
}

/// Construct a single-shot success stream: one text chunk and a stop chunk.
/// `finishReason: 'stop'` exits the agentic loop without tool calls.
List<LlmChunk> _successStream(String text) {
  return [
    LlmChunk(textDelta: text),
    LlmChunk(finishReason: 'stop'),
  ];
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

/// Silence "unused" warnings on the bundled providers dir constant — it
/// documents where built-in providers live but is not strictly needed for
/// this test (we point [ProviderService] at a temp dir).
// ignore: unused_element
final _ = _bundledProvidersDir;

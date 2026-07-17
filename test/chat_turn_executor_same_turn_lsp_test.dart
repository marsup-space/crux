// Tests for two P0 trust fixes in `ChatTurnExecutor`:
//
//  1. Same-turn LSP feedback. write/edit collect LSP diagnostics, but
//     they used to reach the model only on the NEXT turn (via the
//     persisted `<crux-lsp>` payload replayed from history). The tool
//     result sent to the API on the very turn the tool ran must now
//     carry a compact, error-only `<diagnostics>` block. Persistence
//     must keep embedding the full `<crux-lsp>` payload unchanged.
//
//  2. No-API-key error message. A session whose composite model key
//     lost its "provider/" prefix used to fail with the useless
//     `No API key for provider ""`. The error must now name the actual
//     provider (resolved from the model id) and give the next step.
//
// Harness mirrors `chat_turn_executor_retry_test.dart`: an in-memory
// store, a temp providers dir with a single `local.toml`, and an
// `LlmClient` subclass with scripted per-attempt streams.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/lsp/manager.dart';
import 'package:crux/src/lsp/protocol.dart';
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
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _providerName = 'local';
const String _modelId = 'test-model';

/// Scripted [LlmClient] that also snapshots the `messages` argument of
/// every call (shallow-copied per map) so tests can assert on what the
/// API would have received on a given attempt.
class _CapturingFakeLlmClient extends LlmClient {
  final List<List<LlmChunk>> responses;
  final List<List<Map<String, dynamic>>> capturedMessages = [];
  int calls = 0;

  _CapturingFakeLlmClient(this.responses);

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
    capturedMessages.add([
      for (final m in messages) Map<String, dynamic>.from(m),
    ]);
    final response = responses[calls];
    calls++;
    return Stream.fromIterable(response);
  }

  @override
  void dispose() {}
}

/// Returns a fixed diagnostic list without spawning any server.
class _FakeLspManager extends LspManager {
  _FakeLspManager(this._diagnostics)
    : super(workingDirectory: '', actorFactories: const {});

  final List<LspDiagnostic> _diagnostics;

  @override
  Future<List<LspDiagnostic>> touchFileAndWait(
    String filePath, {
    Duration timeout = const Duration(seconds: 5),
    LspAbortCheck? isCancelled,
  }) async => _diagnostics;
}

/// Fixed-key stub so the executor's "no API key → early return" check
/// passes (see `chat_turn_executor_retry_test.dart` for the pattern).
class _StubProviderService extends ProviderService {
  _StubProviderService({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => 'sk-test-not-used';
}

/// Never has an API key — drives the executor into the auth-failure
//  early return that this test group asserts on.
class _KeylessProviderService extends ProviderService {
  _KeylessProviderService({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => null;
}

Future<SessionStore> _freshStore() async {
  final db = CruxDatabase.forTesting(NativeDatabase.memory());
  final store = SessionStore(db);
  addTearDown(db.close);
  return store;
}

Future<String> _makeTempProvidersDir() async {
  final dir = await Directory.systemTemp.createTemp('crux_p0_prov_');
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

ChatTurnExecutor _buildExecutor({
  required SessionStore store,
  required ProviderService providerService,
  required LlmClient llmClient,
  LspManager? lsp,
}) {
  final toolRegistry = ToolRegistry()
    ..registerDefaults(
      FileReadTracker(),
      sessionStore: store,
      webProviderRegistry: WebProviderRegistry(),
      lsp: lsp,
    );
  return ChatTurnExecutor(
    store,
    providerService,
    llmClient,
    ToolExecutor(toolRegistry),
    SessionLeaseManager(),
  );
}

SessionRuntimeState _newRuntime(int sessionId) {
  final rt = SessionRuntimeState(sessionId: sessionId);
  rt.responseStartTime = DateTime.now();
  return rt;
}

void main() {
  late SessionStore store;

  setUp(() async {
    ChatTurnExecutor.debugBackoffOverride = (_) => Duration.zero;
    store = await _freshStore();
  });

  tearDown(() {
    ChatTurnExecutor.debugBackoffOverride = null;
  });

  group('same-turn LSP diagnostics in tool results', () {
    LspDiagnostic errorDiag(String message) => LspDiagnostic(
      range: const LspRange(LspPosition(0, 0), LspPosition(0, 5)),
      message: message,
      severity: LspDiagnosticSeverity.error,
      source: 'fake',
    );

    Future<({LlmError? error, _CapturingFakeLlmClient llm, Session session})>
    runWriteTurn(List<LspDiagnostic> diagnostics) async {
      final projectDir = await Directory.systemTemp.createTemp('crux_p0_ws_');
      addTearDown(() async {
        if (await projectDir.exists()) await projectDir.delete(recursive: true);
      });
      final providerService = _StubProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
      final fakeLlm = _CapturingFakeLlmClient([
        [
          LlmChunk(
            toolUse: ToolUseChunk(
              index: 0,
              callId: 'call_1',
              name: 'write',
              inputDelta: jsonEncode({
                'filePath': 'probe.dart',
                'content': 'void main() {}\n',
                'intent': 'probe',
              }),
            ),
          ),
          const LlmChunk(finishReason: 'tool_calls'),
        ],
        const [LlmChunk(textDelta: 'done'), LlmChunk(finishReason: 'stop')],
      ]);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
        lsp: _FakeLspManager(diagnostics),
      );
      final session = await store.create(
        title: 'same-turn-lsp',
        model: '$_providerName/$_modelId',
        projectPath: projectDir.path,
      );
      LlmError? error;
      await executor.sendMessage(
        sessionId: session.id,
        session: session,
        runtime: _newRuntime(session.id),
        onDelta: (_) {},
        onReasoning: (_) {},
        onChunk: () {},
        onComplete: (_) {},
        onError: (e) => error = e,
        userContent: 'hello',
      );
      return (error: error, llm: fakeLlm, session: session);
    }

    Map<String, dynamic> toolResultMessage(
      _CapturingFakeLlmClient llm,
      int attempt,
    ) {
      // The second streamChat call (index 1) carries the first round's
      // tool results at the tail of `messages`.
      final messages = llm.capturedMessages[attempt];
      return messages.lastWhere(
        (m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_1',
      );
    }

    test('error diagnostics are attached to the SAME-turn tool result, '
        'while persistence keeps the <crux-lsp> payload', () async {
      final r = await runWriteTurn([errorDiag('simulated analyzer error')]);

      expect(r.error, isNull);
      expect(r.llm.calls, 2);

      // ── Same turn: compact text block on the API-bound result ──
      final content = toolResultMessage(r.llm, 1)['content'] as String;
      expect(content, contains('<diagnostics file="probe.dart">'));
      expect(content, contains('ERROR [1:1] simulated analyzer error'));
      expect(
        content,
        isNot(contains('<crux-lsp>')),
        reason:
            'the JSON payload is a persistence-time artifact; the same '
            'turn only gets the compact text block',
      );

      // ── Persistence: full <crux-lsp> payload still embedded ────
      final persisted = await store.messageStore.getMessages(r.session.id);
      final toolRows = persisted.where((m) => m.role == 'tool').toList();
      expect(toolRows, hasLength(1));
      expect(toolRows.single.content, contains('<crux-lsp>'));
      expect(toolRows.single.content, contains('simulated analyzer error'));
    });

    test(
      'warning-only diagnostics leave the same-turn result untouched',
      () async {
        final r = await runWriteTurn([
          LspDiagnostic(
            range: const LspRange(LspPosition(0, 0), LspPosition(0, 5)),
            message: 'just a warning',
            severity: LspDiagnosticSeverity.warning,
          ),
        ]);

        expect(r.error, isNull);
        final content = toolResultMessage(r.llm, 1)['content'] as String;
        expect(content, isNot(contains('<diagnostics')));
        expect(content, startsWith('File written: probe.dart'));
      },
    );
  });

  group('no-API-key error message', () {
    Future<({LlmError? error, Session session})> runKeylessTurn(
      String sessionModel,
    ) async {
      final providerService = _KeylessProviderService(
        userProvidersDir: await _makeTempProvidersDir(),
      );
      await providerService.initialize();
      final fakeLlm = _CapturingFakeLlmClient(const []);
      final executor = _buildExecutor(
        store: store,
        providerService: providerService,
        llmClient: fakeLlm,
      );
      final session = await store.create(
        title: 'keyless',
        model: sessionModel,
        projectPath: Directory.systemTemp.path,
      );
      LlmError? error;
      await executor.sendMessage(
        sessionId: session.id,
        session: session,
        runtime: _newRuntime(session.id),
        onDelta: (_) {},
        onReasoning: (_) {},
        onChunk: () {},
        onComplete: (_) {},
        onError: (e) => error = e,
        userContent: 'hello',
      );
      return (error: error, session: session);
    }

    test('bare model id (no provider prefix) names the serving provider '
        'and the /provider next step', () async {
      final r = await runKeylessTurn(_modelId); // no "local/" prefix

      expect(r.error, isNotNull);
      expect(r.error!.kind, LlmErrorKind.auth);
      expect(
        r.error!.message,
        isNot(contains('provider ""')),
        reason: 'the empty-provider message was the bug being fixed',
      );
      expect(r.error!.message, contains('provider "$_providerName"'));
      expect(r.error!.message, contains('/provider $_providerName'));
      expect(r.session.status, SessionStatus.needUserAction);
    });

    test('known provider without a key names the provider and the '
        '/provider next step', () async {
      final r = await runKeylessTurn('$_providerName/$_modelId');

      expect(r.error, isNotNull);
      expect(r.error!.message, contains('provider "$_providerName"'));
      expect(r.error!.message, contains('/provider $_providerName'));
    });

    test('unknown provider prefix still names it in the message', () async {
      final r = await runKeylessTurn('ghost/$_modelId');

      expect(r.error, isNotNull);
      expect(r.error!.message, isNot(contains('provider ""')));
      expect(r.error!.message, contains('provider "ghost"'));
      expect(r.error!.message, contains('/provider ghost'));
    });

    test('bare unknown model id (no serving provider) falls back to '
        'naming the model id', () async {
      final r = await runKeylessTurn('nonexistent-model');

      expect(r.error, isNotNull);
      expect(r.error!.message, isNot(contains('provider ""')));
      expect(r.error!.message, contains('nonexistent-model'));
      expect(r.error!.message, contains('/provider'));
    });
  });
}

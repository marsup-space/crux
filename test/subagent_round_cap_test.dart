import 'dart:async';
import 'dart:io';

import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/subagent/subagent_prompts.dart';
import 'package:crux/src/services/subagent/subagent_runner.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/utils/subagent_meta.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Scripted [LlmClient]: the Nth `streamChat` call replays the Nth
/// scripted round. Records every request so tests can assert on the
/// final (stop-notice) exchange.
class _ScriptedClient extends LlmClient {
  _ScriptedClient(this.rounds);

  final List<List<LlmChunk>> rounds;
  final List<List<Map<String, dynamic>>> requests = [];
  final List<List<Map<String, dynamic>>?> requestTools = [];

  @override
  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required ProviderConfig config,
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
    final script = requests.length < rounds.length ? rounds[requests.length] : const <LlmChunk>[];
    requests.add(List.of(messages));
    requestTools.add(tools);
    return Stream.fromIterable(script);
  }
}

class _StubProviders extends ProviderService {
  _StubProviders({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => 'sk-test-not-used';

  @override
  ProviderConfig? providerByName(String name) => const ProviderConfig(
        name: 'test',
        type: 'openai',
        wireFamily: WireFamily.openaiCompatible,
        endpointUrl: 'http://localhost:9/v1',
        models: [],
      );
}

class _EchoTool extends ToolDef {
  @override
  String get name => 'echo';

  @override
  String get description => 'echo the args back (test stub)';

  @override
  Map<String, dynamic> get parametersSchema => const {};

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async =>
      const ToolResult(title: 'echo', output: 'ok');
}

const _toolRound = <LlmChunk>[
  LlmChunk(toolUse: ToolUseChunk(callId: 'c1', name: 'echo', index: 0, inputDelta: '{}')),
  LlmChunk(finishReason: 'tool_use'),
];

void main() {
  late Directory tmpDir;
  late _StubProviders providers;
  late CruxDatabase db;
  late AgentStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('subagent_cap_');
    providers = _StubProviders(userProvidersDir: tmpDir.path);
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = AgentStore(db);
  });

  tearDown(() async {
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  /// Drive a runner to completion with [client] as the LLM.
  Future<(String, String)> run({
    required _ScriptedClient client,
    int maxRounds = 2,
  }) async {
    final profile = await store.hire(
      role: SubagentRole.worker,
      model: 'test/smoke',
    );
    final done = Completer<(String, String)>();
    final runner = SubagentRunner(
      agentName: profile.name,
      profile: profile,
      role: SubagentRole.worker,
      intention: 'test cap',
      message: 'keep calling echo',
      providerService: providers,
      toolExecutor: ToolExecutor(ToolRegistry()..register(_EchoTool())),
      tools: [_EchoTool()],
      onDone: (status, report) => done.complete((status, report)),
      sessionId: 1,
      workingDirectory: tmpDir.path,
      clientOverride: client,
      maxRounds: maxRounds,
    );
    await runner.start();
    return done.future.timeout(const Duration(seconds: 5));
  }

  test('round cap interrupts and collects an interim report', () async {
    final client = _ScriptedClient([
      _toolRound, // round 1: echo
      _toolRound, // round 2: echo — budget now exhausted
      const [
        LlmChunk(textDelta: 'INTERIM: fixed the race, tests not run yet.'),
        LlmChunk(finishReason: 'stop'),
      ],
    ]);

    final result = await run(client: client);

    expect(result.$1, 'round_cap');
    expect(result.$2, contains('INTERIM: fixed the race'));
    // Exactly 3 LLM exchanges: 2 work rounds + 1 stop-notice reply.
    expect(client.requests.length, 3);
    // The final exchange carried NO tools and ended with the stop notice.
    expect(client.requestTools.last, isNull);
    final lastUser = client.requests.last.last;
    expect(lastUser['role'], 'user');
    expect((lastUser['content'] as String), contains('round limit reached'));
    expect((lastUser['content'] as String), contains('do NOT call any tool'));
  });

  test('degenerate stop-notice reply (tool call) falls back gracefully',
      () async {
    final client = _ScriptedClient([
      _toolRound,
      _toolRound,
      _toolRound, // model defies the ban — reply is a tool call
    ]);

    final result = await run(client: client);
    expect(result.$1, 'round_cap_no_report');
    expect(result.$2, contains('no interim report'));
  });

  test('stop notice demands interim report and forbids tools', () {
    final notice = kSubagentRoundCapStopNotice(40);
    expect(notice, contains('40-round limit'));
    expect(notice, contains('do NOT call any tool'));
    expect(notice, contains('INTERIM report'));
    expect(notice, contains('next dispatch should pick up'));
  });

  test('round_cap envelope is marked INTERIM and points at re-dispatch', () {
    final envelope = subagentReportEnvelope(
      agentName: 'orion',
      role: SubagentRole.worker,
      domain: 'token-refresh',
      intention: 'harden refresh',
      status: 'round_cap',
      report: 'Half done: fixed the race.',
    );
    expect(envelope, contains('status: round_cap'));
    expect(envelope, contains('INTERIM report'));
    expect(envelope, contains('INCOMPLETE'));
    expect(envelope, contains('re-dispatch with send_agent'));
    // The summary line must be the report body, not the note.
    expect(subagentReportSummary(envelope), 'Half done: fixed the race.');
  });

  test('completed envelope stays clean of interim markers', () {
    final envelope = subagentReportEnvelope(
      agentName: 'orion',
      role: SubagentRole.worker,
      domain: 'token-refresh',
      intention: 'harden refresh',
      status: 'completed',
      report: 'Done. Changed 2 files.',
    );
    expect(envelope, contains('status: completed'));
    expect(envelope, isNot(contains('INTERIM')));
    expect(envelope, isNot(contains('INCOMPLETE')));
  });
}

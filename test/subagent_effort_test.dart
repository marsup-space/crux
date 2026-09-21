import 'dart:async';
import 'dart:io';

import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/subagent/subagent_runner.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Per-agent reasoning effort (v38): the agents-table override reaches
/// the LLM wire request; `off` maps to thinkingMode disabled; null
/// (never set) keeps the pre-v38 wire shape (no effort, thinking on).
///
/// Reuses the round-cap test's harness shape: a scripted client that
/// records every streamChat call's named parameters.
class _ScriptedClient extends LlmClient {
  _ScriptedClient(this.rounds);

  final List<List<LlmChunk>> rounds;

  /// One record per streamChat call: (thinkingMode, reasoningEffort).
  final List<(String, String?)> efforts = [];

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
    efforts.add((thinkingMode, reasoningEffort));
    final script = efforts.length <= rounds.length
        ? rounds[efforts.length - 1]
        : const <LlmChunk>[];
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

class _NoopTool extends ToolDef {
  @override
  String get name => 'noop';

  @override
  String get description => 'noop (test stub)';

  @override
  Map<String, dynamic> get parametersSchema => const {};

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async => const ToolResult(title: 'noop', output: 'ok');
}

const _done = <LlmChunk>[
  LlmChunk(textDelta: 'Done.'),
  LlmChunk(finishReason: 'stop'),
];

void main() {
  late Directory tmpDir;
  late _StubProviders providers;
  late CruxDatabase db;
  late AgentStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('subagent_effort_');
    providers = _StubProviders(userProvidersDir: tmpDir.path);
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = AgentStore(db);
  });

  tearDown(() async {
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  Future<(String, String)> run({
    required _ScriptedClient client,
    required String? effort,
  }) async {
    final profile = await store.hire(
      role: SubagentRole.worker,
      model: 'test/smoke',
      projectPath: tmpDir.path,
    );
    if (effort != null) {
      await store.setReasoningEffort(tmpDir.path, profile.name, effort);
    }
    // Re-read so the run sees the persisted override (markBusy-style
    // flows re-read the profile the same way).
    final fresh = (await store.byName(tmpDir.path, profile.name))!;
    final done = Completer<(String, String)>();
    final runner = SubagentRunner(
      agentName: fresh.name,
      profile: fresh,
      role: SubagentRole.worker,
      intention: 'effort pass-through',
      message: 'answer immediately',
      providerService: providers,
      toolExecutor: ToolExecutor(ToolRegistry()..register(_NoopTool())),
      tools: const [],
      onDone: (status, report) => done.complete((status, report)),
      sessionId: 1,
      workingDirectory: tmpDir.path,
      clientOverride: client,
      maxRounds: 3,
    );
    unawaited(runner.start());
    return done.future.timeout(const Duration(seconds: 5));
  }

  test('null effort keeps the pre-v38 wire shape', () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client, effort: null);
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('enabled', null));
  });

  test('a set effort reaches every streamChat call', () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client, effort: 'high');
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('enabled', 'high'));
  });

  test("'off' maps to thinkingMode disabled", () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client, effort: 'off');
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('disabled', null));
  });

  test('setReasoningEffort persists and clears back to null', () async {
    final profile = await store.hire(
      role: SubagentRole.worker,
      model: 'test/smoke',
      projectPath: tmpDir.path,
    );
    await store.setReasoningEffort(tmpDir.path, profile.name, 'max');
    expect(
      (await store.byName(tmpDir.path, profile.name))!.reasoningEffort,
      'max',
    );
    await store.setReasoningEffort(tmpDir.path, profile.name, null);
    expect(
      (await store.byName(tmpDir.path, profile.name))!.reasoningEffort,
      isNull,
    );
  });
}

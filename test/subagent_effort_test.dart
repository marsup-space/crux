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

/// Pool-entry reasoning effort: the runner's `reasoningEffort`
/// constructor parameter reaches every LLM wire request (`off` maps to
/// thinkingMode disabled + no effort key; the manager resolves the
/// value from the dispatching pool entry, default `normal`).
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
    String effort = 'normal',
  }) async {
    final profile = await store.hire(
      role: SubagentRole.worker,
      model: 'test/smoke',
      projectPath: tmpDir.path,
    );
    final done = Completer<(String, String)>();
    final runner = SubagentRunner(
      agentName: profile.name,
      profile: profile,
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
      reasoningEffort: effort,
    );
    unawaited(runner.start());
    return done.future.timeout(const Duration(seconds: 5));
  }

  test('default effort is normal and reaches the wire', () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client);
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('enabled', 'normal'));
  });

  test('a set effort reaches every streamChat call', () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client, effort: 'high');
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('enabled', 'high'));
  });

  test("'off' maps to thinkingMode disabled and no effort key", () async {
    final client = _ScriptedClient([_done]);
    final result = await run(client: client, effort: 'off');
    expect(result.$1, 'completed');
    expect(client.efforts.first, ('disabled', null));
  });

  group('SubagentModelEntry effort round trip', () {
    test('parses reasoning_effort; absent → normal; unknown → normal', () {
      expect(
        SubagentModelEntry.fromJson({
          'model': 'zhipu/glm-5.3',
          'concurrency': 2,
          'reasoning_effort': 'high',
        })!.reasoningEffort,
        'high',
      );
      expect(
        SubagentModelEntry.fromJson({'model': 'zhipu/glm-5.3'})
            !
            .reasoningEffort,
        'normal',
      );
      expect(
        SubagentModelEntry.fromJson({
          'model': 'zhipu/glm-5.3',
          'reasoning_effort': 'ultra',
        })!.reasoningEffort,
        'normal',
      );
    });

    test('toJson emits reasoning_effort; equality covers it', () {
      final entry = SubagentModelEntry(
        model: 'zhipu/glm-5.3',
        reasoningEffort: 'max',
      );
      expect(entry.toJson()['reasoning_effort'], 'max');
      expect(
        SubagentModelEntry.fromJson(entry.toJson()),
        entry,
      );
      expect(
        SubagentModelEntry.fromJson(entry.toJson()),
        isNot(equals(entry.copyWith(reasoningEffort: 'low'))),
      );
    });
  });
}

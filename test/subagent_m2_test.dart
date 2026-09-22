import 'dart:async';
import 'dart:io';

import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/subagent/subagent_manager.dart';
import 'package:crux/src/services/subagent/subagent_prompts.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/subagent_tools.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// A [SubagentControllerLike] stub — the manager only reads switches
/// and pools, so tests wire a plain value object.
class _Toggles implements SubagentControllerLike {
  final bool workers;
  final bool experts;

  const _Toggles({this.workers = true, this.experts = true});

  @override
  bool get workersOn => workers;
  @override
  bool get expertsOn => experts;
  @override
  bool get anyOn => workers || experts;
  @override
  int? get roundLimit => 40;
  @override
  SubagentModelConfig poolFor(SubagentRole role) =>
      const SubagentConfig().forRole(role);
}

/// Thin [ProviderService] stub: no API-key persistence, no network.
class _StubProviderService extends ProviderService {
  _StubProviderService({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => 'sk-test-not-used';
}

void main() {
  late Directory tmpDir;
  late _StubProviderService providers;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('subagent_m2_');
    providers = _StubProviderService(userProvidersDir: tmpDir.path);
  });

  tearDown(() => tmpDir.delete(recursive: true));

  group('subagentPrompts', () {
    test('worker prompt carries identity, rules, assignment, memory', () {
      final prompt = subagentSystemPrompt(
        agentName: 'orion',
        role: SubagentRole.worker,
        domain: 'token-refresh',
        knowledge: 'refresh must single-flight',
        worklog: 'fixed the race twice',
        intention: 'harden refresh against 409s',
        userLanguage: '中文',
      );
      expect(prompt, contains('orion'));
      expect(prompt, contains('token-refresh'));
      expect(prompt, contains('harden refresh against 409s'));
      expect(prompt, contains('refresh must single-flight'));
      expect(prompt, contains('fixed the race twice'));
      expect(prompt, contains('REPORT'));
      expect(prompt, contains('Never spawn or message other subagents'));
    });

    test('expert prompt is read-only and cites file:line', () {
      final prompt = subagentSystemPrompt(
        agentName: 'libra',
        role: SubagentRole.expert,
        domain: 'auth',
        knowledge: '',
        worklog: '',
        intention: 'review the token flow',
        userLanguage: 'English',
      );
      expect(prompt, contains('READ-ONLY'));
      expect(prompt, contains('file:line'));
      expect(prompt, contains('status update'));
    });

    test('report envelope shape: system-note prefix, never user speech', () {
      final envelope = subagentReportEnvelope(
        agentName: 'orion',
        role: SubagentRole.worker,
        domain: 'token-refresh',
        intention: 'harden refresh',
        status: 'completed',
        report: 'Done. Changed 2 files.',
      );
      expect(
        envelope.startsWith('[Crux system note — subagent report]'),
        isTrue,
      );
      expect(envelope, contains('from: agent://orion (worker,'));
      expect(envelope, contains('status: completed'));
      expect(envelope, contains('  Done. Changed 2 files.'));
      expect(envelope, contains('agent://orion is ready'));
    });
  });

  group('SubagentManager dispatch semantics', () {
    late CruxDatabase db;
    late AgentStore store;

    setUp(() {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = AgentStore(db);
      addTearDown(() => db.close());
    });

    SubagentManager managerWith(
      _Toggles toggles, {
      void Function(String envelope, Agent agent, String status)?
      onReportEnvelope,
    }) => SubagentManager(
      store: store,
      providerService: providers,
      toolExecutor: ToolExecutor(ToolRegistry()),
      toolRegistry: ToolRegistry(),
      toggles: toggles,
      workingDirectory: Directory.current.path,
      onReportEnvelope: onReportEnvelope,
    );

    test('send to unknown agent names the mistake', () async {
      final manager = managerWith(const _Toggles());
      final result = await manager.send(
        agentName: 'orion',
        intention: 'do',
        message: 'work',
        sessionId: 1,
      );
      expect(result, contains('Unknown agent'));
      expect(result, contains('find_agents'));
    });

    test('manager gates hire and send by the requested agent role', () async {
      final workersOnly = managerWith(const _Toggles(experts: false));
      final expertHire = await workersOnly.hire(
        role: SubagentRole.expert,
        domain: 'd',
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(expertHire, contains('Experts is currently OFF'));
      expect(expertHire, contains('/subagent experts on'));

      final expertsOnly = managerWith(const _Toggles(workers: false));
      final workerHire = await expertsOnly.hire(
        role: SubagentRole.worker,
        domain: 'd',
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(workerHire, contains('Workers is currently OFF'));
      expect(workerHire, contains('/subagent workers on'));

      final expert = await store.hire(
        projectPath: Directory.current.path,
        role: SubagentRole.expert,
        model: 'missing/provider',
        domain: 'review',
      );
      final expertSend = await workersOnly.send(
        agentName: expert.name,
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(expertSend, contains('Experts is currently OFF'));
    });

    test('both role switches allow manager dispatch paths', () async {
      final manager = managerWith(const _Toggles());
      final hire = await manager.hire(
        role: SubagentRole.expert,
        domain: 'd',
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(hire, isNot(contains('currently OFF')));

      final expert = await store.hire(
        projectPath: Directory.current.path,
        role: SubagentRole.expert,
        model: 'missing/provider',
        domain: 'review',
      );
      final send = await manager.send(
        agentName: expert.name,
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(send, startsWith('Dispatched agent://'));
    });

    test('hire refuses when the pool is empty', () async {
      final manager = managerWith(const _Toggles());
      final result = await manager.hire(
        role: SubagentRole.worker,
        domain: 'd',
        intention: 'i',
        message: 'm',
        sessionId: 1,
      );
      expect(result, contains('No model available'));
      expect(result, contains('config.toml'));
    });

    test(
      'completed report retains the dispatching session after markReady',
      () async {
        final scope = Directory.current.path;
        final hired = await store.hire(
          projectPath: scope,
          role: SubagentRole.worker,
          model: 'missing/provider',
          domain: 'report routing',
        );
        final reportAgent = Completer<Agent>();
        final manager = managerWith(
          const _Toggles(),
          onReportEnvelope: (_, agent, _) => reportAgent.complete(agent),
        );

        // This is the session that dispatched the run. A UI host may now be
        // viewing another session, so the callback must not lose this stamp.
        await manager.send(
          agentName: hired.name,
          intention: 'report to session A',
          message: 'go',
          sessionId: 41,
        );

        expect(
          (await reportAgent.future.timeout(const Duration(seconds: 1)))
              .runOwnerSessionId,
          41,
        );
        // The durable row correctly becomes ready and clears its owner; only
        // the completion callback receives the owner-preserving snapshot.
        expect(
          (await store.byName(scope, hired.name))!.runOwnerSessionId,
          isNull,
        );
      },
    );

    test('check on a ready agent returns the roster summary', () async {
      final scope = Directory.current.path;
      final hired = await store.hire(
        projectPath: scope,
        role: SubagentRole.expert,
        model: 'zhipu/glm-5.3',
        domain: 'auth',
      );
      await store.markBusy(
        scope,
        hired.name,
        sessionId: 1,
        intention: 'first look',
      );
      await store.markReady(scope, hired.name);

      final manager = managerWith(const _Toggles());
      final result = await manager.check(hired.name);
      expect(result, contains('agent://${hired.name}'));
      expect(result, contains('ready'));
      expect(result, contains('auth'));
      expect(result, contains('first look'));
    });

    test('cancel without a live run clears the queue politely', () async {
      final manager = managerWith(const _Toggles());
      final result = await manager.cancel('orion');
      expect(result, contains('no live run'));
    });
  });

  group('subagent tools: mode gate and agent:// parsing', () {
    late CruxDatabase db;
    late AgentStore store;
    late _Toggles off;
    late _Toggles on;

    setUp(() {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = AgentStore(db);
      addTearDown(() => db.close());
      off = const _Toggles(workers: false, experts: false);
      on = const _Toggles();
    });

    ToolContext ctx() => ToolContext(
      sessionId: 1,
      messageId: 0,
      abort: AbortSignal(),
      workingDirectory: Directory.current.path,
    );

    test('all five tools redirect when mode is off', () async {
      final manager = SubagentManager(
        store: store,
        providerService: providers,
        toolExecutor: ToolExecutor(ToolRegistry()),
        toolRegistry: ToolRegistry(),
        toggles: off,
        workingDirectory: Directory.current.path,
      );
      final tools = [
        FindAgentsTool(manager: manager, toggles: off),
        HireAgentTool(manager: manager, toggles: off),
        SendAgentTool(manager: manager, toggles: off),
        CheckAgentTool(manager: manager, toggles: off),
        CancelAgentTool(manager: manager, toggles: off),
      ];
      for (final tool in tools) {
        final args = tool is FindAgentsTool
            ? <String, dynamic>{}
            : tool is HireAgentTool
            ? {
                'role': 'worker',
                'domain': 'd',
                'intention': 'i',
                'message': 'm',
              }
            : {'agent': 'agent://orion'};
        final result = await tool.execute(args, ctx());
        expect(result.output, contains('OFF'), reason: tool.name);
        expect(result.output, contains('/subagent'), reason: tool.name);
      }
    });

    test('hire and send gate dispatches by agent role', () async {
      final workersOnly = const _Toggles(experts: false);
      final expertsOnly = const _Toggles(workers: false);
      SubagentManager managerFor(_Toggles toggles) => SubagentManager(
        store: store,
        providerService: providers,
        toolExecutor: ToolExecutor(ToolRegistry()),
        toolRegistry: ToolRegistry(),
        toggles: toggles,
        workingDirectory: Directory.current.path,
      );

      final expertHire =
          await HireAgentTool(
            manager: managerFor(workersOnly),
            toggles: workersOnly,
          ).execute({
            'role': 'expert',
            'domain': 'review',
            'intention': 'i',
            'message': 'm',
          }, ctx());
      expect(expertHire.output, contains('Experts is currently OFF'));
      expect(expertHire.output, contains('/subagent experts on'));

      final workerHire =
          await HireAgentTool(
            manager: managerFor(expertsOnly),
            toggles: expertsOnly,
          ).execute({
            'role': 'worker',
            'domain': 'implementation',
            'intention': 'i',
            'message': 'm',
          }, ctx());
      expect(workerHire.output, contains('Workers is currently OFF'));
      expect(workerHire.output, contains('/subagent workers on'));

      final expert = await store.hire(
        projectPath: Directory.current.path,
        role: SubagentRole.expert,
        model: 'missing/provider',
        domain: 'review',
      );
      final expertSend =
          await SendAgentTool(
            manager: managerFor(workersOnly),
            toggles: workersOnly,
          ).execute({
            'agent': 'agent://${expert.name}',
            'intention': 'i',
            'message': 'm',
          }, ctx());
      expect(expertSend.output, contains('Experts is currently OFF'));

      final bothOn = const _Toggles();
      final allowedHire =
          await HireAgentTool(
            manager: managerFor(bothOn),
            toggles: bothOn,
          ).execute({
            'role': 'expert',
            'domain': 'review',
            'intention': 'i',
            'message': 'm',
          }, ctx());
      expect(allowedHire.output, isNot(contains('currently OFF')));
      final allowedSend =
          await SendAgentTool(
            manager: managerFor(bothOn),
            toggles: bothOn,
          ).execute({
            'agent': 'agent://${expert.name}',
            'intention': 'i',
            'message': 'm',
          }, ctx());
      expect(allowedSend.output, isNot(contains('currently OFF')));
    });

    test('send stamps agentBubble metadata with the parsed name', () async {
      final manager = SubagentManager(
        store: store,
        providerService: providers,
        toolExecutor: ToolExecutor(ToolRegistry()),
        toolRegistry: ToolRegistry(),
        toggles: on,
        workingDirectory: Directory.current.path,
      );
      final tool = SendAgentTool(manager: manager, toggles: on);
      final result = await tool.execute({
        'agent': 'agent://ORION',
        'intention': 'wire the bubble',
        'message': 'go',
      }, ctx());
      expect(result.metadata, contains('agentBubble'));
      final bubble = result.metadata['agentBubble'] as Map<String, dynamic>;
      expect(bubble['agentName'], 'orion');
      expect(bubble['dir'], 'to');
      expect(bubble['kind'], 'send');
    });

    test('find_agents lists the roster with role glyphs', () async {
      final scope = Directory.current.path;
      await store.hire(
        projectPath: scope,
        role: SubagentRole.worker,
        model: 'a/b',
        domain: 'db',
      );
      await store.hire(
        projectPath: scope,
        role: SubagentRole.expert,
        model: 'a/b',
        domain: 'auth',
      );
      final manager = SubagentManager(
        store: store,
        providerService: providers,
        toolExecutor: ToolExecutor(ToolRegistry()),
        toolRegistry: ToolRegistry(),
        toggles: on,
        workingDirectory: Directory.current.path,
      );
      final tool = FindAgentsTool(manager: manager, toggles: on);
      final result = await tool.execute({}, ctx());
      expect(result.output, contains('✎worker'));
      expect(result.output, contains('✦expert'));
      expect(result.output, contains('ready'));
      // Non-empty roster: the tail teaches queue/fork, not hire.
      expect(result.output, contains('send_agent'));
    });
  });
}

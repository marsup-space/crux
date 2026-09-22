import '../models/subagent.dart';
import '../services/subagent/subagent_manager.dart';
import '../storage/database.dart' as db;
import '../utils/fuzzy_match.dart' show scoreStringMatch;
import '../utils/subagent_meta.dart';
import 'tool_def.dart';

/// Shared plumbing for the five subagent tools: manager access,
/// mode-off redirect, agentBubble metadata stamping, and the
/// `agent://name` argument parser.
///
/// Per the plan's "模式切换与 cache" section, all five tools are
/// statically registered — when subagent mode is off, calls return a
/// redirect message instead of failing, so the tool list (and the
/// prompt cache) never changes at runtime.
abstract class SubagentToolBase extends ToolDef {
  final SubagentManager manager;
  final SubagentControllerLike toggles;

  SubagentToolBase({required this.manager, required this.toggles});

  /// Common gate: a disabled mode redirects the main agent instead of
  /// executing. `any` is for roster reads/management; role names select the
  /// corresponding dispatch switch.
  ToolResult? gate(String neededSwitch) {
    final enabled = switch (neededSwitch) {
      'worker' => toggles.workersOn,
      'expert' => toggles.expertsOn,
      _ => toggles.anyOn,
    };
    if (enabled) return null;

    final command = switch (neededSwitch) {
      'worker' => '/subagent workers on',
      'expert' => '/subagent experts on',
      _ => '/subagent (e.g. "/subagent workers on")',
    };
    final label = switch (neededSwitch) {
      'worker' => 'Workers',
      'expert' => 'Experts',
      _ => 'Subagent mode',
    };
    return ToolResult(
      title: 'subagent mode off',
      output:
          '$label is currently OFF. Tell the user to enable it with '
          '$command and re-ask.',
      metadata: const {},
    );
  }

  /// Parse `agent://orion` or bare `orion` into the roster name.
  String normalizeAgent(String raw) {
    var name = raw.trim();
    if (name.startsWith('agent://')) name = name.substring('agent://'.length);
    return name.toLowerCase();
  }

  /// Stamp agentBubble metadata for the chat-history renderers.
  Map<String, dynamic> bubble({
    required AgentBubbleDirection direction,
    required String agentName,
    required String kind,
    String message = '',
  }) => agentBubbleMetadata(
    direction: direction,
    agentId: agentName,
    agentName: agentName,
    kind: kind,
    message: message,
  );
}

/// find_agents(query?, role?) — the roster lookup.
///
/// Returns busy + ready by default (finding "who knows this domain"
/// is orthogonal to liveness); matches name + domain + current/last
/// intention via the shared six-tier fuzzy matcher.
class FindAgentsTool extends SubagentToolBase {
  FindAgentsTool({required super.manager, required super.toggles});

  @override
  String get name => 'find_agents';

  @override
  String get description =>
      'Find subagents on the roster. Returns EVERY agent (busy and ready) '
      'by default — you are looking for who knows a domain, not who is '
      'free. The roster is scoped to this workspace: agents hired in '
      'other projects are not visible (and do not occupy names here). '
      'Optionally filter by role. `query` fuzzy-matches name, '
      'domain, and the current/last task intention. Each row shows: '
      'name (agent://<id>), role (worker ✎ / expert ✦), domain, model, '
      'status, and the current (busy) or last (ready) intention. '
      'Use this before send_agent to pick the right agent. '
      'If nobody owns the task\'s specific domain, hire a fresh specialist '
      'rather than reusing an unrelated agent.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'Fuzzy-match against name + domain + intention. '
            'Empty returns the whole roster.',
      },
      'role': {
        'type': 'string',
        'enum': ['all', 'workers', 'experts'],
        'description': 'Filter by role. Default all.',
      },
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final gateResult = gate('any');
    if (gateResult != null) return gateResult;

    final query = (args['query'] as String?)?.trim() ?? '';
    final role = (args['role'] as String?) ?? 'all';

    final all = await manager.store.listAll(manager.projectPath);
    final filtered = [
      for (final agent in all)
        if (role == 'all' ||
            (role == 'workers' && agent.role == 'worker') ||
            (role == 'experts' && agent.role == 'expert'))
          agent,
    ];

    final matched = query.isEmpty
        ? filtered
        : [
            for (final agent in filtered)
              if (_matches(agent, query)) agent,
          ];

    if (matched.isEmpty) {
      return ToolResult(
        title: 'find_agents',
        output: matched.isEmpty && all.isEmpty
            ? 'The roster is empty. hire_agent creates the first agent '
                  '(a fresh name from the constellation pool) and dispatches '
                  'its first task in one step.'
            : 'No agent matches "$query". hire_agent can create one for '
                  'this domain.',
      );
    }

    final buffer = StringBuffer(
      'Roster (${matched.length} agent'
      '${matched.length == 1 ? '' : 's'}):\n',
    );
    for (final agent in matched) {
      final busy = manager.isBusy(agent.name);
      final glyph = agent.role == 'expert' ? '✦' : '✎';
      final intention = agent.lastIntention.isEmpty
          ? '(no intention recorded)'
          : agent.lastIntention;
      buffer.writeln(
        'agent://${agent.name} $glyph${agent.role} · ${agent.domain} · '
        '${agent.model} · ${busy ? 'busy' : 'ready'} · '
        '${busy ? 'current' : 'last'}: $intention',
      );
    }
    buffer.writeln(
      '\nbusy agents still receive send_agent (queued) — or fork with '
      'ifBusy: "fork".',
    );
    return ToolResult(title: 'find_agents', output: buffer.toString());
  }

  bool _matches(db.Agent agent, String query) {
    final q = query.toLowerCase();
    for (final candidate in [agent.name, agent.domain, agent.lastIntention]) {
      if (scoreStringMatch(q, candidate.toLowerCase()) > 0) return true;
    }
    return false;
  }
}

/// hire_agent(role, domain, intention, message) — create + dispatch.
class HireAgentTool extends SubagentToolBase {
  HireAgentTool({required super.manager, required super.toggles});

  @override
  String get name => 'hire_agent';

  @override
  String get description =>
      'Create a NEW subagent and immediately dispatch its first task. '
      'The name is allocated from the constellation pool (workers get '
      'IAU constellations, experts get zodiac signs). The model is picked '
      'from the role\'s configured pool (weighted randomly among entries '
      'with free concurrency and budget) and bound to the agent for its '
      'lifetime. '
      'Use when find_agents shows nobody owns the domain. '
      'Prefer narrow, specific domains ("token-refresh", not "general") — a '
      'fresh specialist beats reusing an unrelated agent.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'role': {
        'type': 'string',
        'enum': ['worker', 'expert'],
        'description':
            'worker: read-write, does hands-on work. '
            'expert: read-only, gives opinions.',
      },
      'domain': {
        'type': 'string',
        'description':
            'Short, SPECIFIC domain label, e.g. '
            '"token-refresh", "release-pipeline", "home-rendering". '
            'Avoid broad labels like "general" — narrow domains keep the '
            'agent\'s distilled context focused. Use the user\'s language '
            'for the label — it is shown in the user\'s UI.',
      },
      'intention': {
        'type': 'string',
        'description':
            'One line: what this dispatch is FOR. Shown in '
            'the UI and preserved in the agent\'s work record.',
      },
      'message': {
        'type': 'string',
        'description':
            'The first task. Include the report granularity '
            'you want (one-line conclusion vs detailed report).',
      },
    },
    'required': ['role', 'domain', 'intention', 'message'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final roleArg = (args['role'] as String?)?.toLowerCase() ?? 'worker';
    final role = roleArg == 'expert'
        ? SubagentRole.expert
        : SubagentRole.worker;
    final gateResult = gate(role.name);
    if (gateResult != null) return gateResult;
    final domain = (args['domain'] as String?)?.trim() ?? '';
    final intention = (args['intention'] as String?)?.trim() ?? '';
    final message = (args['message'] as String?)?.trim() ?? '';
    if (domain.isEmpty) {
      return ToolResult.error(
        'domain is required — pick a narrow, specific label like '
        '"token-refresh".',
      );
    }
    if (intention.isEmpty || message.isEmpty) {
      return ToolResult.error(
        'intention and message are both required (intention drives the UI '
        'tooltip and the post-compaction work record).',
      );
    }

    final result = await manager.hire(
      role: role,
      domain: domain,
      intention: intention,
      message: message,
      sessionId: ctx.sessionId,
    );

    // The hired name rides the result line: "Hired agent://orion ...".
    final hiredName = RegExp(r'agent://([a-z-]+)').firstMatch(result)?.group(1);

    return ToolResult(
      title: 'hire_agent',
      output: result,
      metadata: hiredName == null
          ? const {}
          : bubble(
              direction: AgentBubbleDirection.toAgent,
              agentName: hiredName,
              kind: 'spawn',
              message: intention,
            ),
    );
  }
}

/// send_agent(agent, intention, message, ifBusy?) — the single action
/// entry: ready → the message becomes the task; busy → queue (default)
/// or fork.
class SendAgentTool extends SubagentToolBase {
  SendAgentTool({required super.manager, required super.toggles});

  @override
  String get name => 'send_agent';

  @override
  String get description =>
      'Send a task or follow-up message to a subagent. When the agent is '
      'READY the message becomes its next assignment and the run starts '
      'immediately. When BUSY: ifBusy "queue" (default) appends to its '
      'queue and it is delivered when the current run ends; ifBusy "fork" '
      'copies the agent\'s profile (domain knowledge, work record) to a '
      'fresh name and dispatches there — use fork when it cannot wait. '
      'The call returns immediately; the agent reports back on its own '
      '(you are never blocked). intention is required — one line for the '
      'UI and the agent\'s work record.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'agent': {
        'type': 'string',
        'description': 'The agent to message: agent://orion or orion.',
      },
      'intention': {
        'type': 'string',
        'description': 'One line: what this dispatch is FOR.',
      },
      'message': {
        'type': 'string',
        'description':
            'Task / follow-up content. State the report '
            'granularity you want.',
      },
      'ifBusy': {
        'type': 'string',
        'enum': ['queue', 'fork'],
        'description':
            'What to do when the agent is busy. Default '
            'queue.',
      },
    },
    'required': ['agent', 'intention', 'message'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final gateResult = gate('any');
    if (gateResult != null) return gateResult;

    final agent = normalizeAgent((args['agent'] as String?) ?? '');
    final intention = (args['intention'] as String?)?.trim() ?? '';
    final message = (args['message'] as String?)?.trim() ?? '';
    final ifBusy = (args['ifBusy'] as String?) ?? 'queue';
    if (agent.isEmpty || intention.isEmpty || message.isEmpty) {
      return ToolResult.error(
        'agent, intention, and message are all required.',
      );
    }
    // Preserve manager.send's unknown-agent response before role gating.
    final profile = await manager.store.byName(manager.projectPath, agent);
    if (profile != null) {
      final gateResult = gate(profile.role == 'expert' ? 'expert' : 'worker');
      if (gateResult != null) return gateResult;
    }

    final result = await manager.send(
      agentName: agent,
      intention: intention,
      message: message,
      ifBusy: ifBusy,
      sessionId: ctx.sessionId,
    );

    return ToolResult(
      title: 'send_agent',
      output: result,
      metadata: bubble(
        direction: AgentBubbleDirection.toAgent,
        agentName: agent,
        kind: 'send',
        message: intention,
      ),
    );
  }
}

/// check_agent(agent) — snapshot status probe.
class CheckAgentTool extends SubagentToolBase {
  CheckAgentTool({required super.manager, required super.toggles});

  @override
  String get name => 'check_agent';

  @override
  String get description =>
      'Check how a subagent is doing. For a BUSY agent returns the live '
      'snapshot: current round, last tool call. For a READY agent returns '
      'the roster summary (domain, model, last intention) — no LLM call. '
      'Use when the user asks "how far along is X" or before deciding to '
      'wait (queue) or fork.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'agent': {
        'type': 'string',
        'description': 'The agent to check: agent://orion or orion.',
      },
    },
    'required': ['agent'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final gateResult = gate('any');
    if (gateResult != null) return gateResult;

    final agent = normalizeAgent((args['agent'] as String?) ?? '');
    if (agent.isEmpty) return ToolResult.error('agent is required.');

    final result = await manager.check(agent);
    return ToolResult(
      title: 'check_agent',
      output: result,
      metadata: bubble(
        direction: AgentBubbleDirection.fromAgent,
        agentName: agent,
        kind: 'read',
      ),
    );
  }
}

/// cancel_agent(agent, reason?) — the brake.
class CancelAgentTool extends SubagentToolBase {
  CancelAgentTool({required super.manager, required super.toggles});

  @override
  String get name => 'cancel_agent';

  @override
  String get description =>
      'Cancel a subagent\'s live run: interrupts it, drops its queued '
      'messages, and returns it to ready (the profile is kept). Use when '
      'a dispatch was wrong or a worker went off track. The reason, if '
      'given, is recorded.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'agent': {
        'type': 'string',
        'description': 'The agent to cancel: agent://orion or orion.',
      },
      'reason': {
        'type': 'string',
        'description': 'Why — recorded on the agent.',
      },
    },
    'required': ['agent'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final gateResult = gate('any');
    if (gateResult != null) return gateResult;

    final agent = normalizeAgent((args['agent'] as String?) ?? '');
    if (agent.isEmpty) return ToolResult.error('agent is required.');
    final reason = (args['reason'] as String?)?.trim();

    final result = await manager.cancel(agent, reason: reason);
    return ToolResult(
      title: 'cancel_agent',
      output: result,
      metadata: bubble(
        direction: AgentBubbleDirection.toAgent,
        agentName: agent,
        kind: 'cancel',
        message: reason ?? '',
      ),
    );
  }
}

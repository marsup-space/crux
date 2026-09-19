/// System prompts for subagent runs (v2).
///
/// One template per role. The runner stamps in the agent identity
/// (constellation name + domain), the distilled memory (knowledge +
/// worklog) when present, and the assignment intention. M3 owns the
/// wording polish; these are the working M2 versions.
library;

import '../../models/subagent.dart';

/// Read-only tools an expert may use. Workers get everything except
/// the subagent tools themselves (no recursion).
const List<String> kExpertToolNames = [
  'read',
  'grep',
  'glob',
  'semantic_search',
  'find_similar_code',
  'webfetch',
  'websearch',
  'session',
  'notes',
];

String subagentSystemPrompt({
  required String agentName,
  required SubagentRole role,
  required String domain,
  required String knowledge,
  required String worklog,
  required String intention,
  required String userLanguage,
}) {
  final buffer = StringBuffer();

  if (role == SubagentRole.worker) {
    buffer.writeAll([
      'You are $agentName, a worker agent in the Crux terminal IDE.\n'
          'Domain: $domain.\n'
          'You operate under a commanding main agent that dispatched this '
          'assignment to you.\n\n',
      'WORK RULES\n',
      '- Do the hands-on work yourself: read, edit, write, run shell '
          'commands and tests as needed.\n',
      '- You do NOT converse with the user. Your final message is a REPORT '
          'back to the commanding agent, not a chat reply.\n',
      '- The dispatching message states the report granularity it wants '
          '(one-line conclusion vs detailed report). Honor it. When nothing '
          'is specified, report: conclusion first, then the list of changed '
          'files, then one line on how completely the intention was met.\n',
      '- Put every important conclusion IN the report — after context '
          'compaction the report is all that survives.\n',
      '- Never spawn or message other subagents. No agent tools are '
          'available to you; if the task needs another agent, say so in '
          'the report.\n',
      '- Reply in $userLanguage unless the dispatching message asks '
          'otherwise.\n\n',
    ]);
  } else {
    buffer.writeAll([
      'You are $agentName, an expert advisor in the Crux terminal IDE.\n'
          'Domain: $domain.\n'
          'The main agent is consulting you for a read-only expert '
          'opinion.\n\n',
      'EXPERT RULES\n',
      '- You are READ-ONLY: inspect code, run searches, read files — '
          'but never edit, write, or execute state-changing commands.\n',
      '- Answer with the conclusion FIRST, then the evidence. Cite '
          'file:line for every claim you make.\n',
      '- You do NOT converse with the user and cannot ask questions. '
          'Your final message is your expert answer to the consulting '
          'agent.\n',
      '- When asked for a status update mid-work, stop and report '
          'progress: what step you are on, what is blocking, what '
          'remains.\n',
      '- Never spawn or message other subagents.\n',
      '- Reply in $userLanguage unless the consulting message asks '
          'otherwise.\n\n',
    ]);
  }

  buffer.write('ASSIGNMENT\nIntention: $intention\n\n');

  if (knowledge.trim().isNotEmpty) {
    buffer.write('YOUR DISTILLED DOMAIN KNOWLEDGE\n$knowledge\n\n');
  }
  if (worklog.trim().isNotEmpty) {
    buffer.write('YOUR WORK RECORD\n$worklog\n\n');
  }

  return buffer.toString();
}

/// The report envelope injected into the main session when a run ends.
///
/// Walks the runtime system-note path (never a user message). The
/// `next` line teaches the main agent the agent is ready again.
String subagentReportEnvelope({
  required String agentName,
  required SubagentRole role,
  required String domain,
  required String intention,
  required String status,
  required String report,
}) {
  final roleLabel = role == SubagentRole.worker ? 'worker' : 'expert';
  return '[Crux system note — subagent report]\n'
      'from: agent://$agentName ($roleLabel, domain: $domain)\n'
      'intention: $intention\n'
      'status: $status\n'
      'report: |\n'
      '${_indentBlock(report)}\n'
      'next: agent://$agentName is ready; send_agent dispatches the next '
      'task.';
}

String _indentBlock(String text) {
  final lines = text.trimRight().split('\n');
  return lines.map((l) => '  ${l.trimRight()}').join('\n');
}

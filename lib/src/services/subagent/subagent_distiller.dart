import 'dart:convert';

import '../../utils/token_estimate.dart';

/// The three distillation products (plan §上下文与蒸馏 item 2).
class DistillationProducts {
  /// Domain knowledge: what was learned in this domain.
  final String knowledge;

  /// Work record: what was done, with what outcome.
  final String worklog;

  /// Continuation instruction: where the task stands, what is next.
  /// Fed straight back to the agent to resume the SAME assignment
  /// on a clean `knowledge + worklog + instruction` context.
  final String instruction;

  const DistillationProducts({
    required this.knowledge,
    required this.worklog,
    required this.instruction,
  });

  bool get isValid =>
      knowledge.trim().isNotEmpty &&
      worklog.trim().isNotEmpty &&
      instruction.trim().isNotEmpty;
}

/// The distillation engine — the shared "summarize, don't compress"
/// continuation mechanism (plan §上下文与蒸馏).
///
/// One implementation serves BOTH subagent runs and the main agent
/// (plan: "subagent 与主 agent 共用一套蒸馏实现"). It is a pure
/// request builder + response parser around a single LLM call; the
/// caller supplies the transport (subagent runner streams it inline;
/// the main-agent path can route it through its own client).
///
/// Three-stage contract (the caller counts context-full events):
///   1st & 2nd full → ordinary crux compact (NOT this module).
///   3rd full       → distill via this module, then resume the same
///                    assignment from `knowledge + worklog +
///                    instruction` (never wait for the next dispatch).
class SubagentDistiller {
  /// Prompt head: the distillation task framed for the model that
  /// just hit its third context-full event mid-assignment.
  static const _taskHead = '''
You have hit the context limit for the third time while working on an
assignment. Instead of compressing the conversation again, distill it.

Produce EXACTLY three sections in your reply, each starting with its
marker on its own line:

===KNOWLEDGE===
Durable domain knowledge you learned during this work: facts about the
codebase, invariants, APIs, pitfalls. Written so a fresh instance of
you could act on it. No narrative, just the knowledge.

===WORKLOG===
What you did so far on THIS assignment, with outcomes: commands run
and their results, files changed and why, decisions made and their
reasons. Past tense, chronological, terse.

===INSTRUCTION===
A continuation instruction for yourself: exactly where the task stands,
what remains to reach the stated intention, and the next concrete
action. Imperative, addressed to "you". This is the ONLY part of the
context your next run starts with (plus knowledge and worklog), so it
must carry everything needed to continue seamlessly.
''';

  /// Build the distillation request messages: the system identity is
  /// dropped (the products must be agent-agnostic), the assignment
  /// framing is kept, and the full history rides along one last time.
  static List<Map<String, dynamic>> buildRequest({
    required String agentName,
    required String domain,
    required String intention,
    required List<Map<String, dynamic>> history,
    int? contextCapacity,
  }) {
    return [
      {
        'role': 'system',
        'content':
            'You are the distillation pass for $agentName, a '
            'subagent in domain "$domain", mid-assignment '
            '"$intention".\n$_taskHead',
      },
      ...history,
    ];
  }

  /// Parse the model's reply into the three products. Tolerant of
  /// leading prose before the first marker; missing sections come
  /// back empty (the caller treats an invalid result as a failed
  /// distillation and falls back to a hard truncation report).
  static DistillationProducts parse(String reply) {
    final knowledge = _section(reply, '===KNOWLEDGE===', '===WORKLOG===');
    final worklog = _section(reply, '===WORKLOG===', '===INSTRUCTION===');
    final instruction = _tail(reply, '===INSTRUCTION===');
    return DistillationProducts(
      knowledge: knowledge,
      worklog: worklog,
      instruction: instruction,
    );
  }

  static String _section(String text, String start, String end) {
    final s = text.indexOf(start);
    if (s < 0) return '';
    final body = text.substring(s + start.length);
    final e = body.indexOf(end);
    return (e < 0 ? body : body.substring(0, e)).trim();
  }

  static String _tail(String text, String start) {
    final s = text.indexOf(start);
    if (s < 0) return '';
    return text.substring(s + start.length).trim();
  }
}

/// Token-estimate helpers for the three-stage gate. The caller feeds
/// these a serialized history; both subagent and main-agent callers
/// build their history the same wire way.
extension DistillationHistoryTokens on List<Map<String, dynamic>> {
  /// Rough token estimate of this history (chars/4), matching the
  /// app-wide estimator.
  int get estimatedTokens {
    var total = 0;
    for (final message in this) {
      total += estimateTokens(message['content']?.toString() ?? '');
    }
    return total;
  }
}

/// The three-stage decision for one context-full event.
enum DistillationStage {
  /// 1st or 2nd full → ordinary compact, keep working.
  compact,

  /// 3rd full → distill and resume.
  distill,
}

/// Pure three-stage gate: given how many context-full events this
/// run has already absorbed (BEFORE this one), decide what to do.
DistillationStage stageFor(int priorFullEvents) => priorFullEvents >= 2
    ? DistillationStage.distill
    : DistillationStage.compact;

/// Build the resume context from distillation products: the fresh
/// opening history an agent continues on after the third full.
List<Map<String, dynamic>> buildResumeHistory({
  required String systemPrompt,
  required DistillationProducts products,
}) {
  return [
    {'role': 'system', 'content': systemPrompt},
    {
      'role': 'user',
      'content':
          '===CONTINUATION===\n'
          'Your context was distilled after hitting the limit. '
          'Continue the SAME assignment now.\n\n'
          '===KNOWLEDGE===\n${products.knowledge}\n\n'
          '===WORKLOG===\n${products.worklog}\n\n'
          '===INSTRUCTION===\n${products.instruction}\n',
    },
  ];
}

/// Serialize a history to a single readable block, for logs/tests.
String debugHistoryDump(List<Map<String, dynamic>> history) =>
    jsonEncode(history);

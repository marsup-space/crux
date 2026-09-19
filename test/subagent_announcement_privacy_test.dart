// Subagent-mode announcement privacy: the raw
// `[Crux system note — subagent mode on/off]` block appended to the first
// user message after a toggle flip must never render in the user bubble.
// Verbose mode collapses it to a plain dim marker; vibe mode (the segment
// walker + scrollbar labels) routes through `stripSubagentAnnouncement`
// too. The persisted `llmText` still carries the block — this is a
// display-layer change only.

import 'package:crux/src/utils/strip_skill_bodies.dart';
import 'package:test/test.dart';

const _announcementOn =
    '[Crux system note — subagent mode on]\n'
    'Worker dispatch is ON: hands-on work (edit, write, shell/build/test '
    'runs) MUST go to a worker via send_agent / hire_agent. That includes '
    'investigation and diagnosis — reading code to find a root cause, '
    'tracing a call chain, locating where something lives. You orchestrate: '
    'decompose, dispatch, verify. You never do the legwork yourself, even '
    'with read-only tools.\n'
    'Workflow:\n'
    '- Domains are NARROW: prefer a specific label like "token-refresh" '
    'or "home-rendering" over a broad one like "general" or "ui". If '
    'find_agents shows nobody owns this specific domain, hire a fresh '
    'agent — do NOT reuse an unrelated one: it pollutes that agent\'s '
    'distilled context and dilutes its specialty. Name domains in the '
    'USER\'s language (the reply_language setting), e.g. a '
    'Chinese-speaking user gets "消息渲染", not "message-rendering" — '
    'the domain shows up in the user\'s UI.\n'
    '- ALWAYS refer to agents as agent://<id> (e.g. agent://orion) — '
    'never the bare name. The UI renders agent://<id> as the localized '
    'constellation name in the user\'s language; a bare id like "apus" '
    'or "ara" is meaningless to a non-English user. This applies '
    'EVERYWHERE: prose, tables, headings, summaries.\n'
    '- find_agents first — someone may already own the domain.\n'
    '- Dispatch with intention (one line, shown to the user) and a '
    'message that states the task boundary, acceptance criteria, and the '
    'report granularity you want (one-line conclusion vs detailed).\n'
    '- check_agent asks progress; cancel_agent is the brake; a busy '
    'agent queues by default — fork only when it cannot wait.\n'
    '- Agents report back on their own as system notes; relay their '
    'conclusions to the user, then verify / accept.';

const _announcementOff =
    '[Crux system note — subagent mode off]\n'
    'Subagent mode has been turned OFF. Edit/write/shell tools are '
    'yours to use directly again — no dispatching required.\n'
    'Agents you hired earlier stay on the roster '
    '(find_agents still lists them) and remain dispatchable the '
    'moment the switches go back on.';

void main() {
  group('stripSubagentAnnouncement (unit)', () {
    test('strips a trailing on-announcement', () {
      final out = stripSubagentAnnouncement('测试一下subagent\n\n$_announcementOn');
      expect(out, '测试一下subagent');
    });

    test('strips a trailing off-announcement', () {
      final out = stripSubagentAnnouncement('关掉 subagent\n\n$_announcementOff');
      expect(out, '关掉 subagent');
    });

    test('leaves a message without an announcement untouched', () {
      const msg = 'Just a normal message';
      final out = stripSubagentAnnouncement(msg);
      expect(out, msg);
    });

    test('does not strip a mid-message occurrence', () {
      const mid = 'prefix [Crux system note — subagent mode on] suffix';
      final out = stripSubagentAnnouncement(mid);
      expect(out, mid);
    });

    test('strips after skill bodies', () {
      // Skill bodies are appended BEFORE the announcement in the
      // persisted llmText. stripSkillBodies cuts at the first
      // `\n\nSkill: ` marker — everything after (bodies + announcement)
      // goes — so stripSubagentAnnouncement finds nothing trailing.
      // The net display text is the user's prose either way.
      final content = 'Do it\n\nSkill: widget\nbody text\n\n$_announcementOn';
      final out = stripSubagentAnnouncement(stripSkillBodies(content));
      expect(out, 'Do it');
    });

    test('strips after plan-context when no skill bodies', () {
      const planBlock = '<plan-context>\nplan_path: PLAN.md\n</plan-context>';
      final content = 'Do it\n\n$planBlock\n\n$_announcementOn';
      // The actual render path calls stripSubagentAnnouncement first,
      // then stripPlanContext removes the plan block.
      final afterAnnouncement = stripSubagentAnnouncement(content);
      final afterPlan = stripPlanContext(afterAnnouncement);
      expect(afterPlan.text, 'Do it');
    });

    test('handles empty string', () {
      final out = stripSubagentAnnouncement('');
      expect(out, '');
    });

    test('handles announcement-only message', () {
      final out = stripSubagentAnnouncement(_announcementOn);
      expect(out, '');
    });
  });
}

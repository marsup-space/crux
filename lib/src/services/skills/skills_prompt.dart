/// Render the `<available_skills>` block of the system prompt
/// (layer 3.5, between project notes and env meta).
///
/// The LLM sees only **names + descriptions** — never the body.
/// The body is loaded on demand via the `skill` tool, which is
/// the progressive-disclosure bet: cheap metadata in the prompt,
/// expensive body only when the model decides it's relevant.
///
/// Returns `null` when no skills are discovered, so the system
/// prompt can omit the layer entirely (no empty block).
library;

import 'skill.dart';

/// Render the available-skills block. Pure, side-effect free.
///
/// One skill per line, `- <name>: <description>`, no ordering
/// guarantee. The LLM pattern-matches the description text
/// against the user's task; that's the only signal it has.
///
/// `desc` is wrapped in code-fence-free prose (no markdown) so
/// the LLM can't mistake a backtick in the description for a
/// command invocation. The block itself is wrapped in
/// `<available_skills>…</available_skills>` tags so the LLM can
/// cleanly identify the boundary even after compaction.
String? buildAvailableSkillsBlock(List<SkillInfo> skills) {
  if (skills.isEmpty) return null;

  final lines = <String>['<available_skills>'];
  for (final s in skills) {
    lines.add('- ${s.name}: ${s.description}');
  }
  lines.add('</available_skills>');
  lines.add('');
  lines.add(
    'When a user task matches one of the available skills above, call the '
    '`skill` tool with that skill\'s name to load its full instructions. '
    'The skill body is not pre-loaded; only the names and short '
    'descriptions in this block are visible to you.',
  );
  return lines.join('\n');
}

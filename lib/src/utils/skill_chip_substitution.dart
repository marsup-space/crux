/// Skill chip substitution — converts the user's chat input (with
/// `$<skill-name>` chips) into the user message that actually
/// goes to the LLM.
///
/// The `$` symbol is purely a UI trigger; the LLM never sees it.
/// The skill name itself stays in the prose (so the LLM can see
/// "the user mentioned pr-review") and the skill body is
/// appended at the end of the message, prefixed with
/// `Skill: <name>` for a clean section break.
///
/// Example:
///
///     input:  "please review $pr-review by EOD"
///     userMessage:
///         "please review pr-review by EOD
///
///         Skill: pr-review
///         <body of pr-review>
///         "
///
/// For multiple chips, bodies are appended in chip order, each
/// with its own `Skill: <name>` header and a blank line between
/// them.
library;

import '../services/skills/skill.dart';
import 'skill_chip_parser.dart';

/// Result of expanding a chat input that may contain `$<skill>`
/// chips.
class SkillChipExpansion {
  /// The text to send to the LLM: `$<name>` chips have their
  /// leading `$` stripped, the names are kept in-line, and the
  /// skill bodies are appended at the end (one `Skill: <name>`
  /// block per chip, in chip order).
  final String userMessage;

  /// The chip names found in the input, in chip order. Empty if
  /// the input had no chips.
  final List<String> includedSkills;

  /// The skills that were actually substituted, with the same
  /// ordering as [includedSkills]. Useful for the chat log so
  /// the user can see which skills were loaded for a given turn.
  final List<SkillInfo> includedSkillInfos;

  const SkillChipExpansion({
    required this.userMessage,
    required this.includedSkills,
    required this.includedSkillInfos,
  });
}

/// Expand a chat input that may contain `$<skill>` chips into
/// the user message that goes to the LLM.
///
/// [input] is the raw text from the chat input (with `$`
/// symbols). [available] is the set of discovered skills,
/// typically the result of `discoverSkills(cwd: projectPath)`.
/// Skills named in [input] that are NOT in [available] are left
/// as literal `$<name>` text (the user might be typing a skill
/// the picker didn't show, or referring to a skill that was
/// removed after the input was composed).
///
/// [alreadyLoaded] is the set of skill names already loaded into
/// this session's context — `SessionRuntimeState.loadedSkillNames`,
/// fed by earlier `$` chips and by the `skill` tool. A chip whose
/// skill is in that set is still stripped (`$name` → `name`, so
/// the LLM sees the reference in the prose) but its body is NOT
/// appended again — the model already has the content, and
/// re-sending it would double-pay the tokens on every turn.
SkillChipExpansion expandSkillChips({
  required String input,
  required List<SkillInfo> available,
  Set<String> alreadyLoaded = const {},
}) {
  if (input.isEmpty) {
    return const SkillChipExpansion(
      userMessage: '',
      includedSkills: [],
      includedSkillInfos: [],
    );
  }
  if (available.isEmpty) {
    return SkillChipExpansion(
      userMessage: input,
      includedSkills: const [],
      includedSkillInfos: const [],
    );
  }

  final availableByName = <String, SkillInfo>{
    for (final s in available) s.name: s,
  };

  // Walk left-to-right, copying text into `out` and stripping
  // the leading `$` of each known chip. We also collect the
  // matching skills (in chip order) so we can append their
  // bodies at the end.
  final matches = findAllSkillChips(input, availableByName.keys.toSet());
  if (matches.isEmpty) {
    return SkillChipExpansion(
      userMessage: input,
      includedSkills: const [],
      includedSkillInfos: const [],
    );
  }

  final out = StringBuffer();
  var cursor = 0;
  final included = <String>[];
  final includedInfos = <SkillInfo>[];

  for (final m in matches) {
    // Copy the text between the previous chip (or start) and
    // this one, verbatim — including the `$` of the NEXT chip
    // boundary, which we strip below.
    if (m.dollarOffset > cursor) {
      out.write(input.substring(cursor, m.dollarOffset));
    }
    // Skip the `$`, keep the name.
    out.write(input.substring(m.dollarOffset + 1, m.nameEndOffset));
    cursor = m.nameEndOffset;

    final skill = availableByName[m.skillName];
    if (skill != null) {
      included.add(m.skillName);
      includedInfos.add(skill);
    }
  }
  // Copy the tail after the last chip.
  if (cursor < input.length) {
    out.write(input.substring(cursor));
  }

  if (includedInfos.isEmpty) {
    // Defensive: matches were non-empty but no skill info was
    // resolved. Treat as no chips.
    return SkillChipExpansion(
      userMessage: out.toString(),
      includedSkills: const [],
      includedSkillInfos: const [],
    );
  }

  // Split the resolved chips into fresh (body gets appended)
  // and already-loaded (reference only). Both lists stay in chip
  // order so the appended block matches the prose order.
  final freshInfos = <SkillInfo>[];
  for (final s in includedInfos) {
    if (!alreadyLoaded.contains(s.name)) freshInfos.add(s);
  }

  if (freshInfos.isNotEmpty) {
    // Append the fresh skill bodies at the end, one block per
    // chip. Already-loaded skills contribute only their inline
    // name in the prose above.
    out.write('\n\n');
    for (var i = 0; i < freshInfos.length; i++) {
      if (i > 0) out.write('\n\n');
      final s = freshInfos[i];
      out.write('Skill: ${s.name}\n');
      out.write(s.content.trim());
    }
    out.write('\n');
  }

  return SkillChipExpansion(
    userMessage: out.toString(),
    includedSkills: included,
    includedSkillInfos: includedInfos,
  );
}

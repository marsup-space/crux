/// Strips appended `Skill: <name>\n<body>` blocks from a persisted
/// user message's content.
///
/// When the user sends a message containing `$<skill>` chips,
/// [expandSkillChips] appends the resolved skill bodies at the end
/// of the message (one `\n\nSkill: <name>\n<body>` block per chip)
/// so the LLM sees the full skill text. That expanded form is what
/// gets persisted, but the chat log should only show what the user
/// actually typed — so every user-message renderer strips the
/// appended blocks before display.
///
/// The pattern is: a blank line followed by `Skill: <name>\n` and
/// then the body text, all the way to the end of the message
/// (bodies are always appended at the end, after the user's prose).
library;

String stripSkillBodies(String content) {
  final idx = content.indexOf('\n\nSkill: ');
  if (idx == -1) return content;
  return content.substring(0, idx);
}

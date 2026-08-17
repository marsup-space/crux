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

/// Result of stripping a trailing `<plan-context>` block from a
/// persisted user message: the displayable [text] plus whether a
/// block was removed.
class PlanContextStrip {
  final String text;

  /// True when a `<plan-context>…</plan-context>` block was found and
  /// removed. Renderers use this to show a one-line marker in place of
  /// the raw block (the full block stays inspectable via `/d-*` debug
  /// output, never inline in the bubble).
  final bool stripped;

  const PlanContextStrip(this.text, this.stripped);
}

/// Strips a trailing `<plan-context>…</plan-context>` block from a
/// persisted user message.
///
/// While plan mode is active, `chat_turn_orchestrator` appends a
/// `<plan-context>` block to the LLM-bound text so the agent knows the
/// plan path, view mode, viewport, and selection. That block is what
/// gets persisted as the user message — but it is LLM-facing context,
/// not something the user typed, so the bubble should never render it
/// raw.
///
/// The block is always appended at the very end (`llmText + '\n\n' +
/// block`), after any skill bodies, so this strips from the LAST
/// `<plan-context>` opener to the end of the string. Tolerant of the
/// closing tag being the final characters (the normal case) — the
/// regex spans the whole trailing block regardless.
PlanContextStrip stripPlanContext(String content) {
  final idx = content.lastIndexOf('<plan-context>');
  if (idx == -1) return PlanContextStrip(content, false);
  // Only strip when the block is genuinely trailing — nothing but
  // whitespace after the closing tag (or no closing tag, which means a
  // truncated/malformed block we still don't want to echo).
  final tail = content.substring(idx);
  final closeIdx = tail.indexOf('</plan-context>');
  if (closeIdx != -1) {
    final after = tail.substring(closeIdx + '</plan-context>'.length);
    if (after.trim().isNotEmpty) return PlanContextStrip(content, false);
  }
  // Trim the separator (`\n\n`) that joined the block to the prose.
  var end = idx;
  while (end > 0 && content[end - 1] == '\n') {
    end--;
  }
  return PlanContextStrip(content.substring(0, end), true);
}

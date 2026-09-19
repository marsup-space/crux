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

/// Strips a trailing `[Crux system note — subagent mode on/off]` block
/// from a persisted user message.
///
/// When the user flips a subagent-mode switch, `chat_turn_orchestrator`
/// appends the mode announcement to the FIRST subsequent user message so
/// the LLM learns the new dispatch rules. That expanded form is what gets
/// persisted, but the announcement is LLM-facing context — the bubble
/// should only show what the user actually typed.
///
/// The block is always appended at the very end (`llmText + '\n\n' +
/// announcement`), after any skill bodies and plan-context blocks, so
/// this finds the LAST `[Crux system note — subagent mode` marker
/// preceded by a blank line and cuts everything from there to the end.
///
/// Tolerates two edge cases:
///   * announcement-only message (no preceding `\n\n` separator) → the
///     whole string is the announcement, return empty.
///   * announcement after a plan-context block (no `\n\n` between them)
///     → still strips because the marker is at a line start.
String stripSubagentAnnouncement(String content) {
  const marker = '[Crux system note — subagent mode';
  final idx = content.lastIndexOf(marker);
  if (idx == -1) return content;

  // Case 1: announcement-only message (no prose before it).
  if (idx == 0) return '';

  // Case 2: marker at a line start preceded by a blank line — the normal
  // appended-at-end shape. Cut from the separator.
  final before = content.substring(0, idx);
  if (before.endsWith('\n\n')) {
    return before.substring(0, before.length - 2);
  }

  // Case 3: marker at a line start but only one newline before it — can
  // happen when a plan-context block sits directly before the
  // announcement with just one blank line between them.
  if (before.endsWith('\n')) {
    // Verify the line before the marker is blank (i.e. the marker is at
    // the start of a fresh line, not mid-sentence).
    final lineStart = before.lastIndexOf('\n', before.length - 2);
    if (lineStart == -1) {
      // Only one line before the marker — treat it as prose.
      return content;
    }
    final lastLine = before.substring(lineStart + 1).trimRight();
    if (lastLine.isEmpty) {
      // The marker is on its own line after a blank line — strip it.
      return before.substring(0, lineStart);
    }
  }

  return content;
}

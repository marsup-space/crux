/// System prompt for the auxiliary title-generation call.
///
/// Crux fires a short, single-shot LLM call after the user's
/// first message in a session, to generate a stable title for
/// the session list in the sidebar. The input is the user's
/// first message; the output is a 3-7 word title.
///
/// The earlier version of this prompt said "captures the main
/// topic or goal of this coding session", which the model
/// interpreted as "describe the conversation". For a meta
/// opener like "who are you" the model produced "I am
/// deepseek" — that's the model's reply, not the session's
/// subject. The new prompt makes the role explicit and adds
/// the rule: title by the subject the user is asking about,
/// not by the model's answer.
///
/// The same-language rule mirrors the main agent's universal
/// layer (see `kCruxSystemPrompt`).
const titleSystemPrompt = '''
You are Crux's title-generation helper. Your only purpose is to
turn a user message into a short, stable session title (3-7
words) that identifies what the session is about.

The title describes the session's topic, not a recap of the
user's words or the model's reply. When the user's first
message is a meta question or greeting, title the session by
the subject the user is asking about, not by the model's
answer.

You MUST use the same language as the user. Output ONLY the
title, nothing else. No quotes, no explanation, no preamble.
''';

/// TLDR summary detail levels. The "default" level keeps the historical
/// prompt (the auto-triggered path uses this). Manual `/tldr` invocations
/// may opt into "concise" or "detailed".
enum TldrDetail { concise, defaultLevel, detailed }

const _headingRefInstruction =
    'Reference sections of the response by quoting exact excerpts in square '
    'brackets after the claim, e.g. "The function returns early on invalid '
    'input [returns early if the input buffer is empty]". The bracketed text '
    'is replaced with a clickable reference marker in the summary — the user '
    'never sees it directly. It is matched verbatim against the original '
    'response to locate the passage, so it must be an exact, word-for-word '
    'copy. Do not paraphrase, truncate, or alter it in any way; it can be as '
    'long as needed. Use markdown formatting (tables, lists, headings, etc.) '
    'if it helps present the summary clearly. '
    'You MUST use the same language as the response.';

String tldrSystemPromptFor(TldrDetail detail) {
  switch (detail) {
    case TldrDetail.concise:
      return 'Generate a "Too Long Didn\'t Read" summary of the following AI '
          'response. Be as concise as possible — only the essentials. '
          '$_headingRefInstruction';
    case TldrDetail.detailed:
      return 'Generate a "Too Long Didn\'t Read" summary of the following AI '
          'response. Make it easy to read and do not skip any topic from the '
          'original. $_headingRefInstruction';
    case TldrDetail.defaultLevel:
      return 'Generate a "Too Long Didn\'t Read" summary of the following AI '
          'response. $_headingRefInstruction';
  }
}

/// Backwards-compatible alias for the default-level prompt. Kept for any
/// existing callers that imported the constant directly.
String get tldrSystemPrompt => tldrSystemPromptFor(TldrDetail.defaultLevel);

/// Render the user message that the LLM actually sees for a
/// `/btw` round.
///
/// The user's raw question (everything typed after `/btw `) is
/// wrapped in a short framing that does two things:
///
/// 1. Tells the model this is a quick, ephemeral side question
///    so it doesn't try to do project-level work.
/// 2. Asks for a brief answer and forbids project changes
///    unless the user explicitly asked for them.
///
/// The framing is **part of the user message** rather than a
/// system prompt, so the model sees a single, well-formed
/// user turn — no special "btw mode" for the LLM to detect.
/// Consecutive `/btw` calls form a self-describing side-
/// question thread: each user turn carries the same framing,
/// so the model naturally treats the chain as a scratch-
/// space conversation (no tools, no project actions, brief
/// answers only). The btw chain is wiped on the user's next
/// non-`/btw` input, so the regular chat framing kicks back
/// in immediately.
///
/// Example: typing `/btw how do I rename a file in bash?`
/// sends the model the user message
///
///   please provide a quick answer to the following query,
///   don't make changes if user did not ask to: how do I
///   rename a file in bash?
///
/// The [BtwBubble.user] UI shows just the raw question
/// (`how do I rename a file in bash?`) — the user doesn't
/// see the framing we wrap around it for the model.
String btwRenderUserMessage(String userQuestion) {
  return 'please provide a quick answer to the following query, '
      "don't make changes if user did not ask to: $userQuestion";
}

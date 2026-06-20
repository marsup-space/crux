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
    'Language: write the prose in the same language as the user\'s question '
    '(provided just before the assistant response in the messages). Code '
    'identifiers, file paths, symbol names, and the bracketed verbatim quotes '
    'from the response must stay exactly as they appear in the source — do '
    'NOT translate them. If no user question is provided, fall back to the '
    'language of the response.';

/// Shared preamble for every TLDR detail level. Teaches the
/// auxiliary model that the user's question precedes the
/// assistant response in the message list, so it should anchor
/// the summary to what the user actually asked (and to the
/// user's language, see [_headingRefInstruction]).
const _tldrQuestionContext =
    'Generate a "Too Long Didn\'t Read" summary of the assistant\'s response '
    'below. The user\'s question (when present) appears as the user-role '
    'message just above the assistant response in the conversation — use it '
    'to understand what the user actually asked and prioritize the parts of '
    'the response that answer that question. If no user question is provided, '
    'summarize the response on its own merits. ';

String tldrSystemPromptFor(TldrDetail detail) {
  final level = switch (detail) {
    TldrDetail.concise => 'Be as concise as possible — only the essentials. ',
    TldrDetail.detailed => 'Make it easy to read and do not skip any topic '
        'from the original. ',
    TldrDetail.defaultLevel => '',
  };
  return '$_tldrQuestionContext$level$_headingRefInstruction';
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

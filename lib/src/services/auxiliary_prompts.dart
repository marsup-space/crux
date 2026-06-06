const titleSystemPrompt =
    'Generate a concise title (3-7 words) that captures the '
    'main topic or goal of this coding session. The title should be clear '
    'enough that the user recognizes the session in a list. You MUST use '
    'the same language as the user. Output ONLY the title, nothing else. '
    'No quotes, no explanation.';

/// TLDR summary detail levels. The "default" level keeps the historical
/// prompt (the auto-triggered path uses this). Manual `/tldr` invocations
/// may opt into "concise" or "detailed".
enum TldrDetail { concise, defaultLevel, detailed }

const _headingRefInstruction =
    'Reference sections of the response by quoting exact excerpts in square '
    'brackets, e.g. "The function returns early on invalid input [returns '
    'early if the input buffer is empty]". The bracketed text is hidden from '
    'the user and used to locate the original passage in the source — it is '
    'matched verbatim, so it must be an exact, word-for-word copy from the '
    'response. Do not paraphrase, truncate, or alter it in any way; it can be '
    'as long as needed. Use markdown formatting (tables, lists, headings, etc.) '
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

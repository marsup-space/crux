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
    'Each bullet point MUST reference its corresponding section heading from '
    'the response using square brackets, e.g. '
    '"- Key point here [Section Heading]". '
    'You MUST use the EXACT heading text as it appears in the response — '
    'do not paraphrase or abbreviate headings. Every bullet must include '
    'at least one [Heading] reference. '
    'You MUST use the same language as the response. '
    'Output ONLY the bullet points, nothing else. No preamble, no conclusion.';

String tldrSystemPromptFor(TldrDetail detail) {
  switch (detail) {
    case TldrDetail.concise:
      return 'Summarize the following AI response in as few bullet points as '
          'possible — strictly the minimum needed to convey the core message. '
          'Aim for 1-3 bullets total, even if the response has many sections. '
          'Prefer brevity over completeness: omit any section that is not '
          'essential to understanding the result. '
          'Keep each bullet under 12 words. $_headingRefInstruction';
    case TldrDetail.detailed:
      return 'Summarize the following AI response in thorough bullet points. '
          'Cover every meaningful section of the response — do not skip '
          'sections just to stay short. You may use many bullets if the '
          'response warrants it. Preserve important nuances, caveats, and '
          'distinctions from the original. Keep each bullet under 25 words. '
          '$_headingRefInstruction';
    case TldrDetail.defaultLevel:
      return 'Summarize the following AI response in concise bullet points. '
          'Decide the number of bullets yourself based on the content — '
          'use as few or as many as are needed to capture the key points '
          'without redundancy. Keep each bullet under 15 words. '
          '$_headingRefInstruction';
  }
}

/// Backwards-compatible alias for the default-level prompt. Kept for any
/// existing callers that imported the constant directly.
String get tldrSystemPrompt => tldrSystemPromptFor(TldrDetail.defaultLevel);

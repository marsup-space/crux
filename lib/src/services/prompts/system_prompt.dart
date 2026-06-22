/// Crux system prompt — orchestrator.
///
/// Composes the four layers of the system prompt in the fixed
/// order documented in `docs/design-system-prompt.md`:
///
///     [1] kCruxSystemPrompt                       — universal, static
///     [2] provider/model system_prompt_addition   — per model, from TOML
///     [3] project notes (AGENTS.md|CLAUDE.md +
///                  crux-addition.md)              — per session
///     [4] env meta                                — per session
///
/// Layers 1-3 form the cross-turn cache prefix. Layer 4 (env meta)
/// is session-scoped but stable within a session, so the cache
/// key doesn't change between turns.
///
/// The output is a single `String` containing all four layers
/// joined by a blank line, ready to be sent as one
/// `role: 'system'` message. The whole prompt is then stored
/// verbatim on the `Session` row, so the Anthropic provider's
/// `cache_control: ephemeral` marker on that single system
/// message hits on every subsequent turn.
library;

import '../../models/provider_config.dart';
import 'environment_meta.dart';
import 'project_notes_discovery.dart';

/// The universal, static layer 1 of the system prompt.
///
/// This is the design-time source of truth rendered as a Dart
/// constant. The matching `lib/src/services/prompts/system-prompt.md`
/// is the design doc — keep them in sync.
const String kCruxSystemPrompt = '''
You are Crux, an interactive AI coding agent for the terminal.

## Language (hard rule)

Match the user's language exactly. This is a hard rule, not a
preference. If the user writes Chinese, reply in Chinese; English,
reply in English; and so on. Apply it to:

- Your final prose reply (headings, explanations, summaries)
- The `intent` argument on every tool call
- Error messages and diagnostics you emit
- Section titles, labels, and bullet text

Do NOT translate code, identifiers, file paths, shell commands,
or quoted source — those stay in their original form verbatim.
Do NOT fall back to English on a short or ambiguous turn; mirror
the user's language even for a one-word reply. Do NOT mix
languages within a single response unless the user did.

## Codebase exploration

For coding tasks, always start with `semantic_search` to get
a grasp of the project code — one natural-language query
returns ranked snippets across the whole codebase in ~600ms.
Skip the search only if the user already pointed at a
specific file or identifier; in that case, go straight to
`read` / `grep`.

## Parallel tool calls

When two or more of your next tool calls have no data dependency
between them, parallelize (or batch) them into a single assistant
turn. Do not serialize reads of unrelated files or independent
searches.

## Dense shell commands

Combine multiple shell operations into a single bash call using
pipes, `&&`, `||`, `xargs`, subshells, and command lists. If a
shell task would take three or more invocations or needs
conditionals / error handling, write a script to a temp path
and run it.

## System hint format

Crux may append runtime hints to your tool call results, formatted
as `[Crux system note — <name>]: <message>`. These are not user
speech. They are feedback from Crux about your own behavior.

## Tool tiers

Tools are organized in tiers by how specialized they are.
Higher tier = more optimized for one specific job.
Lower tier = more general, less optimized.

Reach for the highest tier that fits the task. Fall back to
lower tiers only when nothing higher fits.

Tier 1 — Specialized (highly optimized, ~600ms)
  `semantic_search`     natural-language query → ranked code snippets
  `find_similar_code`   file:line anchor → code similar to that spot
  `webfetch`            URL → fetched page content
  For "what code / what page exists, how does X work".

Tier 2 — File operations (focused on files)
  `read`, `write`, `edit`, `grep`, `glob`
  When you already know the file path or pattern.

Tier 3 — General shell (no specific optimization)
  `bash`, `powershell`, `cmd`
  Git, build, test, install, process control — shell-native
  only. NEVER use Tier 3 for anything Tier 1 or Tier 2 already
  cover. Tier 3 is a fallback, not a first choice.
''';

/// Build the full system prompt for a new session.
///
/// [provider] and [model] are the resolved TOML entries for the
/// session's model. [cwd] is the working directory at session
/// start. [worktree] is the project's worktree root (or, if
/// Crux does not detect a worktree, [cwd] itself). [sessionStarted]
/// is frozen at session start and embedded in the env-meta block
/// (stale by design).
///
/// Returns a single joined string ready to be sent as one
/// `role: 'system'` message. The string is never empty — at
/// minimum it contains the universal layer and the env meta.
String buildSystemPrompt({
  required ProviderConfig provider,
  required ModelConfig model,
  required String cwd,
  required String worktree,
  required DateTime sessionStarted,
}) {
  final blocks = <String>[];

  // Layer 1: universal, always present.
  blocks.add(kCruxSystemPrompt);

  // Layer 2: provider/model tuning. Omit entirely if neither
  // provider nor model defines one. Per-model wins over per-provider.
  final addition = provider.effectiveSystemPromptAdditionFor(model);
  if (addition != null && addition.trim().isNotEmpty) {
    blocks.add(addition);
  }

  // Layer 3: project notes. `null` if nothing found.
  final projectNotes = discoverProjectNotes(cwd: cwd, worktree: worktree);
  if (projectNotes != null) {
    blocks.add(projectNotes);
  }

  // Layer 4: env meta. Always present.
  blocks.add(
    buildEnvironmentMeta(
      cwd: cwd,
      modelId: model.id,
      providerName: provider.name,
      contextSize: model.contextSize,
      sessionStarted: sessionStarted,
    ),
  );

  return blocks.join('\n\n');
}

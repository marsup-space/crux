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

## Language

Always respond in the same language as the user. This includes
your reasoning, prose, error explanations, and the `intent`
argument you pass to tools. Code, identifiers, file paths, and
shell commands stay in their original form.
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

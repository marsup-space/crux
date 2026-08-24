/// Environment meta block for the Crux system prompt.
///
/// Layer 4 of the system prompt: a small, session-scoped block
/// describing the runtime context. Computed once at session start,
/// stored on the session row, re-attached verbatim on every turn.
///
/// **Stale by design**: the `Session started` timestamp is captured
/// at session start and never updated. The model is told this
/// directly so it doesn't assume the timestamp is "now".
///
/// The block is rendered as:
///
///     <env>
///       Working directory: <cwd>
///       Is directory a git repo: yes|no
///       Platform: <macos|linux|windows>
///       Model: <id> (provider: <name>, context: <n> tokens)
///       Session started: <iso 8601 timestamp>
///     </env>
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Build the env-meta block.
///
/// [cwd] is the working directory at session start.
/// [modelId] is the model the session is using (e.g. `claude-opus-4-6`).
/// [providerName] is the TOML provider name (e.g. `anthropic`).
/// [contextSize] is the model's max context window in tokens.
/// [sessionStarted] is the session's start time — frozen, never updated.
String buildEnvironmentMeta({
  required String cwd,
  required String modelId,
  required String providerName,
  required int contextSize,
  required DateTime sessionStarted,
}) {
  final isGit = _isInsideGitRepo(cwd);
  final platform = _platformLabel(Platform.operatingSystem);
  final started = sessionStarted.toUtc().toIso8601String();

  return '<env>\n'
      '  Working directory: $cwd\n'
      '  Is directory a git repo: ${isGit ? 'yes' : 'no'}\n'
      '  Platform: $platform\n'
      '  Model: $modelId (provider: $providerName, context: $contextSize tokens)\n'
      '  Session started: $started (stale by design — captured at session start, not now)\n'
      '</env>';
}

/// Build the env-meta block for a Chat-mode session.
///
/// Workspace-free by design: Chat mode is not tied to any directory,
/// so the block deliberately omits the `Working directory` and
/// `Is directory a git repo` lines that [buildEnvironmentMeta]
/// renders. Surfacing a launch directory here made the model treat
/// the chat as workspace-bound (it would mention and offer to work
/// on that directory), which defeats the point of Chat mode. Only
/// platform / model / session-start survive — all workspace-agnostic.
String buildChatEnvironmentMeta({
  required String modelId,
  required String providerName,
  required int contextSize,
  required DateTime sessionStarted,
}) {
  final platform = _platformLabel(Platform.operatingSystem);
  final started = sessionStarted.toUtc().toIso8601String();

  return '<env>\n'
      '  Mode: chat (not tied to any workspace or directory)\n'
      '  Platform: $platform\n'
      '  Model: $modelId (provider: $providerName, context: $contextSize tokens)\n'
      '  Session started: $started (stale by design — captured at session start, not now)\n'
      '</env>';
}

/// Extract the model ID from a cached system prompt's env block.
/// Returns null if no env block or model line is found.
///
/// Used to detect when the session's model has changed since the
/// system prompt was last built, so the prompt can be rebuilt with
/// the current model info.
String? extractModelIdFromPrompt(String? cachedPrompt) {
  if (cachedPrompt == null || cachedPrompt.isEmpty) return null;
  final match = RegExp(r'Model: (\S+)').firstMatch(cachedPrompt);
  return match?.group(1);
}

/// Cheap, best-effort git detection: walks up from [cwd] looking
/// for a `.git` entry. Returns `true` on the first hit, `false`
/// at the filesystem root or on any error.
bool _isInsideGitRepo(String cwd) {
  String? current = p.canonicalize(cwd);
  while (current != null) {
    final gitPath = p.join(current, '.git');
    if (Directory(gitPath).existsSync() || File(gitPath).existsSync()) {
      return true;
    }
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
  return false;
}

/// Map [Platform.operatingSystem] to a short, human-readable label.
String _platformLabel(String os) {
  switch (os) {
    case 'macos':
      return 'macos';
    case 'windows':
      return 'windows';
    case 'linux':
      return 'linux';
    case 'android':
      return 'android';
    case 'ios':
      return 'ios';
    case 'fuchsia':
      return 'fuchsia';
    default:
      return os; // unknown — surface the raw value rather than hide it
  }
}

import '../tools/tool_def.dart';

/// A completed tool execution that can be observed without coupling a
/// consumer to the chat-turn executor's dispatch loop.
///
/// The workspace is the session project path supplied to [ToolContext], not
/// a path inferred from a shell command. Consumers therefore act only on the
/// workspace that owns the agent turn.
class ToolExecutionCompleted {
  final String toolName;
  final Map<String, dynamic> input;
  final ToolResult result;
  final String workspacePath;

  const ToolExecutionCompleted({
    required this.toolName,
    required this.input,
    required this.result,
    required this.workspacePath,
  });

  /// Whether this completed shell invocation ran at least one `git` command.
  ///
  /// This deliberately includes read-only Git commands. Refreshing after
  /// those is cheap (unchanged snapshots do not notify listeners), while it
  /// keeps the sidebar correct when a command chain changes repository state.
  bool get isWorkspaceGitCommand =>
      _shellToolNames.contains(toolName.toLowerCase()) &&
      commandContainsGit(input['command'] as String? ?? '');
}

const _shellToolNames = {'bash', 'cmd', 'powershell'};

/// Best-effort, quote-aware recognition of `git` at a shell command boundary.
///
/// It recognizes command chains such as `dart test && git add .`, but does
/// not mistake quoted text (for example `echo "git status"`) for a Git
/// invocation. This is intentionally not a shell parser: it is a UI refresh
/// hint, so a false negative merely falls back to the normal end-of-turn and
/// 60-second refresh paths.
bool commandContainsGit(String command) {
  var segmentStart = true;
  var quote = '';

  for (var i = 0; i < command.length;) {
    final char = command[i];
    if (quote.isNotEmpty) {
      if (char == '\\' && quote != "'" && i + 1 < command.length) {
        i += 2;
        continue;
      }
      if (char == quote) quote = '';
      i++;
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      i++;
      continue;
    }
    if (char == ';' || char == '|' || char == '&' || char == '\n') {
      segmentStart = true;
      i++;
      continue;
    }
    if (char.trim().isEmpty) {
      i++;
      continue;
    }
    if (!segmentStart) {
      i++;
      continue;
    }

    final tokenStart = i;
    while (i < command.length) {
      final token = command[i];
      if (token.trim().isEmpty ||
          token == ';' ||
          token == '|' ||
          token == '&') {
        break;
      }
      i++;
    }
    final token = command.substring(tokenStart, i).toLowerCase();
    if (token == 'git' || token == 'git.exe') return true;
    segmentStart = false;
  }
  return false;
}

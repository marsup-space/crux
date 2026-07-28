// Shared LSP diagnostics collection for the file-mutating tools
// (write/edit). Previously each tool carried a verbatim copy of this
// helper (`WriteTool._collectLspDiagnostics` /
// `EditTool._collectLspDiagnostics`); the two drifted only in their
// doc comments, so the logic now lives here exactly once.

import '../lsp/manager.dart' show LspManager;
import '../lsp/protocol.dart' show LspDiagnostic;
import 'tool_def.dart';

/// The per-call LSP outcome for a single write/edit, surfaced in the
/// chat-history tool bubble as a color-coded `⎇` glyph.
///
/// Persisted in `messages.meta` as a compact `"lsp":"<state>"` field
/// (see `_buildToolResultForPersist` in `chat_turn_executor.dart`) so
/// both the verbose tool bubble and the vibe tools box can render the
/// state without re-running the language server.
enum LspStatus {
  /// A language server matched the file, ran, and returned zero
  /// diagnostics. Rendered green — the edit introduced no problems.
  clean,

  /// A language server matched the file, ran, and returned at least
  /// one diagnostic (any severity). Rendered red — the edit left
  /// issues behind. (The user-facing bubble counts only
  /// error-severity, but any diagnostic means the server answered.)
  errors,

  /// A language server *should* have answered (its extension/bare-
  /// filename matched the file) but the start / initialize / wait
  /// failed or timed out. Rendered yellow — the LSP is enabled but
  /// not working for this file. Distinct from [none]: a matched-but-
  /// failed server is a real "your LSP is broken" signal worth
  /// surfacing, whereas an unmatched file type is simply not
  /// LSP-backed.
  failed,

  /// No language server handles this file type (or LSP is disabled
  /// for the session). No glyph rendered — the tool is not LSP-backed
  /// for this call, so there's nothing to report.
  none,
}

/// Collect LSP diagnostics for [filePath]. Returns the (possibly-
/// modified) output text, the raw diagnostic list, and the per-call
/// [LspStatus]. The list is exposed in [ToolResult.metadata] under
/// the `lsp` key so the collapsed summary can show the count in the
/// hint bubble, the chat turn executor can attach a compact
/// error-only block to the same-turn tool result, and persistence can
/// embed the full list as a `<crux-lsp>` payload. The [LspStatus] is
/// exposed under the `lspStatus` key so persistence can record the
/// color-coded state in `messages.meta`.
///
/// The output text is returned unchanged — the count is surfaced via
/// the `LspDiagnosticsBubble` in the chat history, not appended to
/// the tool's textual output.
///
/// Best-effort: any failure (no LSP manager, aborted context, no
/// server, timeout, malformed response) returns `[]` diagnostics and
/// a status of [LspStatus.failed] (a server matched but didn't
/// answer) or [LspStatus.none] (no server for this file type). The
/// tool must never fail because of LSP.
Future<({String output, List<LspDiagnostic> diagnostics, LspStatus status})>
collectLspDiagnostics({
  required LspManager? lsp,
  required String filePath,
  required String baseOutput,
  required ToolContext ctx,
}) async {
  const empty = <LspDiagnostic>[];
  final mgr = lsp;
  if (mgr == null) {
    return (output: baseOutput, diagnostics: empty, status: LspStatus.none);
  }
  // A server only counts as "failed" when one actually matched this
  // file's extension/bare-filename. Without this probe an unmatched
  // file type would be misreported as a broken LSP.
  final matched = mgr.matchServerIdFor(filePath) != null;
  if (!matched) {
    return (output: baseOutput, diagnostics: empty, status: LspStatus.none);
  }
  try {
    if (ctx.abort.isAborted) {
      return (output: baseOutput, diagnostics: empty, status: LspStatus.failed);
    }
    final diagnostics = await mgr.touchFileAndWait(
      filePath,
      isCancelled: () => ctx.abort.isAborted,
    );
    if (diagnostics.isEmpty) {
      return (output: baseOutput, diagnostics: empty, status: LspStatus.clean);
    }
    return (
      output: baseOutput,
      diagnostics: diagnostics,
      status: LspStatus.errors,
    );
  } catch (_) {
    return (output: baseOutput, diagnostics: empty, status: LspStatus.failed);
  }
}

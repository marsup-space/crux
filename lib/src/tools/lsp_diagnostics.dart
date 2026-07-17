// Shared LSP diagnostics collection for the file-mutating tools
// (write/edit). Previously each tool carried a verbatim copy of this
// helper (`WriteTool._collectLspDiagnostics` /
// `EditTool._collectLspDiagnostics`); the two drifted only in their
// doc comments, so the logic now lives here exactly once.

import '../lsp/manager.dart' show LspManager;
import '../lsp/protocol.dart' show LspDiagnostic;
import 'tool_def.dart';

/// Collect LSP diagnostics for [filePath]. Returns the (possibly-
/// modified) output text and the raw diagnostic list. The list is
/// exposed in [ToolResult.metadata] under the `lsp` key so the
/// collapsed summary can show the count in the hint bubble, the chat
/// turn executor can attach a compact error-only block to the
/// same-turn tool result, and persistence can embed the full list
/// as a `<crux-lsp>` payload.
///
/// The output text is returned unchanged — the count is surfaced via
/// the `LspDiagnosticsBubble` in the chat history, not appended to
/// the tool's textual output.
///
/// Best-effort: any failure (no LSP manager, aborted context, no
/// server, timeout, malformed response) returns
/// ([baseOutput], const []). The tool must never fail because of LSP.
Future<({String output, List<LspDiagnostic> diagnostics})>
collectLspDiagnostics({
  required LspManager? lsp,
  required String filePath,
  required String baseOutput,
  required ToolContext ctx,
}) async {
  final mgr = lsp;
  if (mgr == null) {
    return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
  }
  try {
    if (ctx.abort.isAborted) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
    final diagnostics = await mgr.touchFileAndWait(
      filePath,
      isCancelled: () => ctx.abort.isAborted,
    );
    if (diagnostics.isEmpty) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
    return (output: baseOutput, diagnostics: diagnostics);
  } catch (_) {
    return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
  }
}

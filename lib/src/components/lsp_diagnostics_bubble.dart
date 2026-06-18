import 'package:nocterm/nocterm.dart';

import 'system_hint_bubble.dart';

/// Small inline bubble rendered when a tool round produced LSP
/// diagnostics for the file just edited/written.
///
/// Distinct from the in-context prompt the chat service might
/// surface to the LLM (we don't currently inject one — the model
/// can call `read` to see the errors via the file path the bubble
/// references). This bubble is the *user-facing* affordance so the
/// human can see at a glance that a tool call surfaced N problems.
///
/// Inherits the shared glyph + body + colour layout from
/// [SystemHintBubble]; this class only supplies the data, the kind
/// (error → red), and the body text formatter.
///
/// Data model:
///   * [errorCount] — number of error-severity diagnostics. Drives
///     the body text. The persisted [Message.parallelCount] is
///     re-used for this value (same column the praise/recall
///     bubbles use; different meaning per `role`).
///   * [filePath] — optional relative path of the file the
///     diagnostics came from. Displayed after the count. Currently
///     the chat service emits one bubble per *file* that had
///     diagnostics, so the path helps when the user edited multiple
///     files in one round.
///   * [language] — optional LSP language id (e.g. `dart`,
///     `typescript`, `rust`) used to prefix the bubble with the
///     language name. When set the body renders as
///     `"Dart lsp: 5 errors in src/auth.ts"`; when null the legacy
///     `"lsp: 5 errors in src/auth.ts"` form is used so older
///     persisted rows keep rendering cleanly. Caller is responsible
///     for humanising the id (capitalise first letter) — the bubble
///     just splices the prefix in.
class LspDiagnosticsBubble extends SystemHintBubble {
  final int errorCount;
  final String? filePath;
  final String? language;

  const LspDiagnosticsBubble({
    super.key,
    required this.errorCount,
    this.filePath,
    this.language,
  });

  @override
  SystemHintKind get kind => SystemHintKind.error;

  @override
  String get body {
    final word = errorCount == 1 ? 'error' : 'errors';
    final tail = filePath != null ? ' in $filePath' : '';
    final prefix = (language != null && language!.isNotEmpty)
        ? '$language lsp'
        : 'lsp';
    return '$prefix: $errorCount $word$tail';
  }

  @override
  Component build(BuildContext context) {
    // Defensive: render nothing for a zero or negative count. The
    // chat service should only persist this bubble when there are
    // actual diagnostics, but a bad migration or a hand-crafted
    // row shouldn't break the chat render.
    if (errorCount <= 0) return const SizedBox.shrink();
    return super.build(context);
  }
}

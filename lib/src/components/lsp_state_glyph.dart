import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../utils/tool_meta.dart';

/// The glyph shown next to a write/edit tool name to flag its
/// per-call LSP outcome. A branch symbol — reads as "this edit went
/// through a language server."
const String kLspGlyph = '⎇';

/// Map an [LspState] to its display color.
///
///   * [LspState.clean]    → `success` (green)  — server ran, no issues
///   * [LspState.errors]   → `error`   (red)    — server returned diagnostics
///   * [LspState.failed]   → `warning` (yellow) — matched server didn't answer
///   * [LspState.none]     → `textMuted` (gray) — no server for this file type
///   * [LspState.disabled] → null               — LSP off for the session, no glyph
Color? lspStateColor(LspState state, CruxThemeData theme) {
  switch (state) {
    case LspState.clean:
      return theme.success;
    case LspState.errors:
      return theme.error;
    case LspState.failed:
      return theme.warning;
    case LspState.none:
      return theme.textMuted;
    case LspState.disabled:
      return null;
  }
}

/// Build the colored `⎇` [TextSpan] for a persisted [LspState], or
/// null when the state is [LspState.disabled] (LSP off — the one state
/// that renders no glyph). [LspState.none] returns a muted gray span
/// so a write to a non-LSP file type still shows a visible state.
/// Leading space separates the glyph from the tool name it follows.
///
/// Shared by the verbose tool-call bubble (`message_bubble.dart`), the
/// persisted vibe tools box (`vibe_segment_bubble.dart`), and the live
/// vibe tools box (`vibe_streaming_bubble.dart`) so all three render
/// the identical glyph + color for the same state.
TextSpan? lspStateGlyphSpan(LspState state, CruxThemeData theme) {
  final color = lspStateColor(state, theme);
  if (color == null) return null;
  return TextSpan(
    text: ' $kLspGlyph',
    style: TextStyle(color: color, fontWeight: FontWeight.bold),
  );
}

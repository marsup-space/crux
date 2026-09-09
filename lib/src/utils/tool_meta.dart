/// Helpers for parsing the user-facing UI metadata blob persisted
/// on `messages.meta` (schema v20). The metadata is set by tool
/// implementations via `ToolResult.metadata`, picked out by
/// `_buildToolResultForPersist` in `chat_service.dart`, and
/// persisted in the `messages.meta` column.
///
/// The metadata is **never** sent to the LLM — it's read only by
/// the chat-history bubble and the tool detail view to render
/// inline affordances like the "via system proxy" badge.
///
/// The wire format is a tiny JSON object. We only forward
/// well-known keys from the tool layer (`routing` today; future
/// keys can be added here). The parser is intentionally minimal —
/// no dependency on `dart:convert`, no arbitrary JSON support.
library;

/// Tool-result routing descriptor persisted in `messages.meta`.
///
/// Currently only used to signal that a `webfetch` (or any other
/// tool that uses `withProxyRetry`) fell back to the system proxy
/// because the direct connection failed. Future tools that go
/// through the same proxy-aware HTTP wrapper will reuse this.
class ToolRouting {
  /// One of: `direct`, `system-proxy`. Direct is the default; the
  /// field is empty in the persisted `meta` for direct calls so
  /// existing rows render correctly without a migration.
  final String value;
  const ToolRouting(this.value);

  /// True when the tool's response came back through the system
  /// proxy because the direct connection failed.
  bool get isProxied => value == 'system-proxy';

  @override
  String toString() => 'ToolRouting($value)';
}

/// Parse the routing descriptor out of [meta] (the JSON blob
/// stored in `messages.meta`). Returns `null` if there is no
/// routing entry, the entry is malformed, or the value is the
/// default `"direct"` (nothing to surface in the UI).
ToolRouting? parseToolRouting(String? meta) {
  if (meta == null || meta.isEmpty) return null;
  final value = _extractJsonStringField(meta, 'routing');
  if (value == null) return null;
  if (value == 'direct') return null;
  return ToolRouting(value);
}

/// Build the JSON blob to write into `messages.meta` for a given
/// routing descriptor. Returns `''` (empty string) when no
/// metadata applies — that's the column's default and what we
/// want for direct calls.
String buildToolMeta({ToolRouting? routing}) {
  if (routing == null || routing.value == 'direct') return '';
  return '{"routing":"${_escapeJsonString(routing.value)}"}';
}

/// Short, user-visible hint for the collapsed tool bubble.
/// Returns `null` when nothing should be added.
String? routingBubbleHint(ToolRouting? routing) {
  if (routing == null) return null;
  switch (routing.value) {
    case 'system-proxy':
      return 'via system proxy';
    default:
      return routing.value;
  }
}

/// Per-call LSP outcome persisted in `messages.meta` as
/// `"lsp":"<state>"`. Mirrors `LspStatus` in
/// `lib/src/tools/lsp_diagnostics.dart` but lives here (not imported
/// from the tool layer) so the chat-history bubble and vibe tools box
/// can parse the state without a dependency on the tool internals.
/// The string values are identical to `LspStatus.name` so the tool
/// layer and the UI agree on the wire format.
enum LspState {
  /// Server matched, ran, zero diagnostics → green glyph.
  clean,

  /// Server matched, ran, ≥1 diagnostic → red glyph.
  errors,

  /// Server matched but start/initialize/wait failed → yellow glyph.
  failed,

  /// No server handles this file type (e.g. a `.txt` write) → neutral
  /// gray glyph. Visible so the user always gets a per-call answer,
  /// but muted because "not applicable" is normal, not a problem.
  none,

  /// LSP is disabled for the session (no manager wired in) → no
  /// glyph at all. Distinct from [none]: a write to a code file with
  /// LSP turned off shouldn't imply a server was merely unmatched.
  /// Never persisted — absent `lsp` field parses to this when the
  /// tool is known to be LSP-capable but reported nothing.
  disabled,
}

/// True when [meta] carries a persisted `lsp` field — i.e. a write/edit
/// actually executed and consulted the language server (regardless of
/// outcome). False for empty meta and for results that never reached the
/// LSP (e.g. a guard-aborted edit, which persists no `lspStatus`).
///
/// The renderers gate the glyph on this rather than on
/// [parseLspState] alone: empty meta parses to [LspState.none], which
/// would otherwise stamp a gray "not applicable" glyph on a tool that
/// never ran the LSP at all. Only a persisted `lsp` field earns a glyph.
bool hasLspState(String? meta) {
  if (meta == null || meta.isEmpty) return false;
  return _extractJsonStringField(meta, 'lsp') != null;
}

/// Parse the LSP state out of [meta] (the JSON blob stored in
/// `messages.meta`). Returns [LspState.none] when there is no `lsp`
/// field or the value is unrecognised. Note: [LspState.disabled] is
/// never written to the blob (the tool omits it), so it is only ever
/// produced in-memory by the tool layer, never parsed back here.
///
/// Callers that want "render a glyph only when the LSP was actually
/// consulted" should check [hasLspState] first — an absent field parses
/// to [LspState.none], which is a *visible* gray state, not "no glyph".
LspState parseLspState(String? meta) {
  if (meta == null || meta.isEmpty) return LspState.none;
  final value = _extractJsonStringField(meta, 'lsp');
  switch (value) {
    case 'clean':
      return LspState.clean;
    case 'errors':
      return LspState.errors;
    case 'failed':
      return LspState.failed;
    case 'none':
      return LspState.none;
    default:
      return LspState.none;
  }
}

/// Serialize an [LspState] to its wire value, or null when the state
/// carries no UI affordance and should be omitted from the persisted
/// blob. Only [LspState.disabled] is omitted — every other state
/// (including the gray "not applicable" [LspState.none]) is persisted
/// so the glyph renders.
String? lspStateToWire(LspState state) =>
    state == LspState.disabled ? null : state.name;

/// Tiny JSON-string-field extractor. Avoids depending on
/// `dart:convert` for a single well-known key shape. Returns
/// `null` if the field is absent or the JSON is malformed.
String? _extractJsonStringField(String json, String field) {
  final match = RegExp('"$field"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"')
      .firstMatch(json);
  if (match == null) return null;
  return _unescapeJsonString(match.group(1)!);
}

/// Unescape the small subset of JSON string escapes we emit.
String _unescapeJsonString(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final next = s[i + 1];
      switch (next) {
        case '"':
          out.write('"');
        case r'\':
          out.write(r'\');
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        default:
          out.write(next);
      }
      i += 2;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// Minimal JSON string escaper for our well-known values.
String _escapeJsonString(String s) {
  return s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\t', r'\t');
}

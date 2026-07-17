// Format LSP diagnostics for inclusion in tool output (edit/write).
//
// Crux mirrors OpenCode's behavior from `lsp/diagnostic.ts`:
//   - Filter to severity 1 (errors) only; warnings/info/hint are noise.
//   - Cap at 20 diagnostics per file to keep tool output manageable.
//   - Format: `ERROR [line:col] message` per diagnostic, wrapped in
//     `<diagnostics file="...">` … `</diagnostics>`.
//   - Emit a trailing `... and N more` if the cap truncated.
//
// In addition, this file hosts the helpers for embedding the full
// diagnostic list in a tool result's `content` field as a
// magic-marker JSON block. The block travels with the message and
// the detail view parses it out to render a dedicated "LSP errors"
// section. The marker is named with `crux-` prefix so a casual
// content search won't trigger a false positive.

import 'dart:convert';

import 'protocol.dart';

const int _kMaxPerFile = 20;

/// Magic-marker envelope used to embed the LSP diagnostic list in
/// the tool result's `content` field as JSON. The model can read
/// the structured data to self-correct; the tool detail view
/// parses the marker out and renders a dedicated "LSP errors"
/// section.
///
/// Both tags must appear on their own lines so a parser can
/// extract the body without false positives from a path or
/// message that happens to mention the substring. The marker
/// can appear anywhere in the content (typically appended at
/// the end after a blank line).
const String lspTagOpen = '<crux-lsp>';
const String lspTagClose = '</crux-lsp>';

/// Full marker with the surrounding newlines that wrap the
/// payload. The leading and trailing newlines keep the marker
/// visually distinct when the content is read as plain text.
const String lspMarkerOpen = '\n$lspTagOpen\n';
const String lspMarkerClose = '\n$lspTagClose';

/// Return the subset of [diagnostics] that are error-severity.
///
/// Per the LSP spec, a missing/null `severity` field defaults to
/// Error (severity 1), so null is treated as error here — same as
/// the tool detail pane. Crux only surfaces errors in the
/// user-facing UI: the chat-history `lsp_diagnostics` bubble and
/// the tool detail pane's "LSP errors" section both count and
/// render only this subset, so any drift between the two views
/// would surface as a bubble vs. detail mismatch. Warnings / info
/// / hint stay in the embedded `<crux-lsp>` JSON for the model's
/// own consumption but are not user-facing.
List<LspDiagnostic> errorDiagnostics(List<LspDiagnostic> diagnostics) {
  return diagnostics
      .where(
        (d) =>
            (d.severity ?? LspDiagnosticSeverity.error) ==
            LspDiagnosticSeverity.error,
      )
      .toList(growable: false);
}

/// Pretty-print a single diagnostic for the agent. Lines are 1-based
/// (LSP is 0-based; the LLM thinks in editor coordinates).
///
/// When [maxMessageChars] is > 0, an over-long `message` is truncated
/// to that many characters with an ellipsis — a pathological analyzer
/// (multi-KB single diagnostic) must not blow up the token budget of
/// whatever surface embeds the line.
String prettyDiagnostic(LspDiagnostic d, {int maxMessageChars = 0}) {
  final severity = switch (d.severity) {
    LspDiagnosticSeverity.error => 'ERROR',
    LspDiagnosticSeverity.warning => 'WARN',
    LspDiagnosticSeverity.information => 'INFO',
    LspDiagnosticSeverity.hint => 'HINT',
    null => 'ERROR',
  };
  final line = d.range.start.line + 1;
  final col = d.range.start.character + 1;
  var message = d.message;
  if (maxMessageChars > 0 && message.length > maxMessageChars) {
    message = '${message.substring(0, maxMessageChars)}…';
  }
  return '$severity [$line:$col] $message';
}

/// Render diagnostics for one file into the agent-facing block. Returns
/// the empty string if there are no error-severity items.
///
/// Error filtering follows [errorDiagnostics] semantics: a missing
/// `severity` defaults to Error per the LSP spec. [maxPerFile] caps
/// how many entries are shown (remainder is summarized as
/// `... and N more`); [maxMessageChars] truncates each message
/// (0 = no truncation). Both knobs exist so same-turn tool results
/// can spend a much smaller budget than the historical per-file cap.
String reportDiagnostics(
  String file,
  List<LspDiagnostic> issues, {
  int maxPerFile = _kMaxPerFile,
  int maxMessageChars = 0,
}) {
  final errors = errorDiagnostics(issues);
  if (errors.isEmpty) return '';
  final shown = errors
      .take(maxPerFile)
      .map((d) => prettyDiagnostic(d, maxMessageChars: maxMessageChars))
      .join('\n');
  final total = errors.length;
  final suffix = total > maxPerFile
      ? '\n... and ${total - maxPerFile} more'
      : '';
  return '<diagnostics file="$file">\n$shown$suffix\n</diagnostics>';
}

/// Same-turn feedback budget: how many error diagnostics a write/edit
/// tool result may carry back to the API on the turn that produced
/// them, and how long each message may be. Kept deliberately small —
/// the model only needs enough signal to self-correct; the full list
/// (up to [_kMaxPerFile]) travels in the persisted `<crux-lsp>` payload.
const int kSameTurnMaxDiagnostics = 5;
const int kSameTurnMaxMessageChars = 160;

/// [reportDiagnostics] with the same-turn budget applied. Used by the
/// chat turn executor to append a compact error-only block to the
/// tool result sent to the API on the very turn a write/edit ran —
/// closing the loop that previously only opened on the NEXT turn
/// (via the persisted payload replayed from history).
String reportDiagnosticsSameTurn(String file, List<LspDiagnostic> issues) {
  return reportDiagnostics(
    file,
    issues,
    maxPerFile: kSameTurnMaxDiagnostics,
    maxMessageChars: kSameTurnMaxMessageChars,
  );
}

/// Same as [reportDiagnostics] but uses a relative path for display.
String reportDiagnosticsRelative({
  required String fileAbsolute,
  required String workingDirectory,
  required List<LspDiagnostic> issues,
}) {
  final rel = _shortPath(fileAbsolute, workingDirectory);
  return reportDiagnostics(rel, issues);
}

String _shortPath(String absolute, String cwd) {
  if (absolute.startsWith(cwd)) {
    final rel = absolute.substring(cwd.length);
    return rel.startsWith('/') ? rel.substring(1) : rel;
  }
  return absolute;
}

// ══════════════════════════════════════════════════════════════════════
// LSP payload marker — embed the diagnostic list in tool result
// content. The detail view parses it out to render a dedicated
// "LSP errors" section; the model can use the structured data
// directly to self-correct.
// ══════════════════════════════════════════════════════════════════════

/// Encode a list of diagnostics into a JSON body suitable for
/// embedding in the [lspMarkerOpen] / [lspMarkerClose] envelope.
String encodeLspDiagnostics(List<LspDiagnostic> diagnostics) {
  if (diagnostics.isEmpty) return '';
  return jsonEncode(
    diagnostics
        .map(
          (d) => {
            'range': {
              'start': d.range.start.toJson(),
              'end': d.range.end.toJson(),
            },
            'message': d.message,
            'severity': d.severity?.wireValue,
            'source': d.source,
            'code': d.code,
          },
        )
        .toList(growable: false),
  );
}

/// Wrap a JSON body in the [lspMarkerOpen] / [lspMarkerClose]
/// envelope. Returns the empty string for an empty body.
String wrapLspPayload(String jsonBody) {
  if (jsonBody.isEmpty) return '';
  return '$lspMarkerOpen$jsonBody$lspMarkerClose';
}

/// Full helper: encode + wrap a list of diagnostics into a single
/// string ready to append to a tool result's content. Returns the
/// empty string when there are no diagnostics to embed.
String buildLspPayload(List<LspDiagnostic> diagnostics) {
  return wrapLspPayload(encodeLspDiagnostics(diagnostics));
}

/// Parse the magic marker out of a tool result's `content`. Returns
/// a record with the visible content (marker stripped) and the
/// decoded list of diagnostics (empty list if the marker is absent
/// or malformed).
///
/// The parser is lenient: missing or malformed JSON yields an empty
/// diagnostic list rather than an error, since the detail view is
/// best-effort. The visible content is the original `content` with
/// the marker and the surrounding blank lines removed.
({String visible, List<LspDiagnostic> diagnostics}) extractLspPayload(
  String content,
) {
  final openTagIdx = content.indexOf(lspTagOpen);
  if (openTagIdx == -1) {
    return (visible: content, diagnostics: const <LspDiagnostic>[]);
  }
  final closeTagIdx = content.indexOf(lspTagClose, openTagIdx);
  if (closeTagIdx == -1) {
    return (visible: content, diagnostics: const <LspDiagnostic>[]);
  }
  // Body is the JSON between the tag pair, after the leading
  // newline (the marker's body is on its own line).
  final bodyStart = openTagIdx + lspTagOpen.length;
  final body = _extractBody(content, bodyStart, closeTagIdx);
  final diagnostics = _decodeLspPayload(body);
  final visible = _stripMarkerSection(content, openTagIdx, closeTagIdx);
  return (visible: visible, diagnostics: diagnostics);
}

String _extractBody(String content, int bodyStart, int closeTagIdx) {
  // Skip the newline immediately following the open tag, if
  // present (the marker writes `\n<crux-lsp>\n{...}`).
  var start = bodyStart;
  if (start < content.length && content[start] == '\n') start++;
  return content.substring(start, closeTagIdx);
}

String _stripMarkerSection(String content, int openTagIdx, int closeTagIdx) {
  // Cut from the start of the line that contains `<crux-lsp>`
  // through `</crux-lsp>` (inclusive of the close tag). Keeps
  // the surrounding text flowing with a single newline separator.
  final lineStartIdx = content.lastIndexOf('\n', openTagIdx - 1);
  final start = lineStartIdx < 0 ? 0 : lineStartIdx;
  final after = closeTagIdx + lspTagClose.length;
  final before = content.substring(0, start).trimRight();
  final afterText = content.substring(after).trimLeft();
  if (before.isEmpty) return afterText;
  if (afterText.isEmpty) return before;
  return '$before\n$afterText';
}

List<LspDiagnostic> _decodeLspPayload(String body) {
  try {
    final raw = jsonDecode(body);
    if (raw is! List) return const <LspDiagnostic>[];
    return raw
        .whereType<Map>()
        .map((m) => _diagnosticFromMap(m.cast<String, dynamic>()))
        .toList(growable: false);
  } catch (_) {
    return const <LspDiagnostic>[];
  }
}

LspDiagnostic _diagnosticFromMap(Map<String, dynamic> json) {
  final rangeJson =
      (json['range'] as Map?)?.cast<String, dynamic>() ?? const {};
  final startJson =
      (rangeJson['start'] as Map?)?.cast<String, dynamic>() ?? const {};
  final endJson =
      (rangeJson['end'] as Map?)?.cast<String, dynamic>() ?? const {};
  return LspDiagnostic(
    range: LspRange(
      LspPosition(
        startJson['line'] as int? ?? 0,
        startJson['character'] as int? ?? 0,
      ),
      LspPosition(
        endJson['line'] as int? ?? 0,
        endJson['character'] as int? ?? 0,
      ),
    ),
    message: json['message'] as String? ?? '',
    severity: LspDiagnosticSeverity.fromJson(json['severity']),
    source: json['source'] as String?,
    code: json['code'] as String?,
  );
}

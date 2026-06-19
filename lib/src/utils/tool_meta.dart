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

/// Tiny JSON-string-field extractor. Avoids depending on
/// `dart:convert` for a single well-known key shape. Returns
/// `null` if the field is absent or the JSON is malformed.
String? _extractJsonStringField(String json, String field) {
  final match = RegExp(
    '"$field"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"',
  ).firstMatch(json);
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
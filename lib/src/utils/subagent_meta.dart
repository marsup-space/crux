/// Agent-communication metadata persisted on `messages.meta`.
///
/// Commands' Subagent tool results (spawn/assign/send/cancel/read) stamp an
/// `agentBubble` field into [ToolResult.metadata]; the chat executor forwards
/// it into the tool-result row's `meta` column (same wire path as `routing`
/// and `lsp`). The chat-history renderers then parse it back to draw the
/// commander↔worker communication bubbles — verbose mode renders one
/// [AgentBubble] per row, vibe mode aggregates them into the `agents` box.
///
/// The metadata is **never** sent to the LLM.
library;

/// Direction of one communication row, relative to the main agent
/// (the commander). [toAgent] marks commander→worker actions
/// (spawn, assign, send, cancel); [fromAgent] marks worker-facing
/// reads the commander performed (read_worker) and worker reports.
enum AgentBubbleDirection { toAgent, fromAgent }

/// One parsed communication row.
class AgentBubblePayload {
  final AgentBubbleDirection direction;

  /// Durable worker id (`worker-<hex>` / `fork-<hex>`), as persisted.
  final String agentId;

  /// Optional persisted Worker identity (for example `aquila`).
  ///
  /// The UI localizes known constellation ids at render time. The durable id
  /// above remains the addressing key and is retained for legacy fallback.
  final String? agentName;

  /// One of: `spawn`, `assign`, `send`, `cancel`, `read`, `report`.
  final String kind;

  /// Optional human text (task / instruction / reason / report summary).
  final String message;

  /// True when this row re-announces a report that was persisted in an
  /// earlier process and only delivered at startup replay. Renderers must
  /// show it as late history, not fresh progress. Absent on live rows.
  final bool lateReplay;

  /// The re-announced report's ORIGINAL persisted creation time. Null on
  /// live rows and on legacy rows persisted before this field existed.
  final DateTime? originalReportAt;

  const AgentBubblePayload({
    required this.direction,
    required this.agentId,
    this.agentName,
    required this.kind,
    this.message = '',
    this.lateReplay = false,
    this.originalReportAt,
  });
}

/// Upper bound for the message text persisted into the meta blob. The bubble
/// renders one line; anything longer is truncated at persist time so the
/// stored meta stays tiny. The full text lives on the tool-result output.
const int kAgentBubbleMessageMaxChars = 120;

/// Truncate [text] to the persisted budget, appending an ellipsis marker.
/// Newlines collapse to spaces first — the meta blob is a hand-built JSON
/// string literal (see chat_turn_executor's `_jsonString`) that only escapes
/// quotes and backslashes, so a raw newline would corrupt the blob.
String _truncateMessage(String text) {
  final trimmed = text.replaceAll('\n', ' ').trim();
  if (trimmed.length <= kAgentBubbleMessageMaxChars) return trimmed;
  return '${trimmed.substring(0, kAgentBubbleMessageMaxChars)}…';
}

/// Escape into a JSON string literal is NOT done here — the metadata map
/// carries plain strings; serialization (and escaping) happens where the
/// blob is written: chat_turn_executor's `_buildToolResultForPersist` and
/// chat_panel's `persistAgentReport`.

/// Unescape the small subset the persisted blob emits (`\"`, `\\`, `\n`).
String _jsonUnescape(String s) {
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

/// Build the `agentBubble` JSON fragment for [ToolResult.metadata].
/// Returns a map suitable for nesting under the `agentBubble` key.
///
/// [lateReplay] / [originalReportAt] are only set on startup-replay rows;
/// a live row passes the defaults and the fragment stays byte-identical to
/// the pre-late-replay format.
Map<String, dynamic> agentBubbleMetadata({
  required AgentBubbleDirection direction,
  required String agentId,
  String? agentName,
  required String kind,
  String message = '',
  bool lateReplay = false,
  DateTime? originalReportAt,
}) {
  return {
    'agentBubble': {
      'dir': direction == AgentBubbleDirection.toAgent ? 'to' : 'from',
      'agentId': agentId,
      if (agentName != null && agentName.trim().isNotEmpty)
        'agentName': agentName.trim(),
      'kind': kind,
      if (message.trim().isNotEmpty) 'msg': _truncateMessage(message),
      if (lateReplay) 'lateReplay': true,
      if (originalReportAt != null)
        'originalReportAt': originalReportAt.millisecondsSinceEpoch,
    },
  };
}

/// Parse the `agentBubble` payload out of [meta] (the JSON blob stored in
/// `messages.meta`). Returns `null` when the blob has no (or malformed)
/// `agentBubble` field.
AgentBubblePayload? parseAgentBubble(String? meta) {
  if (meta == null || meta.isEmpty) return null;
  final dirMatch = RegExp(
    '"agentBubble"\\s*:\\s*\\{[^{}]*?"dir"\\s*:\\s*"(to|from)"',
  ).firstMatch(meta);
  if (dirMatch == null) return null;
  final direction = dirMatch.group(1) == 'to'
      ? AgentBubbleDirection.toAgent
      : AgentBubbleDirection.fromAgent;

  String? field(String name) {
    final m = RegExp('"$name"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"')
        .firstMatch(meta);
    return m == null ? null : _jsonUnescape(m.group(1)!);
  }

  final agentId = field('agentId');
  if (agentId == null || agentId.isEmpty) return null;
  final kind = field('kind') ?? '';
  final agentName = field('agentName');
  final message = field('msg') ?? '';
  // Numeric fields ride the regex-free path: `lateReplay` is a bare JSON
  // boolean and `originalReportAt` a bare epoch-ms integer, both optional so
  // every pre-existing blob parses exactly as before.
  final lateReplay =
      RegExp(r'"lateReplay"\s*:\s*true').hasMatch(meta) ||
      field('lateReplay') == 'true';
  final tsMatch = RegExp(r'"originalReportAt"\s*:\s*(\d{10,})')
      .firstMatch(meta);
  final originalReportAt = tsMatch == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(int.parse(tsMatch.group(1)!));
  return AgentBubblePayload(
    direction: direction,
    agentId: agentId,
    agentName: agentName,
    kind: kind,
    message: message,
    lateReplay: lateReplay,
    originalReportAt: originalReportAt,
  );
}

/// Short display label for a durable worker id.
///
/// Live ids are `<kind>-<32 hex chars>` (see `SubagentRuntime._defaultId`),
/// too wide for a vibe box row. This folds them to the leading hex slab:
/// `worker-0a1b2c3d…` → `w:0a1b2c3d`. Ids that don't match the durable
/// pattern (short test ids, custom generators) pass through unchanged.
String abbreviateAgentId(String agentId) {
  final m = RegExp('^(?:worker|fork)-(?:[0-9a-f]{4,})\$').firstMatch(agentId);
  if (m == null) return agentId;
  final prefix = agentId.startsWith('fork') ? 'f' : 'w';
  return '$prefix:${agentId.substring(agentId.indexOf('-') + 1, agentId.indexOf('-') + 9)}';
}

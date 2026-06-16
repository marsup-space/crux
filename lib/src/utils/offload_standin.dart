/// Shared parser for the offload stand-in pointer that replaces
/// a large argument's value in a persisted tool_call. The pointer
/// is a single-line string of the form
///   `[offloaded: <N> lines / <size>; recall via offloaded_content(key="<id>")`
/// (optionally with a trailing `; intent: "..."` fragment). It
/// was originally emitted by
/// [ToolExecutor._buildOffloadStandIn] in `tool_executor.dart` and
/// is now consumed in three places: the chat bubble's
/// `collapsedSummary` (for the `+N -M` line diff display on
/// `edit` and `write`), the detail pane's pretty/raw views
/// (to render the "offloaded, unavailable" placeholder), and
/// the raw-view metrics footer.
///
/// Centralizing the parser avoids three slightly-different regex
/// copies drifting out of sync as the pointer format evolves.
library;

/// Parsed fields from an offload stand-in pointer. All fields are
/// nullable because the pointer format is an evolving wire format
/// — new fields may be added without breaking older parsers.
class OffloadStandIn {
  final int lineCount;
  final String sizeStr;
  final String? intent;
  final String? key;

  const OffloadStandIn({
    required this.lineCount,
    required this.sizeStr,
    this.intent,
    this.key,
  });
}

/// Returns the parsed stand-in if [text] starts with the
/// `[offloaded: ...]` prefix, or `null` otherwise. The parser is
/// deliberately tolerant of trailing fragments (intent, future
/// fields) — anything after the `key="..."` segment is ignored.
OffloadStandIn? parseOffloadStandIn(String text) {
  final match = RegExp(
    r'^\[offloaded:\s*(\d+)\s+lines\s*/\s*([\d.]+[KMG]?B)',
  ).firstMatch(text);
  if (match == null) return null;
  final lineCount = int.tryParse(match.group(1)!) ?? 0;
  final sizeStr = match.group(2)!;
  final intentMatch = RegExp(r'intent:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
  final keyMatch = RegExp(r'key="([^"]+)"').firstMatch(text);
  return OffloadStandIn(
    lineCount: lineCount,
    sizeStr: sizeStr,
    intent: intentMatch?.group(1),
    key: keyMatch?.group(1),
  );
}

/// Line count of a (possibly offloaded) string argument.
///
/// If [value] is the original content, this is just the number of
/// `\n`-separated lines (a final unterminated line still counts as
/// a line, matching how `read` reports line counts). If [value]
/// is an offload stand-in pointer, the line count of the
/// *original* content is recovered from the pointer — we never
/// want to count the lines of the stand-in metadata string
/// itself, which would be off by 1 and confusing.
///
/// Returns 0 for an empty or null string, and 1 for a non-empty
/// string with no newlines (a single-line file/edit).
int lineCountOfArg(String? value) {
  if (value == null || value.isEmpty) return 0;
  final standIn = parseOffloadStandIn(value);
  if (standIn != null) {
    return standIn.lineCount;
  }
  return '\n'.allMatches(value).length + 1;
}

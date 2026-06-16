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

/// Returns true when [text] contains an offload stand-in pointer.
///
/// This is intentionally broader than [parseOffloadStandIn], which
/// only parses a whole argument that starts with the stand-in. The
/// write/edit tools use this guard before writing content to disk so
/// a model cannot accidentally paste the history placeholder into a
/// source file.
bool containsOffloadStandIn(String text) {
  return RegExp(
    r'\[offloaded:\s*\d+\s+lines\s*/\s*[\d.]+[KMG]?B\b[^\n]*offloaded_content\(key="[^"]+"\)[^\n]*\]',
  ).hasMatch(text);
}

/// Returns true when the JSON object text in [accumulatedJson]
/// contains a string argument named [argName] whose value contains
/// an offload stand-in pointer.
///
/// The input may be partial streaming JSON. We scan just the target
/// string value prefix instead of decoding the whole object, because
/// the closing quote/brace often has not arrived yet when the early
/// guard can already make a decision.
bool jsonStringArgContainsOffloadStandIn(
  String accumulatedJson,
  String argName,
) {
  final keyMatch = RegExp(
    '"${RegExp.escape(argName)}"\\s*:',
  ).firstMatch(accumulatedJson);
  if (keyMatch == null) return false;

  var i = keyMatch.end;
  while (i < accumulatedJson.length && accumulatedJson.codeUnitAt(i) <= 0x20) {
    i++;
  }
  if (i >= accumulatedJson.length || accumulatedJson[i] != '"') {
    return false;
  }

  final buffer = StringBuffer();
  var escaped = false;
  for (var j = i + 1; j < accumulatedJson.length; j++) {
    final ch = accumulatedJson[j];
    if (escaped) {
      switch (ch) {
        case '"':
          buffer.write('"');
          break;
        case '\\':
          buffer.write('\\');
          break;
        case 'n':
          buffer.write('\n');
          break;
        case 'r':
          buffer.write('\r');
          break;
        case 't':
          buffer.write('\t');
          break;
        default:
          buffer.write(ch);
      }
      escaped = false;
      continue;
    }
    if (ch == '\\') {
      escaped = true;
      continue;
    }
    if (ch == '"') break;
    buffer.write(ch);
  }

  return containsOffloadStandIn(buffer.toString());
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

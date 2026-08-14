// ignore_for_file: implementation_imports
import 'package:nocterm/src/utils/unicode_width.dart';

/// The display width of [text] in terminal columns.
///
/// Thin wrapper over nocterm's `UnicodeWidth.stringWidth`, re-exported so
/// callers don't reach into nocterm's `lib/src` themselves.
int stringWidth(String text) => UnicodeWidth.stringWidth(text);

/// Pad [text] to [width] terminal columns by appending single-column
/// spaces.
///
/// Uses nocterm's `UnicodeWidth.stringWidth` — the same xterm/Unicode-11
/// width table the terminal renders with — so CJK ideographs, kana,
/// emoji, and combining marks all count their real display width. There
/// is no per-locale branch here: "Chinese is two columns" is not a
/// special case, it's just what the width table already answers.
String padToWidth(String text, int width) {
  final current = UnicodeWidth.stringWidth(text);
  if (current >= width) return text;
  return text + (' ' * (width - current));
}

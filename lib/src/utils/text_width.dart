// ignore_for_file: implementation_imports
import 'package:nocterm/src/utils/unicode_width.dart';

/// The display width of [text] in terminal columns.
///
/// Thin wrapper over nocterm's `UnicodeWidth.stringWidth`, re-exported so
/// callers don't reach into nocterm's `lib/src` themselves.
int stringWidth(String text) => UnicodeWidth.stringWidth(text);

/// Clip [text] to at most [maxColumns] display columns, appending an
/// ellipsis (`…`, one column) when anything was cut.
///
/// Widths come from the same Unicode table [stringWidth] uses, so a CJK
/// ideograph costs 2 columns and is never split in half. [maxColumns] is
/// the budget *including* the ellipsis; `0` (or less) yields an empty
/// string, and text that already fits is returned unchanged.
String truncateToWidth(String text, int maxColumns) {
  if (maxColumns <= 0) return '';
  if (stringWidth(text) <= maxColumns) return text;
  final budget = maxColumns - 1;
  final buf = StringBuffer();
  var width = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final charWidth = stringWidth(char);
    if (width + charWidth > budget) break;
    buf.write(char);
    width += charWidth;
  }
  return '$buf…';
}

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

/// `SkillChipBackdrop` — paints `$<skill>` chip backgrounds on
/// top of the chat input's nocterm `TextField`.
///
/// The chat input wraps the [TextField] in a `Stack`:
///   * Layer 1 (bottom): nocterm's [TextField] — handles all
///     editing: typing, deletion, IME composition, paste,
///     cursor blink, click-drag selection. Owns the cursor
///     character and the selection rendering.
///   * Layer 2 (top):    this [SkillChipBackdrop] — paints
///     chip backgrounds only. Read-only.
///
/// The backdrop reads `controller.text` + `controller.selection`
/// and renders a `Column` of `Row`s, where each `Row` is the
/// text of one logical line split into segments:
///   * Plain text segments: rendered as plain [Text] (no
///     background), so the [TextField]'s default text shows
///     through.
///   * Chip segments: rendered as [Text] with
///     `backgroundColor: chipBackground`, painting a colored
///     band over the chip's characters.
///
/// The backdrop leaves a gap at the cursor cell so the
/// [TextField]'s native cursor character (the block/underline
/// painted by the TextField itself) shows through. Without
/// this gap, the backdrop's character would overpaint the
/// cursor and the user would lose their visual anchor.
///
/// This is a Stack overlay, not a custom input widget. The
/// [TextField] keeps ownership of all editing semantics, so
/// IME, blink, and selection work out of the box. The backdrop
/// is pure rendering on top.
library;

import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../services/skills/skill_discovery.dart';
import '../utils/skill_chip_parser.dart';

/// One segment of the backdrop's rendered text.
///
/// [text] is the actual text content. [background] is the
/// cell background to paint; `null` means "leave the cell as
/// the [TextField] painted it" (i.e. transparent from the
/// backdrop's perspective). The widget uses this to skip
/// painting at the cursor position.
class BackdropSegment {
  final String text;
  final Color? background;

  const BackdropSegment(this.text, {this.background});
}

/// Pure function: split [text] (one logical line, no `\n`)
/// into the segments the backdrop should render, given the
/// set of [chips] (from [findAllSkillChips]) and the current
/// [cursor] cell index.
///
/// [cursor] is in the global text coordinate space, not the
/// line-relative one — pass `controller.selection.extentOffset`
/// directly. If the cursor falls inside a chip, that chip's
/// segment is split into pre-cursor + post-cursor so the
/// [TextField]'s cursor character shows through the gap.
List<BackdropSegment> computeBackdropSegments({
  required String text,
  required List<SkillChipMatch> chips,
  required int cursor,
  required Color chipBackground,
}) {
  if (text.isEmpty) return const [];

  if (chips.isEmpty) {
    // No chips in this line — return a single transparent
    // segment (so the backdrop is a no-op, the TextField's
    // text shows through entirely).
    return [BackdropSegment(text)];
  }

  final result = <BackdropSegment>[];
  var pos = 0;
  for (final chip in chips) {
    if (chip.dollarOffset < pos) {
      // Overlapping with a previous chip; skip. (The chip
      // parser dedups by name, so this is defensive.) The
      // overlap region falls through to the trailing-plain-text
      // pass below, so the cells in the overlap aren't
      // highlighted.
      continue;
    }
    if (pos < chip.dollarOffset) {
      // Plain text leading up to the chip.
      result.add(BackdropSegment(
        text.substring(pos, chip.dollarOffset),
      ));
    }
    // Chip text — may be split at the cursor.
    final chipStart = chip.dollarOffset;
    final chipEnd = chip.nameEndOffset;
    final chipText = text.substring(chipStart, chipEnd);
    if (cursor >= chipStart && cursor < chipEnd) {
      // Cursor is inside the chip (or at its first cell). Split
      // into pre/post so the cell at [cursor] is left to the
      // TextField as a gap.
      final splitAt = cursor - chipStart;
      // Skip empty segments so a cursor at chipStart doesn't
      // produce a zero-width pre, and a cursor at chipEnd-1
      // doesn't produce a zero-width post.
      if (splitAt > 0) {
        result.add(BackdropSegment(
          chipText.substring(0, splitAt),
          background: chipBackground,
        ));
      }
      if (splitAt + 1 < chipText.length) {
        result.add(BackdropSegment(
          chipText.substring(splitAt + 1),
          background: chipBackground,
        ));
      }
    } else {
      result.add(BackdropSegment(
        chipText,
        background: chipBackground,
      ));
    }
    pos = chipEnd;
  }
  if (pos < text.length) {
    result.add(BackdropSegment(text.substring(pos)));
  }
  return result;
}

/// Paints `$<skill>` chip backgrounds on top of the chat
/// input's nocterm `TextField`. Read-only — the [TextField]
/// does all the editing.
class SkillChipBackdrop extends StatelessComponent {
  const SkillChipBackdrop({
    super.key,
    required this.controller,
    required this.textStyle,
    required this.chipBackground,
  });

  /// The same controller the [TextField] reads/writes. The
  /// backdrop never mutates the controller — it just observes
  /// text + selection.
  final TextEditingController controller;

  /// Text style for the chip background. Must match the
  /// [TextField]'s `style` so the two renderings align
  /// pixel-for-pixel.
  final TextStyle textStyle;

  /// Background color painted behind chip characters.
  final Color chipBackground;

  @override
  Component build(BuildContext context) {
    final text = controller.text;
    if (text.isEmpty) return const SizedBox.shrink();

    final available = discoverSkills(cwd: Directory.current.path);
    if (available.isEmpty) return const SizedBox.shrink();

    final availableNames = available.map((s) => s.name).toSet();
    final cursor = controller.selection.extentOffset.clamp(0, text.length);

    // Split into logical lines (TextField's `maxLines: null`
    // is honored for explicit `\n`, but soft wrap is not
    // replicated here — for v1 the visual chip might land in
    // the wrong row if the line soft-wraps, but the chip text
    // and its colored band remain visible).
    final lines = text.split('\n');
    var lineStart = 0;
    final rows = <Component>[];
    for (final line in lines) {
      final lineEnd = lineStart + line.length;
      final lineChips = <SkillChipMatch>[];
      for (final c in findAllSkillChips(line, availableNames)) {
        // Re-base the chip's offsets to the full text (the
        // parser only sees the per-line string).
        final globalDollar = lineStart + c.dollarOffset;
        final globalEnd = lineStart + c.nameEndOffset;
        lineChips.add(SkillChipMatch(
          dollarOffset: globalDollar,
          nameEndOffset: globalEnd,
          skillName: c.skillName,
        ));
      }
      if (line.isEmpty && lineChips.isEmpty) {
        // Empty line with no chips — no segment to render.
        lineStart = lineEnd + 1;
        continue;
      }
      final segs = computeBackdropSegments(
        text: line,
        chips: lineChips
            .map((c) => SkillChipMatch(
                  dollarOffset: c.dollarOffset - lineStart,
                  nameEndOffset: c.nameEndOffset - lineStart,
                  skillName: c.skillName,
                ))
            .toList(),
        // Rebase the cursor from the full text to this line. If
        // the cursor is on a different line, this value falls
        // outside the line range and the function's split check
        // (`cursor > chipStart && cursor < chipEnd`) won't fire
        // for any chip on this line — exactly the behaviour we
        // want.
        cursor: cursor - lineStart,
        chipBackground: chipBackground,
      );
      rows.add(_buildLineRow(line, segs, textStyle, cursor, lineStart));
      lineStart = lineEnd + 1; // +1 for the '\n'
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Component _buildLineRow(
    String line,
    List<BackdropSegment> segs,
    TextStyle textStyle,
    int globalCursor,
    int lineStart,
  ) {
    final children = <Component>[];
    for (final seg in segs) {
      if (seg.text.isEmpty) continue;
      // If this segment is split around the cursor, the
      // pre- and post- halves are already separate segments
      // in our list (computeBackdropSegments handles the
      // split). So each BackdropSegment here is either
      // entirely before the cursor, entirely after, or
      // entirely a chip that doesn't contain the cursor.
      // The "gap" at the cursor cell is implicit: the segment
      // that's the post-cursor half starts at char `cursor+1`,
      // so the cell at `cursor` has no Text widget from us.
      children.add(Text(
        seg.text,
        style: seg.background == null
            ? textStyle
            : textStyle.copyWith(backgroundColor: seg.background),
      ));
    }
    return Row(children: children);
  }
}

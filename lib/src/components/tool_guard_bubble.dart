import 'package:nocterm/nocterm.dart';

import 'system_hint_bubble.dart';

/// Semantic kind of a tool guard, used to pick the body text and
/// (later) the glyph for [ToolGuardBubble]. Add new variants here
/// when introducing new guard types — the bubble's `body` getter
/// dispatches on this enum.
///
/// The order of variants is significant: the index is encoded
/// as the `parallelCount` column when the bubble is persisted, so
/// reordering existing values would invalidate every persisted
/// `tool_guard` message. Add new variants at the end.
enum ToolGuardKind {
  /// The tool's `oldString` couldn't be found in the current file
  /// content, or the match was disproportionate. The tool re-read
  /// the file and returned its current content so the model can
  /// retry on the next turn.
  autoRead,

  /// The model called `write` on a file it hasn't read, or the
  /// file changed externally between read and write. The tool
  /// re-read the file and returned its current content so the
  /// model can retry.
  readBeforeWrite,

  /// The model called `write` with a payload dramatically smaller
  /// than the existing file. The tool refused the write to
  /// protect against accidental full-file overwrites. The model
  /// should switch to `edit` for in-place changes, or pass
  /// `force: true` to override.
  sizeMismatch,
}

/// Small inline bubble rendered when a tool call hit a guard
/// (auto-read, read-before-write, size-mismatch). The model's
/// view of the failure is unchanged — the tool's `output` still
/// contains the explanation and any re-read content. This bubble
/// is purely the *user-facing* affordance so the chat history
/// shows what happened at a glance without bloating the
/// tool_call row.
///
/// Inherits the shared glyph + body + colour layout from
/// [SystemHintBubble]; this class supplies the data and the
/// body-text dispatcher.
///
/// Note: the field is named [guardKind] (not `kind`) because the
/// superclass already defines `kind` for the [SystemHintKind]
/// colour bucket.
class ToolGuardBubble extends SystemHintBubble {
  final ToolGuardKind guardKind;
  final String? filePath;

  const ToolGuardBubble({
    super.key,
    required this.guardKind,
    this.filePath,
  });

  @override
  SystemHintKind get kind => SystemHintKind.warning;

  @override
  String get body {
    final label = switch (guardKind) {
      ToolGuardKind.autoRead => 'auto-read',
      ToolGuardKind.readBeforeWrite => 'read-before-write',
      ToolGuardKind.sizeMismatch => 'refused: use edit or pass force',
    };
    final tail = filePath != null && filePath!.isNotEmpty
        ? ': $filePath'
        : '';
    return 'guard: $label$tail';
  }

  @override
  Component build(BuildContext context) {
    // Defensive: render nothing for an unrecognised kind. The
    // chat service should only persist this bubble for a known
    // guard, but a future migration could leave a stale row.
    if (guardKind == ToolGuardKind.autoRead ||
        guardKind == ToolGuardKind.readBeforeWrite ||
        guardKind == ToolGuardKind.sizeMismatch) {
      return super.build(context);
    }
    return const SizedBox.shrink();
  }
}

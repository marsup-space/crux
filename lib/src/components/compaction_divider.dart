// ignore_for_file: implementation_imports

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import '../theme/crux_theme.dart';

/// Inline divider rendered at the position of each `role: 'compaction'`
/// message in the chat history. Marks the boundary between raw history
/// (skipped at the wire layer) and the active conversation.
///
/// Under the "replace from scratch" model, a session can have at
/// most ONE `compaction`-role message at any time — prior ones are
/// physically deleted by [ChatService.createChatLogCompaction]
/// before the new one is inserted. The divider therefore carries
/// no per-session index; every divider in the chat history is the
/// "current" one. If a future model brings back the chain, the
/// index can be re-introduced here.
///
/// In production, the divider is a static marker — the chat log
/// content is opaque to the user, that's the whole point of
/// compaction. In debug mode (when [onTap] is non-null), the divider
/// becomes a hover-styled link that opens a fullpane showing the raw
/// compaction content (the chat log markdown) plus metadata
/// (strategy, source message range, time).
class CompactionDivider extends StatefulComponent {
  /// Tapped when the user clicks the divider. The host (chat panel)
  /// gates this on debug mode so the divider is only clickable when
  /// running with `--debug` / `/debug on`.
  final VoidCallback? onTap;

  const CompactionDivider({super.key, this.onTap});

  @override
  State<CompactionDivider> createState() => _CompactionDividerState();
}

class _CompactionDividerState extends State<CompactionDivider> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final canTap = component.onTap != null;

    final style = canTap && _hovered
        ? TextStyle(
            color: theme.onColor(theme.tldrLink),
            backgroundColor: theme.tldrLink,
            fontWeight: FontWeight.bold,
          )
        : TextStyle(
            // No underline even in debug mode — the `Compaction`
            // label sits between dash fills, and an underline
            // on the dashes themselves made the line look like a
            // hyperlink rather than a structural divider. The
            // hover background + bold are enough affordance to
            // signal "this is clickable".
            color: canTap ? theme.tldrLink : theme.onSurfaceDim,
          );

    // Build the line as a single Text filled out to the full
    // available width: <dashes> <label> <dashes>. The label
    // sits centered by the surrounding dash counts. The
    // LayoutBuilder inside the SizedBox(forced-width) gets the
    // real constraints from the parent ListView, so the line
    // stretches edge-to-edge regardless of how short the label
    // is — the previous version rendered the short
    // "─── Compaction #N ───" string and let it float wherever
    // the parent put it, which looked visually thin next to
    // the full-width MessageBubbles around it.
    final line = LayoutBuilder(
      builder: (ctx, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 0;
        final label = ' Compaction ';
        final labelWidth = UnicodeWidth.stringWidth(label);
        final remaining = maxWidth - labelWidth;
        if (remaining <= 0) {
          // Terminal too narrow to fit even the label. Drop
          // the dashes entirely so the label can take the
          // full width without truncation.
          return Text(label, style: style);
        }
        // Bias the right side so off-by-one differences in
        // odd widths don't drop a dash from the leading edge
        // (which would look misaligned with the "left" edge
        // of the chat history).
        //
        // Use the same continuous box-drawing rule as the relative-time
        // divider (for example, `3 minutes ago`), rather than visibly
        // segmented ASCII hyphens.
        const rule = '─';
        final ruleWidth = UnicodeWidth.stringWidth(rule);
        if (ruleWidth == 0) return Text(label, style: style);
        final leftPad = remaining ~/ (2 * ruleWidth);
        final rightPad = (remaining - leftPad * ruleWidth) ~/ ruleWidth;
        return Text(rule * leftPad + label + rule * rightPad, style: style);
      },
    );

    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: line,
    );

    // Force the divider to take the full ListView width so the
    // LayoutBuilder sees a real maxWidth. Without this the
    // divider would size to its content (a few dozen cells of
    // dash characters), the LayoutBuilder would receive a
    // tight maxWidth, and the line would still float instead
    // of stretching edge-to-edge.
    final stretch = SizedBox(width: double.infinity, child: body);

    if (!canTap) return stretch;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      opaque: false,
      child: GestureDetector(
        onTap: component.onTap,
        behavior: HitTestBehavior.opaque,
        child: stretch,
      ),
    );
  }
}

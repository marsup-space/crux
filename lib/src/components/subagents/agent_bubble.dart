import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../services/subagent/worker_name_localizer.dart';
import '../../theme/crux_theme.dart';
import '../../utils/subagent_meta.dart';
import '../../utils/text_width.dart';
import '../ui/highlighted_markdown_text.dart';

/// Chat-log bubble for one commander↔worker communication row.
///
/// Rendered in BOTH display modes:
///
///  * verbose — chat_history swaps the `role: 'user'` row that carries an
///    `agentBubble` meta payload for this bubble.
///  * vibe — one bubble per row inside the segment's `agents` box (the box
///    reuses [VibeBox] chrome; each row is an [AgentBubble] without its own
///    padding so the rows align inside the box body).
///
/// Row shape (arrow carries the direction, relative to the main agent):
///
///     ❱ spawned w:0a1b2c3d
///     ❱ assigned w:0a1b2c3d: 修复登录页的空指针
///     ❱ sent w:0a1b2c3d: 优先处理 X
///     ❰ read w:0a1b2c3d
///
/// The persisted meta is UI-only — the LLM never sees it; the full task /
/// message text stays on the tool-result output the model reads.
class AgentBubble extends StatelessComponent {
  final AgentBubblePayload payload;

  /// Horizontal padding around the bubble. Verbose-mode rows keep the
  /// chat-history gutter (`horizontal: 1`); rows inside the vibe agents box
  /// pass `0` so they align with the box's own body padding.
  final double padding;

  /// Render as a single, non-flexible line for the vibe agents box.
  ///
  /// The box shrink-wraps its content — [VibeBox] hands every body row an
  /// *unbounded* width — so the verbose layout's `Row` + `Expanded` (which
  /// gives the message a width budget to soft-wrap into) is illegal there:
  /// nocterm's `RenderFlex` raises "children have non-zero flex but
  /// incoming width constraints are unbounded", the row paints as blank,
  /// and the box renders as an empty frame. Inline mode emits one
  /// [RichText] line instead — the same shape the tools box uses — with
  /// the message clipped to [inlineMessageColumns] display columns.
  final bool inline;

  /// Display-column budget for the inline message, ellipsis included.
  /// The full message stays on the tool result the model read; the box row
  /// is a one-line summary sitting next to the think/tools/files boxes.
  static const int inlineMessageColumns = 40;

  final Strings strings;

  const AgentBubble({
    super.key,
    required this.payload,
    required this.strings,
    this.padding = 1,
    this.inline = false,
  });

  /// Localized verb for the payload's kind + direction.
  String _kindLabel() {
    final s = strings;
    return switch (payload.kind) {
      'spawn' => s.t('chat.agent.spawned'),
      'assign' => s.t('chat.agent.assigned'),
      'send' => s.t('chat.agent.sent'),
      'cancel' => s.t('chat.agent.cancelled'),
      'read' => s.t('chat.agent.read'),
      'report' => s.t('chat.agent.reported'),
      'question' => s.t('chat.agent.asked'),
      _ => payload.kind,
    };
  }

  /// The late-replay annotation shown after the headline when this row
  /// re-announces a report from an earlier process. Names the report's
  /// ORIGINAL creation time in local time, so a startup replay of old work
  /// can never read as progress that just happened.
  String? _lateReplayLabel() {
    if (!payload.lateReplay) return null;
    final originalAt = payload.originalReportAt;
    final when = originalAt == null ? '' : _formatTimestamp(originalAt);
    return strings.t('chat.agent.lateReplay', {'time': when});
  }

  static String _formatTimestamp(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// Friendly identity when present; older rows retain their abbreviated ID.
  String _whoLabel() {
    final persisted = payload.agentName;
    if (persisted == null || persisted.trim().isEmpty) {
      return abbreviateAgentId(payload.agentId);
    }
    return const WorkerNameLocalizer().display(persisted, strings.locale);
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final toAgent = payload.direction == AgentBubbleDirection.toAgent;
    final glyph = toAgent ? '❱' : '❰';
    final agentColor = toAgent ? theme.accent : theme.secondary;
    final who = _whoLabel();
    final label = _kindLabel();
    final message = payload.message.trim();

    if (inline) {
      final headline = TextStyle(
        color: agentColor,
        fontWeight: FontWeight.bold,
      );
      final replayLabel = _lateReplayLabel();
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '$glyph ', style: headline),
            TextSpan(text: '$label $who', style: headline),
            if (message.isNotEmpty) ...[
              TextSpan(
                text: ': ',
                style: TextStyle(color: theme.textMuted),
              ),
              TextSpan(
                text: _inlineMessage(message),
                style: TextStyle(color: theme.text),
              ),
            ],
            if (replayLabel != null) ...[
              TextSpan(
                text: '  ',
                style: TextStyle(color: theme.textMuted),
              ),
              TextSpan(
                text: replayLabel,
                style: TextStyle(color: theme.textMuted),
              ),
            ],
          ],
        ),
      );
    }

    final replayLabel = _lateReplayLabel();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$glyph ',
                style: TextStyle(
                  color: agentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '$label $who',
                style: TextStyle(
                  color: agentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (message.isNotEmpty) ...[
                Text(': ', style: TextStyle(color: theme.textMuted)),
                Expanded(child: HighlightedMarkdownText(message)),
              ],
            ],
          ),
          if (replayLabel != null)
            Padding(
              padding: EdgeInsets.only(left: 2),
              child: Text(
                replayLabel,
                style: TextStyle(color: theme.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  /// The message as the inline row shows it: newlines collapse (the row
  /// cannot wrap) and the text is clipped to [inlineMessageColumns].
  static String _inlineMessage(String message) => truncateToWidth(
    message.replaceAll(RegExp(r'\s+'), ' ').trim(),
    inlineMessageColumns,
  );
}

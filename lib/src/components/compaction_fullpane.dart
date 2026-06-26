import 'dart:convert';

import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../theme/crux_theme.dart';
import 'ui/highlighted_markdown_text.dart';

/// Fullpane content that renders a `role: 'compaction'` message in
/// full, for debug inspection.
///
/// Layout, top to bottom:
///
///   1. **Metadata strip** — parsed from [Message.meta]: strategy
///      (`chat-log-v1`), reason (`auto` / `manual`), source message
///      id range, and compacted-at timestamp. Compact one-liner
///      attributes; anything more goes in the body.
///   2. **Body** — the raw [Message.content]. The compaction layer
///      stores this already wrapped in the meta-prompt
///      (`<compacted-session-log>...</compacted-session-log>`); we
///      render it verbatim via [HighlightedMarkdownText] so the
///      chat log markdown renders properly.
///
/// Both panels share a scroll controller so scrolling feels
/// continuous — the metadata stays at top while the body scrolls.
class CompactionFullpane extends StatefulComponent {
  final Message message;

  const CompactionFullpane({super.key, required this.message});

  @override
  State<CompactionFullpane> createState() => _CompactionFullpaneState();
}

class _CompactionFullpaneState extends State<CompactionFullpane> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _parseMeta() {
    final raw = component.message.meta;
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through — return empty map.
    }
    return const {};
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final meta = _parseMeta();
    final msg = component.message;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Metadata strip ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildMetaChips(meta, theme),
          ),
        ),
        Divider(color: theme.divider, height: 1),

        // ── Body ──
        // `useIsolate: true` is critical here: the chat log can
        // be hundreds of KB (or more, for sessions that read
        // large files before compacting), and the sync markdown
        // parse on the main isolate freezes the terminal for
        // several seconds on open. The isolate path is async —
        // the user sees a brief blank moment, then the text
        // appears. Code blocks render unhighlighted in the
        // fullpane (a known limitation of the worker isolate,
        // see `markdown_isolate.dart`), but that's acceptable
        // for a debug view of a chat log.
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
              child: HighlightedMarkdownText(msg.content, useIsolate: true),
            ),
          ),
        ),
      ],
    );
  }

  List<Component> _buildMetaChips(
    Map<String, dynamic> meta,
    CruxThemeData theme,
  ) {
    final chips = <Component>[];
    final strategy = meta['strategy'];
    if (strategy is String) {
      chips.add(_chip('strategy: $strategy', theme));
    }
    final reason = meta['reason'];
    if (reason is String) {
      chips.add(_chip('reason: $reason', theme));
    }
    final startId = meta['sourceStartMessageId'];
    final endId = meta['sourceEndMessageId'];
    if (startId is int && endId is int) {
      chips.add(_chip('covers msg #$startId → #$endId', theme));
    }
    final compactedAt = meta['compactedAt'];
    if (compactedAt is int) {
      final dt = DateTime.fromMillisecondsSinceEpoch(compactedAt);
      chips.add(_chip('at: ${_formatTimestamp(dt)}', theme));
    }
    final preTokens = meta['preTokens'];
    if (preTokens is int) {
      chips.add(_chip('pre-tokens: $preTokens', theme));
    }
    if (chips.isEmpty) {
      chips.add(
        Text(
          '(no metadata)',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    return chips;
  }

  Component _chip(String label, CruxThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      decoration: BoxDecoration(
        color: theme.surfaceVariant,
        borderRadius: BorderRadius.circular(1),
      ),
      child: Text(
        label,
        style: TextStyle(color: theme.onSurfaceVariant),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final yyyy = dt.year.toString().padLeft(4, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$mi:$ss';
  }
}
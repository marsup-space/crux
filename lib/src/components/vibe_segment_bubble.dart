import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import 'dart:convert';

import '../models/message.dart';
import '../services/a2ui/models.dart';
import 'surface_action_bubble.dart';
import '../services/a2ui/surface_catalog.dart';
import '../services/a2ui/surface_controller.dart';
import '../services/llm_provider.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import '../utils/markdown_links.dart';
import '../utils/quick_reply_parser.dart';
import '../utils/strip_skill_bodies.dart';
import 'surface_bubble.dart';
import 'ui/highlighted_markdown_text.dart';
import 'lsp_state_glyph.dart';
import 'vibe_box.dart';
import 'vibe_box_data.dart';
import 'vibe_file_diff.dart';
import 'vibe_file_row.dart';

/// Renders one [VibeSegment]: user line + three aggregated metadata
/// boxes (think, tools, files) + prose line.
///
/// The prose row is rendered through [HighlightedMarkdownText] and
/// receives the same three clickable-token callbacks the verbose
/// `MessageBubble` uses:
///
/// * [onQuickReplyTap] — fired when the user clicks an
///   `ask://label{answer}` (or shorthand `ask://label`) button.
///   Gated to the most-recently-persisted AI segment so older turns'
///   asks don't fire; see [enableQuickReplies] for the exact rule.
/// * [onSessionLinkTap] — fired when the user clicks a
///   `ses://<id>` reference in the prose. Always forwarded (every
///   persisted turn is fair game for session switching).
/// * [onLinkTap] — fired when the user clicks a markdown link of
///   the form `[label](url)`. Always forwarded for the same reason.
///
/// Boxes are omitted when their data is null — no empty bordered
/// region renders. The three boxes are laid out in a [Row] side-by-side;
/// if the joined width exceeds the panel, the caller's [LayoutBuilder]
/// constraints will cause overflow, which the user can scroll to see.
/// (The design doc's horizontal↔vertical flip is future work; v1
/// uses horizontal only.)
class VibeSegmentBubble extends StatelessComponent {
  final VibeSegment segment;

  /// Forwarded to the prose [HighlightedMarkdownText] so any
  /// `ask://label{answer}` token in the segment's prose becomes a
  /// clickable button. Mirrors the same callback on the verbose
  /// `MessageBubble` so the chat panel can use one handler for both
  /// display modes.
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// True when this segment is the most-recently-persisted AI segment
  /// in the open response. The chat history computes this and passes
  /// it down so quick replies are only clickable on the active reply
  /// (older turns' asks are stale and would mislead the user). The
  /// verbose path uses `i == latestAiIndex` for the same purpose;
  /// vibe's walker fans an agent turn into multiple segments, so
  /// the gating happens at the segment level instead of at the
  /// message index.
  ///
  /// The bubble also forces the value to `false` for prose rows
  /// whose `Message.role` is `tool_call` — those are mid-round
  /// remarks, not full replies, and never carry actionable asks.
  final bool enableQuickReplies;

  /// Forwarded for every persisted segment, regardless of whether
  /// it is the "latest closed AI" — switching to a referenced
  /// session is always safe, even for an older turn. When null,
  /// `ses://<id>` references render as plain prose.
  final void Function(int sessionId)? onSessionLinkTap;

  /// Forwarded for every persisted segment, regardless of gating —
  /// a markdown link to docs or an external resource is still
  /// useful to open from older turns. When null, `[label](url)`
  /// links render as plain prose.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Fired when the user activates `open` on a file row. Receives the
  /// file's display path; the chat panel reveals it in the system file
  /// manager. When null, the row's `open` action is omitted.
  final void Function(String path)? onOpenFile;

  /// Fired when the user activates `diff` on a file row. Receives the
  /// file's index within the segment's files list plus the segment's
  /// [ModBoxData] and mutating tool calls, so the chat panel can open
  /// the diff fullpane focused on that file. When null, the row's `diff`
  /// action is omitted.
  final void Function(int fileIndex, ModBoxData mods, List<ToolCallData> calls)?
  onDiffFiles;

  /// Reasoning presets from the session's provider, used to map
  /// the persisted [ThinkBoxData.effort] internal value to its
  /// display label (e.g. `normal` → `adaptive` for MiniMax).
  /// Mirrors the same parameter on [VibeStreamingBubble] and
  /// `MessageBubble` so the live and consolidated bubbles agree
  /// on how the same effort renders. When null/empty, the raw
  /// internal value is used (identity mapping).
  final List<ReasoningPreset> reasoningPresets;

  /// The A2UI surface catalog for rendering `surface` tool calls
  /// inline below the boxes. Null when surfaces aren't available.
  final SurfaceCatalog? surfaceCatalog;

  /// Callback fired when an interactive surface triggers an action.
  final void Function(A2uiAction action)? onSurfaceAction;

  final Strings strings;

  const VibeSegmentBubble({
    required this.segment,
    this.onQuickReplyTap,
    this.enableQuickReplies = false,
    this.onSessionLinkTap,
    this.onLinkTap,
    this.onOpenFile,
    this.onDiffFiles,
    this.reasoningPresets = const [],
    this.surfaceCatalog,
    this.onSurfaceAction,
    this.strings = kEnglishStrings,
    super.key,
  });

  /// Map a persisted effort internal value to its display label
  /// using the provider's reasoning presets. Returns the raw
  /// value when there's no preset entry — same fallback as the
  /// streaming bubble and `MessageBubble` so all three renderers
  /// agree on what the user sees.
  String _displayEffort(String internal) {
    for (final p in reasoningPresets) {
      if (p.internalValue == internal) return p.displayLabel;
    }
    return internal;
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  static String _fmtDuration(int secs) {
    if (secs < 60) return '${secs}s';
    final m = secs ~/ 60;
    final s = secs % 60;
    if (m < 60) return '${m}m ${s}s';
    return '${m ~/ 60}h ${m % 60}m';
  }

  /// Build the prose content, splitting out any inline
  /// `<a2ui>...</a2ui>` tags into live [SurfaceController] widgets.
  ///
  /// Text segments render via [HighlightedMarkdownText]; a2ui segments
  /// parse the JSON payload and render via [SurfaceController] — no
  /// background tint, no extra padding, just the raw component tree
  /// embedded in the prose flow.
  Component _buildProse(BuildContext context, CruxThemeData theme) {
    final content = segment.prose!.content;
    final catalog = surfaceCatalog;

    // Fast path: no a2ui tags → plain markdown text.
    if (catalog == null || !content.contains('<a2ui>')) {
      return HighlightedMarkdownText(
        content,
        onQuickReplyTap: enableQuickReplies && segment.prose!.role == 'ai'
            ? onQuickReplyTap
            : null,
        onSessionLinkTap: onSessionLinkTap,
        onLinkTap: onLinkTap,
      );
    }

    // Split into alternating text/surface segments.
    final segments = _splitA2uiSegments(content);
    if (segments.length == 1 && segments.first.$2 == null) {
      // Only text, no surfaces found (malformed a2ui block).
      return HighlightedMarkdownText(
        content,
        onQuickReplyTap: enableQuickReplies && segment.prose!.role == 'ai'
            ? onQuickReplyTap
            : null,
        onSessionLinkTap: onSessionLinkTap,
        onLinkTap: onLinkTap,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (text, surfaceJson) in segments)
          if (surfaceJson != null)
            // Inline surface: left accent stripe (border.left) +
            // surface background tint + 1-line vertical margin via
            // Padding — the stripe spans the full height of the
            // Container (including its padding area), and the Padding
            // provides the vertical gap above and below.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.surface,
                  border: BoxBorder(
                    left: BorderSide(
                      color: theme.accent.withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: _buildInlineSurface(context, surfaceJson, catalog),
              ),
            )
          else if (text.isNotEmpty)
            HighlightedMarkdownText(
              text,
              onQuickReplyTap: enableQuickReplies && segment.prose!.role == 'ai'
                  ? onQuickReplyTap
                  : null,
              onSessionLinkTap: onSessionLinkTap,
              onLinkTap: onLinkTap,
            ),
      ],
    );
  }

  /// Split [content] into alternating (text, null) and ('', json)
  /// segments at `<a2ui>...</a2ui>` tag boundaries.
  ///
  /// Skips `<a2ui>` tags inside markdown code fences — those are
  /// literal examples, not live surfaces.
  List<(String, String?)> _splitA2uiSegments(String content) {
    final segments = <(String, String?)>[];
    var remaining = content;
    var inCodeFence = false;

    while (true) {
      // Track code fence state before looking for <a2ui>.
      final fenceIdx = remaining.indexOf('```');
      final a2uiIdx = remaining.indexOf('<a2ui>');

      if (a2uiIdx == -1) break; // no more tags

      // If the next ``` fence starts before the next <a2ui>, we're
      // entering a code block — skip past it.
      if (fenceIdx != -1 && fenceIdx < a2uiIdx) {
        inCodeFence = !inCodeFence;
        remaining = remaining.substring(fenceIdx + 3);
        continue;
      }

      if (inCodeFence) {
        // Skip this <a2ui> — it's inside a code block.
        remaining = remaining.substring(a2uiIdx + 6);
        continue;
      }

      final endIdx = remaining.indexOf('</a2ui>', a2uiIdx);
      if (endIdx == -1) {
        // Unclosed tag — the stream ended before </a2ui> arrived.
        // Render the rest as plain text (the surface will never
        // complete), not as a "building" placeholder.
        break;
      }

      // Text before the tag.
      final before = remaining.substring(0, a2uiIdx).trimRight();
      if (before.isNotEmpty) segments.add((before, null));

      // JSON payload between tags.
      final json = remaining.substring(a2uiIdx + 6, endIdx).trim();
      segments.add(('', json));

      remaining = remaining.substring(endIdx + 7);
    }

    // Trailing text after last tag.
    final trailing = remaining.trimRight();
    if (trailing.isNotEmpty) segments.add((trailing, null));

    return segments;
  }

  /// Build an inline surface from a JSON payload string.
  Component _buildInlineSurface(
    BuildContext context,
    String jsonStr,
    SurfaceCatalog catalog,
  ) {
    final theme = CruxTheme.of(context);

    CreateSurface? surface;
    String? parseError;
    try {
      // The agent sometimes wraps the JSON payload in a markdown code
      // fence out of habit (```json ... ```). Strip the fence before
      // parsing — the tag protocol itself is the delimiter, the fence
      // is just noise.
      var payload = jsonStr.trim();
      if (payload.startsWith('```')) {
        final firstNewline = payload.indexOf('\n');
        if (firstNewline != -1) {
          payload = payload.substring(firstNewline + 1);
          if (payload.endsWith('```')) {
            payload = payload.substring(0, payload.length - 3).trim();
          }
        }
      }

      final json = jsonDecode(payload);
      if (json is Map<String, dynamic>) {
        final createSurface = json['createSurface'];
        if (createSurface is Map<String, dynamic>) {
          surface = CreateSurface.fromJson(createSurface);
          if (surface == null) {
            parseError = 'CreateSurface.fromJson returned null';
          }
        } else {
          parseError =
              'no "createSurface" key (keys: ${json.keys.take(5).join(",")})';
        }
      } else {
        parseError = 'json is ${json.runtimeType}, not a Map';
      }
    } catch (e) {
      parseError = '$e';
    }

    if (surface == null) {
      return Text(
        '[invalid a2ui block: $parseError]',
        style: TextStyle(color: theme.error),
      );
    }

    final errors = catalog.validate(surface);
    if (errors.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'surface "${surface.surfaceId}": validation errors',
            style: TextStyle(color: theme.error),
          ),
          for (final e in errors)
            Text('  $e', style: TextStyle(color: theme.textMuted)),
        ],
      );
    }

    final instance = catalog.instanceFor(surface.surfaceId, surface);

    return SurfaceController(
      surface: instance,
      catalog: catalog,
      onAction: onSurfaceAction,
    );
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    final boxes = <Component>[];

    if (segment.think != null) {
      final think = segment.think!;
      final rows = <String>[];
      final secs = think.duration.inMilliseconds / 1000.0;
      rows.add('${secs.toStringAsFixed(1)}s');
      rows.add(formatTokens(think.tokens));
      if (think.effort != null) {
        // Apply the provider's internal→display mapping (e.g.
        // `normal` → `adaptive` for MiniMax). Without this the
        // consolidated segment bubble shows the raw internal
        // value while the streaming bubble next to it shows the
        // mapped label — the same effort rendering two ways in
        // the same view. `ThinkBoxData.effort` is documented as
        // "stored as a raw string because many models override
        // the display value", so the mapping belongs here, not
        // at the walker.
        rows.add(_displayEffort(think.effort!));
      }
      boxes.add(
        VibeBox(
          title: strings.t('chat.vibe.think'),
          bodyRows: rows,
          mutedColor: theme.thinkPrefix,
          activeColor: theme.responsePrefix,
        ),
      );
    }

    if (segment.tools != null) {
      final tools = segment.tools!;
      // Build each row as spans so the LSP outcome glyph (`⎇`) can be
      // color-coded (green/red/yellow) while the rest of the row keeps
      // the box's default text color. Entries with LspState.none get no
      // glyph and render as a plain single-span row.
      final rowSpans = tools.entries.map((e) {
        final label =
            '${e.name} x${e.callCount}: ${formatTokens(e.totalTokens)}';
        final glyph = lspStateGlyphSpan(e.lspState, theme);
        if (glyph == null) return TextSpan(text: label);
        return TextSpan(
          children: [
            TextSpan(text: label),
            glyph,
          ],
        );
      }).toList();
      boxes.add(
        VibeBox(
          title: strings.t('chat.vibe.tools'),
          bodyRowSpans: rowSpans,
          mutedColor: theme.toolPrefix,
          activeColor: theme.accent,
        ),
      );
    }

    if (segment.mods != null) {
      final mods = segment.mods!;
      // One interactive multibutton row per file. Hovering a row swaps
      // it for `open` / `diff` actions (see [VibeFileRow]); the resting
      // row shows the basename plus its own per-file `+N -M` counts from
      // [ModBoxData.files] (falling back to the segment sums for legacy
      // segments that predate per-file entries).
      final rows = <Component>[];
      for (var i = 0; i < mods.paths.length; i++) {
        final path = mods.paths[i];
        final name = p.basename(path);
        final entry = i < mods.files.length ? mods.files[i] : null;
        final added = entry?.linesAdded ?? mods.linesAdded;
        final removed = entry?.linesRemoved ?? mods.linesRemoved;
        // Gate `diff` on reconstructability: when the segment's
        // persisted calls can't rebuild this file's before/after
        // (segments persisted before the walker tracked mutating
        // calls, or rows whose call args lack old/new content), the
        // fullpane would only show its "(no reconstructable
        // changes)" placeholder — disable the action instead of
        // opening that dead end. The MultiButton renders a null
        // callback as a dim, non-clickable segment.
        final diffable = hasReconstructableVibeFileDiff(path, segment.modCalls);
        rows.add(
          VibeFileRow(
            key: ValueKey('vibe-file-$i-$path'),
            name: name.isEmpty ? path : name,
            linesAdded: added,
            linesRemoved: removed,
            strings: strings,
            onOpen: onOpenFile == null ? null : () => onOpenFile!(path),
            onDiff: onDiffFiles == null || !diffable
                ? null
                : () => onDiffFiles!(i, mods, segment.modCalls),
          ),
        );
      }
      if (mods.overflowCount > 0) {
        rows.add(
          Text(
            '+${mods.overflowCount} more files',
            style: TextStyle(color: theme.onSurfaceDim),
          ),
        );
      }
      boxes.add(
        VibeBox(
          title: strings.t('chat.vibe.files'),
          bodyRowComponents: rows,
          mutedColor: theme.success,
          activeColor: theme.warning,
        ),
      );
    }

    // Persisted progress box: the compact echo of a long-running bash
    // call that reported progress signals. Green ✓ on success, warning
    // ✗ on failure — same palette convention as the other boxes (muted
    // color carries the state; the box is never "active" once persisted).
    if (segment.progress != null) {
      final p = segment.progress!;
      final ok = p.exitCode == 0;
      final phase = p.phase ?? 'bash';
      final details = <String>[];
      if (p.peakPercent != null) details.add('${p.peakPercent!.round()}%');
      if (p.bytes > 0) details.add(_fmtBytes(p.bytes));
      if (p.durationSec > 0) details.add(_fmtDuration(p.durationSec));
      final row = ok
          ? '✓ $phase${details.isEmpty ? '' : ' · ${details.join(' · ')}'}'
          : '✗ $phase failed'
                '${p.peakPercent != null ? ' at ${p.peakPercent!.round()}%' : ''}';
      boxes.add(
        VibeBox(
          title: strings.t('chat.vibe.progress'),
          bodyRows: [row],
          mutedColor: ok ? theme.success : theme.warning,
          activeColor: theme.accent,
        ),
      );
    }

    return Column(
      // `stretch` so the column — and therefore the user line, the
      // boxes row, and the agent prose — fills the chat panel's
      // cross-axis (the ListView's `crossAxisExtent`). With
      // `start` (the default), the column shrink-wraps to the widest
      // child: the boxes row sets the width (~60 cells of vibe box
      // chrome), the `You:`/`Crux:` rows expand to that width, and
      // the rest of the panel reads as empty space on the right.
      // That makes the segment look like a left-aligned block on
      // wide screens while the VibeTurnDivider alone spans the full
      // width — a visual mismatch the user reads as "the divider
      // breaks in vibe mode". Stretching the column aligns the
      // user/agent prose with the divider and lets the boxes row
      // sit flush against the left edge as a sub-element of a
      // full-width segment.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User line — only on the first segment of a user turn.
        // Mirrors the verbose `MessageBubble` layout:
        //   `Padding(horizontal: 1) → Row(Text(' You: '), Expanded(Text(userText)))`
        // so the user prose starts at the same column as the
        // agent prose below (column 8 — 1 cell of padding + the
        // 7-char `' You: '` prefix). Earlier this used a single
        // flat `Text(' you: $userText')` whose 6-char `' you: '`
        // prefix put the text at column 7, off by one from the
        // crux row. The `Expanded` also gives the user text a
        // real width budget so terminal-driven soft-wrap aligns
        // continuation lines at the same column as the first
        // line — without it, a long message wrapped flush-left
        // under the bubble's column 1, breaking the visual
        // anchor the prefix establishes. Explicit user newlines
        // keep their natural indentation inside `Expanded`.
        if (segment.showUserMessage)
          // Surface-action messages (submitted A2UI form data) swap the
          // normal user line for a compact chip recap — the raw
          // `action: ...` lines stay in the store for the agent.
          if (A2uiAction.tryParseDisplayString(segment.userMessage.content)
              case final surfaceAction?)
            SurfaceActionBubble(action: surfaceAction)
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ' You: ',
                    style: TextStyle(
                      color: theme.userPrefix,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    // Strip the `Skill: <name>\n<body>` blocks and the
                    // LLM-only `<plan-context>` block appended for the
                    // LLM — the chat log shows only what the user
                    // actually typed (mirrors the verbose `MessageBubble`).
                    child: Text(
                      stripPlanContext(
                        stripSkillBodies(segment.userMessage.content),
                      ).text.trim(),
                    ),
                  ),
                ],
              ),
            ),
        // Boxes (only render if at least one box exists)
        if (boxes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < boxes.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  boxes[i],
                ],
              ],
            ),
          ),
        // A2UI surfaces — rendered inline between the boxes and the
        // prose line. Each `surface` tool call in this segment gets
        // its own [SurfaceBubble].
        if (surfaceCatalog != null && segment.surfaceToolCalls.isNotEmpty)
          for (final tc in segment.surfaceToolCalls)
            SurfaceBubble(
              toolCall: tc,
              catalog: surfaceCatalog!,
              onAction: onSurfaceAction,
            ), // Prose line. Single closing message — its `content` is
        // rendered under the `crux:` prefix. Either `role: 'ai'`
        // (the agent's prose reply) or `role: 'tool_call'` with
        // non-empty content (a mid-round remark that itself
        // closed a prose boundary). Null on a pending or
        // boxes-only segment.
        if (segment.prose != null && segment.prose!.content.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Crux: ',
                  style: TextStyle(
                    color: theme.responsePrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(child: _buildProse(context, theme)),
              ],
            ),
          ),
      ],
    );
  }
}

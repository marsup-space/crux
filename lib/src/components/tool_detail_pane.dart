import 'dart:convert';

import 'package:nocterm/nocterm.dart';
import '../lsp/diagnostic.dart' show errorDiagnostics, extractLspPayload;
import '../lsp/protocol.dart' show LspDiagnostic;
import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../utils/tool_meta.dart';
import '../utils/token_estimate.dart';
import '../utils/tool_metrics_animator.dart';
import 'ui/highlighted_markdown_text.dart';

/// Data needed to render a tool detail fullpane.
class ToolDetailData {
  final ToolCallData toolCall;
  final Message? pairedResult;
  final ToolRegistry? toolRegistry;

  const ToolDetailData({
    required this.toolCall,
    this.pairedResult,
    this.toolRegistry,
  });
}

/// Fullpane content that shows the detailed view of a tool call,
/// with two tabs: Pretty (tool-specific well-presented view)
/// and Raw (full input + output).
class ToolDetailPane extends StatefulComponent {
  final ToolDetailData data;

  const ToolDetailPane({required this.data, super.key});

  @override
  State<ToolDetailPane> createState() => _ToolDetailPaneState();
}

class _ToolDetailPaneState extends State<ToolDetailPane> {
  /// Active tab: 0 = pretty, 1 = raw.
  int _activeTab = 0;

  /// Scroll controllers for each tab.
  final _prettyScrollController = ScrollController();
  final _rawScrollController = ScrollController();

  /// Lerps the `~N tokens` value in the tab-bar header from 0
  /// → final when the pane opens (or when the user navigates
  /// between calls with a different token cost). Same shared
  /// module that drives the streaming bubble and the
  /// collapsed chat row, so the cadence and the format match.
  final ToolMetricsAnimator _animator = ToolMetricsAnimator(
    tickerName: 'toolDetailPane',
  );

  @override
  void initState() {
    super.initState();
    _animator.onAdvance = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void didUpdateComponent(ToolDetailPane old) {
    super.didUpdateComponent(old);
    // The pane is reused across navigations (the parent just
    // swaps `data` and rebuilds). When the user clicks a
    // different tool call in the chat history, forget the
    // previous callId from the animator so the new call's
    // `~N tokens` lerps from 0 instead of inheriting the
    // previous call's settled value.
    final oldCallId = old.data.toolCall.callId;
    final newCallId = component.data.toolCall.callId;
    if (oldCallId != newCallId) {
      _animator.forget(oldCallId);
    }
  }

  @override
  void dispose() {
    _prettyScrollController.dispose();
    _rawScrollController.dispose();
    _animator.dispose();
    super.dispose();
  }

  // ── Resolve the real value for an arg ──

  String _resolveArg(String key, dynamic rawValue) {
    return _formatValue(rawValue);
  }

  // ══════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Tab bar ──
        _buildTabBar(theme),
        Divider(color: theme.divider, height: 1),

        // ── Content area ──
        Expanded(
          child: _activeTab == 0 ? _buildPrettyTab(theme) : _buildRawTab(theme),
        ),
      ],
    );
  }

  // ── Tab bar ──────────────────────────────────────────────────────────

  Component _buildTabBar(CruxThemeData theme) {
    return Row(
      children: [
        _buildTab('Pretty', 0, theme),
        _tabSep(theme),
        _buildTab('Raw', 1, theme),
        const Spacer(),
        _buildQuickMetrics(theme),
      ],
    );
  }

  Component _buildTab(String label, int index, CruxThemeData theme) {
    final active = _activeTab == index;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = index),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        opaque: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          decoration: active
              ? BoxDecoration(
                  color: theme.surfaceVariant,
                  border: BoxBorder.all(
                    color: theme.outline,
                    style: BoxBorderStyle.rounded,
                  ),
                  borderRadius: BorderRadius.circular(1),
                )
              : null,
          child: Text(
            label,
            style: TextStyle(
              color: active ? theme.foreground : theme.onSurfaceDim,
              fontWeight: active ? FontWeight.bold : null,
            ),
          ),
        ),
      ),
    );
  }

  Component _tabSep(CruxThemeData theme) {
    return Text(' │ ', style: TextStyle(color: theme.divider));
  }

  Component _buildQuickMetrics(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final result = component.data.pairedResult;
    final tool = component.data.toolRegistry?.lookup(tc.name);
    String? metric;

    if (tool != null && result != null) {
      final output = result.content;
      if (!output.startsWith('[GUARD]') && !output.startsWith('[AUTOREAD]')) {
        final summary = tool.collapsedSummary(
          tc.input,
          ToolResult(title: '', output: output),
        );
        // Drive the shared animator with the final value so
        // the `~N tokens` half lerps from 0 → summary.totalTokens
        // when the pane opens. The static `summary.text` half
        // (which already carries the `+M -N lines, 1.2KB`
        // shape for write/edit) stays in the same text and
        // is the leading part of the metric; only the `N`
        // animates.
        _animator.setTarget(tc.callId, tokens: summary.totalTokens);
        final metrics = _animator.read(tc.callId);
        final tokensText = metrics == null
            ? '~0 tokens'
            : '~${metrics.displayTokens.round()} tokens';
        // The summary text already encodes the meaningful
        // tool-specific line diff for edit/write (e.g. "+5 -2
        // lines, 1.2KB"). For tools that don't have a custom
        // summary the text falls back to a generic "N lines,
        // size" string which we don't want to duplicate next to
        // the token count, so we suppress it in that case.
        metric = summary.text.isNotEmpty
            ? '${summary.text}, $tokensText'
            : tokensText;
      } else {
        // Guard / auto-read — same as the streaming bubble:
        // render nothing in the header. Forget the entry so
        // the animator doesn't keep a stale target around.
        _animator.forget(tc.callId);
      }
    } else if (result != null) {
      // Tool without a registered handler — fall back to a
      // rough char-based token estimate of the result. Same
      // animation treatment so the value lerps from 0 →
      // estimate when the pane opens.
      final estimated = estimateTokens(result.content);
      _animator.setTarget(tc.callId, tokens: estimated);
      final metrics = _animator.read(tc.callId);
      final shown = metrics == null ? 0 : metrics.displayTokens.round();
      metric = '~$shown tokens';
    } else {
      // No result yet — nothing to animate. Forget the entry
      // so the per-frame scheduler can pause if this is the
      // only thing it was tracking.
      _animator.forget(tc.callId);
    }

    if (metric == null) return const SizedBox.shrink();
    return Text(metric, style: TextStyle(color: theme.onSurfaceDim));
  }

  // ══════════════════════════════════════════════════════════════════════
  // Pretty tab — tool-specific well-presented views
  // ══════════════════════════════════════════════════════════════════════

  Component _buildPrettyTab(CruxThemeData theme) {
    final tc = component.data.toolCall;
    switch (tc.name) {
      case 'write':
        return _buildPrettyWrite(theme);
      case 'edit':
        return _buildPrettyEdit(theme);
      case 'bash':
      case 'cmd':
      case 'powershell':
        return _buildPrettyShell(theme);
      case 'read':
        return _buildPrettyRead(theme);
      case 'grep':
        return _buildPrettyGrep(theme);
      case 'glob':
        return _buildPrettyGlob(theme);
      case 'webfetch':
        return _buildPrettyWebfetch(theme);
      default:
        return _buildPrettyGeneric(theme);
    }
  }

  // ── Write ────────────────────────────────────────────────────────────

  Component _buildPrettyWrite(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final filePath = tc.input['filePath']?.toString() ?? '';
    final intent = tc.input['intent']?.toString() ?? '';
    final content = _resolveArg('content', tc.input['content']);
    final language = _languageFromPath(filePath);

    final children = <Component>[];

    // Header
    children.add(_fileHeader(filePath, intent, theme));

    // Content — syntax-highlighted code block. The persist path
    // embeds an LSP payload marker at the end of the result's
    // content; we strip it from the displayed block but render the
    // diagnostics in a dedicated section below.
    final result = component.data.pairedResult;
    final lsp = result == null
        ? (visible: content, diagnostics: const <LspDiagnostic>[])
        : extractLspPayload(result.content);

    if (lsp.visible.isEmpty) {
      children.add(_dimText('  (empty)', theme));
    } else {
      children.add(
        Expanded(
          child: _scrollableCodeBlock(lsp.visible, language ?? '', theme),
        ),
      );
    }

    if (lsp.diagnostics.isNotEmpty) {
      children.add(_lspErrorsSection(filePath, lsp.diagnostics, theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ── Edit ─────────────────────────────────────────────────────────────

  Component _buildPrettyEdit(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final filePath = tc.input['filePath']?.toString() ?? '';
    final intent = tc.input['intent']?.toString() ?? '';
    final oldStr = _resolveArg('oldString', tc.input['oldString']);
    final newStr = _resolveArg('newString', tc.input['newString']);
    final replaceAll = tc.input['replaceAll'] == true;
    final language = _languageFromPath(filePath);

    final children = <Component>[];

    // Header
    children.add(_fileHeader(filePath, intent, theme));
    if (replaceAll) {
      children.add(_banner('⟳ Replace all occurrences', theme.info, theme));
    }

    // Old → New diff-style view
    children.add(_sectionHeading('Old', theme, color: theme.error));
    if (oldStr.isEmpty) {
      children.add(_dimText('  (empty)', theme));
    } else {
      children.add(
        Container(
          padding: const EdgeInsets.only(left: 1),
          child: _inlineCodeBlock(oldStr, language ?? '', theme),
        ),
      );
    }

    children.add(Divider(color: theme.dividerDim, height: 1));
    children.add(_sectionHeading('New', theme, color: theme.success));
    if (newStr.isEmpty) {
      children.add(_dimText('  (empty)', theme));
    } else {
      children.add(
        Container(
          padding: const EdgeInsets.only(left: 1),
          child: _inlineCodeBlock(newStr, language ?? '', theme),
        ),
      );
    }

    // LSP errors section (if any diagnostics were attached to the
    // tool result). The persist path embeds the diagnostic list
    // in the result's content as a `<crux-lsp>...</crux-lsp>` JSON
    // block; we parse it here and render a dedicated section so
    // the user can see what the language server reported without
    // having to switch to the raw tab.
    final result = component.data.pairedResult;
    if (result != null) {
      final lsp = extractLspPayload(result.content);
      if (lsp.diagnostics.isNotEmpty) {
        children.add(Divider(color: theme.dividerDim, height: 1));
        children.add(_lspErrorsSection(filePath, lsp.diagnostics, theme));
      }
    }

    return Scrollbar(
      controller: _prettyScrollController,
      thumbVisibility: true,
      thumbColor: theme.onSurfaceDim.withOpacity(0.4),
      trackColor: theme.surfaceVariant.withOpacity(0.3),
      child: SingleChildScrollView(
        controller: _prettyScrollController,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  // ── Shell (bash / cmd / powershell) ──────────────────────────────────

  Component _buildPrettyShell(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final command = tc.input['command']?.toString() ?? '';
    final intent = tc.input['intent']?.toString() ?? '';
    final result = component.data.pairedResult;
    final output = result?.content ?? '';

    final children = <Component>[];

    // Header: command + intent
    children.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Text(
              '\$ ',
              style: TextStyle(
                color: theme.success,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: Text(
                command,
                style: TextStyle(
                  color: theme.foreground,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (intent.isNotEmpty) {
      children.add(_labelValue('Intent', intent, theme, valueItalic: true));
    }

    // Exit code from metadata
    final exitCode = result != null ? _extractExitCode(result.content) : null;
    if (exitCode != null && exitCode != 0) {
      children.add(_banner('✗ Exit code: $exitCode', theme.error, theme));
    } else if (result != null) {
      children.add(_banner('✓ Completed', theme.success, theme));
    }

    children.add(Divider(color: theme.dividerDim, height: 1));

    // Output — the actual command output, shown in a code block
    if (output.isNotEmpty) {
      // Strip the [exit code: N] trailer that the tool appends
      final displayOutput = _stripExitCodeLine(output);
      children.add(
        Expanded(child: _scrollableCodeBlock(displayOutput, '', theme)),
      );
    } else {
      children.add(_dimText('  (no output)', theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ── Read ─────────────────────────────────────────────────────────────

  Component _buildPrettyRead(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final filePath = tc.input['filePath']?.toString() ?? '';
    final result = component.data.pairedResult;
    final output = result?.content ?? '';
    final language = _languageFromPath(filePath);

    final children = <Component>[];

    // Header
    children.add(_fileHeader(filePath, '', theme));

    // File content (output already has line numbers from the tool)
    if (output.isNotEmpty) {
      children.add(
        Expanded(child: _scrollableCodeBlock(output, language ?? '', theme)),
      );
    } else {
      children.add(_dimText('  (no content)', theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ── Grep ─────────────────────────────────────────────────────────────

  Component _buildPrettyGrep(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final pattern = tc.input['pattern']?.toString() ?? '';
    final path = tc.input['path']?.toString() ?? '';
    final include = tc.input['include']?.toString() ?? '';
    final result = component.data.pairedResult;
    final output = result?.content ?? '';

    final children = <Component>[];

    // Header
    final headerParts = <TextSpan>[];
    headerParts.add(
      TextSpan(
        text: 'Pattern: ',
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    headerParts.add(
      TextSpan(
        text: '/$pattern/',
        style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
      ),
    );
    if (path.isNotEmpty) {
      headerParts.add(
        TextSpan(
          text: '  in $path',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    if (include.isNotEmpty) {
      headerParts.add(
        TextSpan(
          text: '  filter: $include',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    children.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Expanded(
              child: RichText(text: TextSpan(children: headerParts)),
            ),
          ],
        ),
      ),
    );

    // Match count
    final totalMatches = result?.content.isNotEmpty == true
        ? '\n'.allMatches(output).length + 1
        : 0;
    children.add(_labelValue('Matches', '$totalMatches', theme));

    children.add(Divider(color: theme.dividerDim, height: 1));

    // Results
    if (output.isNotEmpty) {
      children.add(Expanded(child: _scrollableCodeBlock(output, '', theme)));
    } else {
      children.add(_dimText('  (no matches)', theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ── Glob ─────────────────────────────────────────────────────────────

  Component _buildPrettyGlob(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final pattern = tc.input['pattern']?.toString() ?? '';
    final path = tc.input['path']?.toString() ?? '';
    final result = component.data.pairedResult;
    final output = result?.content ?? '';

    final children = <Component>[];

    // Header
    final headerParts = <TextSpan>[];
    headerParts.add(
      TextSpan(
        text: 'Pattern: ',
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    headerParts.add(
      TextSpan(
        text: pattern,
        style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
      ),
    );
    if (path.isNotEmpty) {
      headerParts.add(
        TextSpan(
          text: '  in $path',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    children.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Expanded(
              child: RichText(text: TextSpan(children: headerParts)),
            ),
          ],
        ),
      ),
    );

    final fileCount = output.isNotEmpty
        ? '\n'.allMatches(output).length + 1
        : 0;
    children.add(_labelValue('Files', '$fileCount', theme));

    children.add(Divider(color: theme.dividerDim, height: 1));

    if (output.isNotEmpty) {
      children.add(Expanded(child: _scrollableCodeBlock(output, '', theme)));
    } else {
      children.add(_dimText('  (no files matched)', theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ── WebFetch ─────────────────────────────────────────────────────────

  Component _buildPrettyWebfetch(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final url = tc.input['url']?.toString() ?? '';
    final result = component.data.pairedResult;
    final output = result?.content ?? '';

    final children = <Component>[];

    // Header
    children.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Text(
              'URL: ',
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: Text(
                url,
                style: TextStyle(
                  color: theme.mdLink,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Inline UI hints from `messages.meta`. The LLM never sees
    // these — they're rendered only here and in the collapsed
    // bubble so the user knows the response came back through
    // the system proxy (or whatever the tool layer wants to
    // surface). Surfaces as a colored badge above the body.
    final metaHint = _metaHint(result?.meta, theme);
    if (metaHint != null) {
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: metaHint,
        ),
      );
    }

    children.add(Divider(color: theme.dividerDim, height: 1));

    // Content
    if (output.isNotEmpty) {
      children.add(
        Expanded(
          child: Scrollbar(
            controller: _prettyScrollController,
            thumbVisibility: true,
            thumbColor: theme.onSurfaceDim.withOpacity(0.4),
            trackColor: theme.surfaceVariant.withOpacity(0.3),
            child: SingleChildScrollView(
              controller: _prettyScrollController,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                child: HighlightedMarkdownText(output),
              ),
            ),
          ),
        ),
      );
    } else {
      children.add(_dimText('  (no content)', theme));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// Builds the user-visible hint badge for a tool result whose
  /// persisted `meta` blob carries routing (or other) information.
  /// Returns `null` when there is nothing to surface. Mirrors the
  /// same parser used by the collapsed bubble in
  /// `message_bubble.dart` so both views agree.
  Component? _metaHint(String? meta, CruxThemeData theme) {
    final routing = parseToolRouting(meta);
    if (routing == null) return null;
    switch (routing.value) {
      case 'system-proxy':
        return Row(
          children: [
            Text(
              '  ·  ',
              style: TextStyle(color: theme.onSurfaceDim),
            ),
            Text(
              'via system proxy ',
              style: TextStyle(
                color: theme.warning,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '(direct connection failed; retried through the system proxy)',
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        );
      default:
        return Text(
          '  ·  ${routing.value}',
          style: TextStyle(color: theme.onSurfaceDim),
        );
    }
  }

  // ── Generic fallback ─────────────────────────────────────────────────

  Component _buildPrettyGeneric(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final tool = component.data.toolRegistry?.lookup(tc.name);
    final intent = _intentLabel(tc, tool);

    final children = <Component>[];

    children.add(
      _labelValue(
        'Tool',
        _capitalize(tc.name),
        theme,
        valueColor: theme.toolPrefix,
        valueBold: true,
      ),
    );
    if (intent.isNotEmpty) {
      children.add(_labelValue('Intent', intent, theme, valueItalic: true));
    }

    children.add(Divider(color: theme.dividerDim, height: 1));
    children.add(_sectionHeading('Arguments', theme));

    if (tc.input.isEmpty) {
      children.add(_dimText('(no arguments)', theme));
    } else {
      for (final entry in tc.input.entries) {
        children.add(_buildArgBlock(entry.key, entry.value, theme));
      }
    }

    // Result
    final result = component.data.pairedResult;
    if (result != null && result.content.isNotEmpty) {
      children.add(Divider(color: theme.dividerDim, height: 1));
      children.add(_sectionHeading('Result', theme));
      children.add(
        Container(
          padding: const EdgeInsets.only(left: 1),
          child: HighlightedMarkdownText(result.content),
        ),
      );
    }

    return Scrollbar(
      controller: _prettyScrollController,
      thumbVisibility: true,
      thumbColor: theme.onSurfaceDim.withOpacity(0.4),
      trackColor: theme.surfaceVariant.withOpacity(0.3),
      child: ListView(controller: _prettyScrollController, children: children),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // Raw tab — shows all input args + full output
  // ══════════════════════════════════════════════════════════════════════

  Component _buildRawTab(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final tool = component.data.toolRegistry?.lookup(tc.name);
    final result = component.data.pairedResult;

    final children = <Component>[];

    // ── Input section ──
    children.add(_sectionLabel('Input', theme));
    children.add(
      _labelValue(
        'Tool',
        _capitalize(tc.name),
        theme,
        valueColor: theme.toolPrefix,
        valueBold: true,
      ),
    );

    final intent = _intentLabel(tc, tool);
    if (intent.isNotEmpty) {
      children.add(_labelValue('Intent', intent, theme, valueItalic: true));
    }

    if (tc.input.isEmpty) {
      children.add(_dimText('  (no arguments)', theme));
    } else {
      for (final entry in tc.input.entries) {
        children.add(_buildArgBlock(entry.key, entry.value, theme));
      }
    }

    // ── Output section ──
    if (result != null) {
      children.add(Divider(color: theme.divider, height: 1));
      children.add(_sectionLabel('Output', theme));

      final output = result.content;
      final isGuard = output.startsWith('[GUARD]');
      final isGuardAborted = output.contains(
        '[Crux system note — tool-call early abort]',
      );
      final isAutoRead = output.startsWith('[AUTOREAD]');
      if (isGuardAborted) {
        children.add(
          _banner('Aborted mid-stream by Crux (early abort)', theme.warning, theme),
        );
      } else if (isGuard) {
        children.add(
          _banner('⚠ ${_guardReason(output)}', theme.warning, theme),
        );
      } else if (isAutoRead) {
        children.add(
          _banner('↻ ${_autoReadReason(output)}', theme.info, theme),
        );
      }

      if (output.isNotEmpty) {
        children.add(
          Container(
            padding: const EdgeInsets.only(left: 1),
            child: HighlightedMarkdownText(output),
          ),
        );
      } else {
        children.add(_dimText('  (empty)', theme));
      }
    } else {
      children.add(Divider(color: theme.divider, height: 1));
      children.add(_sectionLabel('Output', theme));
      children.add(_dimText('  (no result yet)', theme));
    }

    return Scrollbar(
      controller: _rawScrollController,
      thumbVisibility: true,
      thumbColor: theme.onSurfaceDim.withOpacity(0.4),
      trackColor: theme.surfaceVariant.withOpacity(0.3),
      child: ListView(controller: _rawScrollController, children: children),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // Shared building blocks
  // ══════════════════════════════════════════════════════════════════════

  /// File path header used by write, edit, read.
  Component _fileHeader(String filePath, String intent, CruxThemeData theme) {
    final spans = <TextSpan>[];
    spans.add(
      TextSpan(
        text: '📄 ', // file icon
        style: TextStyle(color: theme.foreground),
      ),
    );
    spans.add(
      TextSpan(
        text: filePath,
        style: TextStyle(color: theme.foreground, fontWeight: FontWeight.bold),
      ),
    );
    if (intent.isNotEmpty) {
      spans.add(
        TextSpan(
          text: '  $intent',
          style: TextStyle(
            color: theme.onSurfaceDim,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        children: [
          Expanded(
            child: RichText(text: TextSpan(children: spans)),
          ),
        ],
      ),
    );
  }

  /// Section label with a colored background bar.
  Component _sectionLabel(String label, CruxThemeData theme) {
    return Container(
      decoration: BoxDecoration(color: theme.surfaceVariant),
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        label,
        style: TextStyle(color: theme.foreground, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// A full-width scrollable code block with syntax highlighting.
  Component _scrollableCodeBlock(
    String content,
    String language,
    CruxThemeData theme,
  ) {
    final fence = language.isNotEmpty
        ? '```$language\n$content\n```'
        : '```\n$content\n```';
    return Scrollbar(
      controller: _prettyScrollController,
      thumbVisibility: true,
      thumbColor: theme.onSurfaceDim.withOpacity(0.4),
      trackColor: theme.surfaceVariant.withOpacity(0.3),
      child: SingleChildScrollView(
        controller: _prettyScrollController,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: HighlightedMarkdownText(
            fence,
            styleSheet: HighlightMarkdownStyleSheet.fromTheme(theme),
          ),
        ),
      ),
    );
  }

  /// An inline (non-scrollable) code block. Used when the code is
  /// inside a larger scrollable area (e.g. edit's old/new).
  Component _inlineCodeBlock(
    String content,
    String language,
    CruxThemeData theme,
  ) {
    final fence = language.isNotEmpty
        ? '```$language\n$content\n```'
        : '```\n$content\n```';
    return HighlightedMarkdownText(
      fence,
      styleSheet: HighlightMarkdownStyleSheet.fromTheme(theme),
    );
  }

  // ── Arg rendering (used by Raw tab and Generic pretty) ──────────────

  Component _buildArgBlock(String key, dynamic value, CruxThemeData theme) {
    final valueStr = _formatValue(value);
    return _buildArgBlockWithContent(key, valueStr, theme);
  }

  Component _buildArgBlockWithContent(
    String key,
    String valueStr,
    CruxThemeData theme,
  ) {
    final isLong = valueStr.length > 80 || valueStr.contains('\n');
    final language = _languageForArgKey(key);

    final headerSpans = <TextSpan>[];
    headerSpans.add(
      TextSpan(
        text: '$key ',
        style: TextStyle(color: theme.foreground, fontWeight: FontWeight.bold),
      ),
    );
    if (!isLong) {
      headerSpans.add(
        TextSpan(
          text: valueStr,
          style: TextStyle(color: theme.foreground),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RichText(text: TextSpan(children: headerSpans)),
              ),
            ],
          ),
        ),
        if (isLong)
          Container(
            padding: const EdgeInsets.only(left: 2),
            child: _inlineCodeBlock(valueStr, language, theme),
          ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════

  // ── LSP errors section ─────────────────────────────────────────────
  //
  // Rendered when the tool result carries an LSP diagnostic list
  // (embedded as a `<crux-lsp>` JSON block by the chat_service
  // persist path). Each diagnostic shows severity, 1-based
  // line:col, source (e.g. "dart"), and the message text.
  Component _lspErrorsSection(
    String filePath,
    List<LspDiagnostic> diagnostics,
    CruxThemeData theme,
  ) {
    final errors = errorDiagnostics(diagnostics);
    final shown = errors.take(20).toList();
    final more = errors.length - shown.length;
    final word = errors.length == 1 ? 'error' : 'errors';

    final children = <Component>[];
    children.add(
      _sectionHeading('LSP · ${errors.length} $word', theme, color: theme.error),
    );
    if (filePath.isNotEmpty) {
      children.add(_dimText('  in $filePath', theme));
    }
    for (final d in shown) {
      children.add(_lspErrorRow(d, theme));
    }
    if (more > 0) {
      children.add(_dimText('  ... and $more more', theme));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Component _lspErrorRow(LspDiagnostic d, CruxThemeData theme) {
    final line = d.range.start.line + 1;
    final col = d.range.start.character + 1;
    final where = d.source ?? 'lsp';
    final message = d.message;
    return Container(
      padding: const EdgeInsets.only(left: 2, top: 0, bottom: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '✗ ',
            style: TextStyle(color: theme.error, fontWeight: FontWeight.bold),
          ),
          Text('[$where ', style: TextStyle(color: theme.onSurfaceDim)),
          Text(
            '$line:$col',
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text('] $message', style: TextStyle(color: theme.foreground)),
        ],
      ),
    );
  }

  Component _labelValue(
    String label,
    String value,
    CruxThemeData theme, {
    Color? valueColor,
    bool valueBold = false,
    bool valueItalic = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? theme.foreground,
                fontWeight: valueBold ? FontWeight.bold : null,
                fontStyle: valueItalic ? FontStyle.italic : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Component _sectionHeading(String text, CruxThemeData theme, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? theme.onSurfaceDim,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Component _banner(String text, Color color, CruxThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  Component _dimText(String text, CruxThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        text,
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  String _languageForArgKey(String key) {
    switch (key) {
      case 'content':
      case 'oldString':
      case 'newString':
        return _detectLanguage() ?? '';
      case 'command':
        return 'bash';
      default:
        return '';
    }
  }

  String? _detectLanguage() {
    final tc = component.data.toolCall;
    const pathKeys = ['filePath', 'file_path', 'path'];
    for (final key in pathKeys) {
      final path = tc.input[key];
      if (path is String && path.isNotEmpty) {
        return _languageFromPath(path);
      }
    }
    return null;
  }

  /// Extract exit code from the tool result output line like
  /// `[exit code: N]`. Returns null if not found.
  int? _extractExitCode(String output) {
    final match = RegExp(r'\[exit code:\s*(\d+)\]').firstMatch(output);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  /// Strip the `[exit code: N]` line from shell output.
  String _stripExitCodeLine(String output) {
    return output.replaceFirst(RegExp(r'\n?\[exit code:\s*\d+\]\s*$'), '');
  }

  String _formatValue(dynamic value) {
    if (value is String) return value;
    if (value is Map || value is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(value);
      } catch (_) {
        return value.toString();
      }
    }
    return value.toString();
  }

  String _intentLabel(ToolCallData tc, ToolDef? tool) {
    if (tool is IntentionalTool) {
      return tool.intentFromArgs(tc.input) ?? '';
    }
    return '';
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  String _guardReason(String content) {
    const prefix = '[GUARD] Write was BLOCKED';
    if (!content.startsWith(prefix)) return 'Guard triggered';
    final rest = content.substring(prefix.length);
    final dash = rest.indexOf('\u2014');
    if (dash == -1) return 'Guard triggered';
    final reason = rest.substring(dash + 1);
    final dash2 = reason.indexOf('\u2014');
    if (dash2 != -1) {
      return 'Guard: ${reason.substring(0, dash2).trim()}';
    }
    final period = reason.indexOf('.');
    final trimmed = (period == -1 ? reason : reason.substring(0, period))
        .trim();
    return trimmed.isEmpty ? 'Guard triggered' : 'Guard: $trimmed';
  }

  String _autoReadReason(String content) {
    const prefix = '[AUTOREAD] No changes were made';
    if (!content.startsWith(prefix)) return 'Auto-read';
    final rest = content.substring(prefix.length);
    final dash = rest.indexOf('\u2014');
    if (dash == -1) return 'Auto-read';
    final reason = rest.substring(dash + 1);
    final period = reason.indexOf('.');
    final trimmed = (period == -1 ? reason : reason.substring(0, period))
        .trim();
    return trimmed.isEmpty ? 'Auto-read' : 'Auto-read: $trimmed';
  }

  static String? _languageFromPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot >= path.length - 1) return null;
    final ext = path.substring(dot + 1).toLowerCase();
    return _extToLanguage[ext];
  }

  static const _extToLanguage = <String, String>{
    'dart': 'dart',
    'py': 'python',
    'js': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'jsx': 'javascript',
    'rs': 'rust',
    'go': 'go',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'swift': 'swift',
    'html': 'html',
    'htm': 'html',
    'css': 'css',
    'scss': 'css',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'sql': 'sql',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'toml': 'toml',
    'xml': 'xml',
    'md': 'markdown',
    'c': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'cxx': 'cpp',
    'h': 'c',
    'hpp': 'cpp',
    'rb': 'ruby',
    'php': 'php',
    'lua': 'lua',
    'pl': 'perl',
    'r': 'r',
    'scala': 'scala',
    'ex': 'elixir',
    'exs': 'elixir',
    'erl': 'erlang',
    'hs': 'haskell',
    'clj': 'clojure',
    'vue': 'html',
    'svelte': 'html',
  };
}

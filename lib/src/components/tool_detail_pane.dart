import 'dart:convert';

import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../utils/token_estimate.dart';
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

/// Parsed metrics from an offload stand-in pointer string.
class _OffloadStandIn {
  final int lineCount;
  final String sizeStr;
  final String? intent;

  const _OffloadStandIn({
    required this.lineCount,
    required this.sizeStr,
    this.intent,
  });
}

/// Fullpane content that shows the detailed view of a tool call,
/// with tabbed Input / Output / Summary views.
class ToolDetailPane extends StatefulComponent {
  final ToolDetailData data;

  const ToolDetailPane({
    required this.data,
    super.key,
  });

  @override
  State<ToolDetailPane> createState() => _ToolDetailPaneState();
}

class _ToolDetailPaneState extends State<ToolDetailPane> {
  /// Active tab: 0 = input, 1 = output, 2 = summary.
  int _activeTab = 1; // default to output — most useful view

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
          child: _buildContent(theme),
        ),
      ],
    );
  }

  // ─── Tab bar ────────────────────────────────────────────────────────

  Component _buildTabBar(CruxThemeData theme) {
    final result = component.data.pairedResult;
    return Row(
      children: [
        _buildTab('Input', 0, theme),
        _tabSep(theme),
        _buildTab('Output', 1, theme),
        if (result != null) ...[
          _tabSep(theme),
          _buildTab('Summary', 2, theme),
        ],
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
        metric = '~${summary.totalTokens} tokens';
      }
    } else if (result != null) {
      metric = '~${estimateTokens(result.content)} tokens';
    }

    if (metric == null) return const SizedBox.shrink();
    return Text(metric, style: TextStyle(color: theme.onSurfaceDim));
  }

  // ─── Content router ────────────────────────────────────────────────

  Component _buildContent(CruxThemeData theme) {
    switch (_activeTab) {
      case 0:
        return _buildInputTab(theme);
      case 1:
        return _buildOutputTab(theme);
      case 2:
        return _buildSummaryTab(theme);
      default:
        return _buildOutputTab(theme);
    }
  }

  // ─── Input tab ─────────────────────────────────────────────────────

  Component _buildInputTab(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final tool = component.data.toolRegistry?.lookup(tc.name);

    final children = <Component>[];

    // Tool name
    children.add(_labelValue(
      'Tool',
      _capitalize(tc.name),
      theme,
      valueColor: theme.toolPrefix,
      valueBold: true,
    ));

    // Intent
    final intent = _intentLabel(tc, tool);
    if (intent.isNotEmpty) {
      children.add(_labelValue(
        'Intent',
        intent,
        theme,
        valueItalic: true,
      ));
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

    return ListView(children: children);
  }

  Component _buildArgBlock(String key, dynamic value, CruxThemeData theme) {
    final valueStr = _formatValue(value);

    // For LargePayloadTool offloadable args (write's content, edit's
    // oldString/newString), never dump the full value into the detail
    // pane — even "small" writes/edits can be distracting when shown
    // inline, and after offloading the value is a stand-in pointer
    // that should also be summarised rather than displayed raw.
    final tc = component.data.toolCall;
    final tool = component.data.toolRegistry?.lookup(tc.name);
    if (tool is LargePayloadTool &&
        tool.offloadableArgs.contains(key)) {
      return _buildLargeArgSummary(key, valueStr, theme);
    }

    final isLong = valueStr.length > 80 || valueStr.contains('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$key ',
                style: TextStyle(
                  color: theme.foreground,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!isLong)
                Expanded(
                  child: Text(
                    valueStr,
                    style: TextStyle(color: theme.foreground),
                  ),
                ),
            ],
          ),
        ),
        if (isLong)
          Container(
            padding: const EdgeInsets.only(left: 2),
            child: HighlightedMarkdownText(
              '```\n$valueStr\n```',
              styleSheet: HighlightMarkdownStyleSheet.fromTheme(theme),
            ),
          ),
      ],
    );
  }

  /// Build a compact summary for an offloadable argument
  /// (e.g. write's `content`, edit's `oldString`/`newString`).
  /// Shows just the arg name, line count, and byte size — never the
  /// full content. When the value is an offload stand-in pointer
  /// (e.g. `[offloaded: 142 lines / 4.2KB; …]`), the metrics are
  /// extracted from the pointer text so the display stays clean.
  Component _buildLargeArgSummary(
    String key,
    String valueStr,
    CruxThemeData theme,
  ) {
    // Detect offload stand-in pointers and extract their metrics
    // rather than displaying the raw pointer text.
    final standIn = _parseOffloadStandIn(valueStr);
    String metricsText;
    if (standIn != null) {
      metricsText = '${standIn.lineCount} lines, ${standIn.sizeStr}'
          '${standIn.intent != null ? " (intent: '${standIn.intent}')" : ''}';
    } else if (valueStr.isEmpty) {
      metricsText = 'empty';
    } else {
      final lineCount = '\n'.allMatches(valueStr).length + 1;
      final byteSize = valueStr.length;
      final sizeStr = byteSize > 1024
          ? '${(byteSize / 1024).toStringAsFixed(1)}KB'
          : '${byteSize}B';
      metricsText = '$lineCount lines, $sizeStr';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$key ',
            style: TextStyle(
              color: theme.foreground,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              metricsText,
              style: TextStyle(color: theme.onSurfaceDim),
            ),
          ),
        ],
      ),
    );
  }

  /// Parse an offload stand-in pointer string like
  /// `[offloaded: 142 lines / 4.2KB; intent: "…"; recall via …]`
  /// and extract its metrics. Returns null if [text] is not a stand-in.
  _OffloadStandIn? _parseOffloadStandIn(String text) {
    // Stand-in format: [offloaded: N lines / SIZE; …]
    final match = RegExp(
      r'^\[offloaded:\s*(\d+)\s+lines\s*/\s*([\d.]+[KMG]?B)',
    ).firstMatch(text);
    if (match == null) return null;
    final lineCount = int.tryParse(match.group(1)!) ?? 0;
    final sizeStr = match.group(2)!;
    // Try to extract intent from the stand-in.
    final intentMatch = RegExp(r'intent:\s*"((?:[^"\\]|\\.)*)"')
        .firstMatch(text);
    final intent = intentMatch?.group(1);
    return _OffloadStandIn(
      lineCount: lineCount,
      sizeStr: sizeStr,
      intent: intent,
    );
  }

  // ─── Output tab ────────────────────────────────────────────────────

  Component _buildOutputTab(CruxThemeData theme) {
    final result = component.data.pairedResult;

    if (result == null) {
      return Center(
        child: Text(
          'No result yet (tool may still be running)',
          style: TextStyle(
            color: theme.onSurfaceDim,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    final output = result.content;
    final isGuard = output.startsWith('[GUARD]');
    final isAutoRead = output.startsWith('[AUTOREAD]');

    final children = <Component>[];

    // Status banner
    if (isGuard) {
      children.add(_banner('⚠ ${_guardReason(output)}', theme.warning, theme));
      children.add(Divider(color: theme.divider, height: 1));
    } else if (isAutoRead) {
      children.add(_banner('↻ ${_autoReadReason(output)}', theme.info, theme));
      children.add(Divider(color: theme.divider, height: 1));
    }

    // Content
    children.add(
      Expanded(
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: HighlightedMarkdownText(output),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ─── Summary tab ───────────────────────────────────────────────────

  Component _buildSummaryTab(CruxThemeData theme) {
    final tc = component.data.toolCall;
    final result = component.data.pairedResult;
    final tool = component.data.toolRegistry?.lookup(tc.name);

    final children = <Component>[];

    // Tool name
    children.add(_labelValue(
      'Tool',
      _capitalize(tc.name),
      theme,
      valueColor: theme.toolPrefix,
      valueBold: true,
    ));

    // Intent
    final intent = _intentLabel(tc, tool);
    if (intent.isNotEmpty) {
      children.add(_labelValue('Intent', intent, theme, valueItalic: true));
    }

    // Key arg
    final keyArg = _keyArg(tc);
    if (keyArg.isNotEmpty) {
      children.add(_labelValue('Target', keyArg, theme));
    }

    children.add(Divider(color: theme.dividerDim, height: 1));

    // Collapsed summary
    if (tool != null && result != null) {
      final output = result.content;
      final isGuard = output.startsWith('[GUARD]');
      final isAutoRead = output.startsWith('[AUTOREAD]');

      if (!isGuard && !isAutoRead) {
        final summary = tool.collapsedSummary(
          tc.input,
          ToolResult(title: '', output: output),
        );
        children.add(_labelValue('Summary', summary.text, theme));

        final tokenInfo = StringBuffer('~${summary.totalTokens} total');
        if (summary.argsTokens > 0 &&
            summary.argsTokens != summary.totalTokens) {
          tokenInfo.write(', args ~${summary.argsTokens}');
        }
        children.add(_labelValue(
          'Tokens',
          tokenInfo.toString(),
          theme,
          valueColor: theme.onSurfaceDim,
        ));
      } else if (isGuard) {
        children.add(_labelValue(
          'Status',
          'Guard triggered — auto read',
          theme,
          valueColor: theme.warning,
        ));
      } else if (isAutoRead) {
        children.add(_labelValue(
          'Status',
          'Auto-read — no changes',
          theme,
          valueColor: theme.info,
        ));
      }
    } else if (result != null) {
      children.add(_labelValue(
        'Result',
        _resultMetrics(result.content),
        theme,
        valueColor: theme.onSurfaceDim,
      ));
    }

    children.add(Divider(color: theme.dividerDim, height: 1));

    // Compact argument list
    children.add(_sectionHeading('Arguments', theme));

    if (tc.input.isEmpty) {
      children.add(_dimText('  (none)', theme));
    } else {
      for (final entry in tc.input.entries) {
        // For LargePayloadTool offloadable args, show a compact
        // summary instead of the value.
        final tool = component.data.toolRegistry?.lookup(tc.name);
        final isOffloadable = tool is LargePayloadTool &&
            tool.offloadableArgs.contains(entry.key);
        final valueStr = _formatValue(entry.value);
        String display;
        if (isOffloadable) {
          final standIn = _parseOffloadStandIn(valueStr);
          if (standIn != null) {
            display = '${standIn.lineCount} lines, ${standIn.sizeStr}';
          } else if (valueStr.isEmpty) {
            display = 'empty';
          } else {
            final lineCount = '\n'.allMatches(valueStr).length + 1;
            final sizeStr = valueStr.length > 1024
                ? '${(valueStr.length / 1024).toStringAsFixed(1)}KB'
                : '${valueStr.length}B';
            display = '$lineCount lines, $sizeStr';
          }
        } else {
          final lineCount = '\n'.allMatches(valueStr).length + 1;
          display = lineCount > 1
              ? '($lineCount lines)'
              : (valueStr.length > 60
                  ? '${valueStr.substring(0, 57)}...'
                  : valueStr);
        }
        children.add(
          Container(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.key}: ',
                  style: TextStyle(color: theme.onSurfaceDim),
                ),
                Expanded(
                  child: Text(
                    display,
                    style: TextStyle(color: theme.foreground),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    return ListView(children: children);
  }

  // ─── Shared helpers ────────────────────────────────────────────────

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

  Component _sectionHeading(String text, CruxThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        text,
        style: TextStyle(
          color: theme.onSurfaceDim,
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

  String _keyArg(ToolCallData tc) {
    const priorityKeys = [
      'file_path',
      'path',
      'filePath',
      'command',
      'query',
      'url',
      'directory',
    ];
    for (final key in priorityKeys) {
      if (tc.input.containsKey(key)) {
        return tc.input[key].toString();
      }
    }
    if (tc.input.isNotEmpty) {
      return tc.input.values.first.toString();
    }
    return '';
  }

  String _resultMetrics(String content) {
    final lines = '\n'.allMatches(content).length + 1;
    final size = content.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    return '$lines lines, $sizeStr';
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
    final trimmed = (period == -1 ? reason : reason.substring(0, period)).trim();
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
    final trimmed = (period == -1 ? reason : reason.substring(0, period)).trim();
    return trimmed.isEmpty ? 'Auto-read' : 'Auto-read: $trimmed';
  }
}

// Unicode-width measuring for terminal columns needs nocterm's
// internal helpers (same rationale as highlighted_markdown_text.dart).
// ignore_for_file: implementation_imports
import 'package:dart_markdown/dart_markdown.dart' as dm;
import 'package:nocterm/nocterm.dart'
    show FontStyle, FontWeight, InlineSpan, TextSpan, TextStyle;
import 'package:nocterm/src/utils/unicode_width.dart';
import 'package:source_span/source_span.dart' as src;

import '../components/ui/highlighted_markdown_text.dart';
import '../components/ui/highlight_service.dart';
import '../components/ui/markdown_isolate.dart' show MarkdownThemeFields;
import '../diagram/diagram.dart'
    show
        DiagramRenderOptions,
        DiagramRenderResult,
        isDiagramLanguage,
        renderDiagram;
import '../diagram/diagram_model.dart' show DiagramParseException;
import '../i18n/strings.dart';
import '../models/plan_selection.dart' as model;

/// Parse result for the plan pane: the rendered span tree plus the
/// [model.SourceMap] built in the same walk.
///
/// The two are atomic by construction — the visitor appends to the
/// source map every time it emits text — so they can never go stale
/// relative to each other (design doc §5 P3).
/// One markdown section heading, located in the rendered output.
///
/// Collected in the same visitor walk that builds the spans and the
/// [model.SourceMap], so [renderedRow] can never drift from the render:
/// it uses the flat-row convention shared by `viewportSourceLines` /
/// `_flatRowStarts` (the flat text split on `\n`, before terminal
/// word-wrap).
class PlanHeading {
  /// The flat rendered row the heading's text starts on (0-based).
  final int renderedRow;

  /// The heading's plain text (markers like `##` stripped).
  final String text;

  const PlanHeading({required this.renderedRow, required this.text});
}

class PlanParseResult {
  final List<InlineSpan> spans;
  final model.SourceMap sourceMap;

  /// The rendered flat text (`spans` concatenated, `\n` separators
  /// included). This is what the pane's single selectable displays and
  /// what selection offsets index into.
  final String renderedText;

  /// Section headings in source order, one per markdown heading, for
  /// the pane's scrollbar markers.
  final List<PlanHeading> headings;

  const PlanParseResult({
    required this.spans,
    required this.sourceMap,
    required this.renderedText,
    this.headings = const [],
  });

  static final empty = PlanParseResult(
    spans: const [],
    sourceMap: model.SourceMap.empty,
    renderedText: '',
  );
}

/// Parse [text] with the vendored `dart_markdown` (the ONLY parser in the
/// tree with char-perfect source positions — design doc §13) and return
/// render spans + a [model.SourceMap].
///
/// Synchronous: plan docs are user-sized (a few KB), and the parse runs
/// only on agent edits / version switches, not per frame.
PlanParseResult parsePlanDocument(
  String text,
  MarkdownThemeFields theme, {
  int? maxWidth,
  Strings strings = kEnglishStrings,
}) {
  final visitor = _PlanVisitor(theme, maxWidth: maxWidth, strings: strings);
  return visitor.parse(text);
}

/// Visitor over the vendored `dart_markdown` AST.
///
/// Mirrors the shape of `_HighlightMarkdownVisitor` (the chat renderer,
/// official `markdown` 7.3.1) but works over the `dart_markdown` AST,
/// whose nodes carry `{offset, line, column}` on every node AND on every
/// marker — the property the whole plan-mode selection design hinges on.
///
/// SourceMap conventions (load-bearing — tests depend on them):
///   - Content spans map 1:1 to their node's source range.
///   - Every markdown marker (`#`, `**`, backticks, list bullets, `>`,
///     fences, table pipes, `---`) contributes a zero-width marker span
///     parked at the rendered offset where its content would sit.
///   - Synthetic separators (block gaps, blockquote gutters, code/table
///     chrome, indentation) are marker spans whose `sourceStart ==
///     sourceEnd` — no source position claims them; they exist so
///     rendered offsets stay contiguous. A `\n`-only synthetic span's
///     rendered length equals its newline count (SourceMap relies on
///     this for row math).
///   - Block nodes split their trailing `\n\n` into a per-source-line
///     content span plus a synthetic `\n` separator, so the flash's
///     `sourceLinesToRenderedRows` attributes blank rows to the block's
///     trailing source lines instead of to nothing.
class _PlanVisitor {
  _PlanVisitor(this.theme, {this.maxWidth, this.strings = kEnglishStrings});

  final MarkdownThemeFields theme;
  final int? maxWidth;

  /// Message catalog for parser-level user-facing text (the diagram
  /// cycle warning). Defaults to English so bare construction stays
  /// valid in tests/previews; the pane-synced controller passes the
  /// real locale.
  final Strings strings;

  late final HighlightMarkdownStyleSheet styleSheet =
      HighlightMarkdownStyleSheet.fromThemeFields(theme);

  final List<InlineSpan> _spans = [];
  final List<model.SourceSpan> _mapSpans = [];
  final List<PlanHeading> _headings = [];
  final StringBuffer _flat = StringBuffer();

  int get _renderedOffset => _flat.length;

  /// The flat rendered row the next emitted character lands on. The
  /// heading walk snapshots this just before emitting the heading's
  /// content so the marker lines up with the heading's first row.
  int get _currentRow => '\n'.allMatches(_flat.toString()).length;

  PlanParseResult parse(String text) {
    final document = dm.Markdown(enableTable: true);
    final nodes = document.parse(text);
    _visitBlocks(nodes);
    final rendered = _flat.toString();
    final rowCount = rendered.isEmpty
        ? 0
        : '\n'.allMatches(rendered).length + 1;
    return PlanParseResult(
      spans: _spans,
      sourceMap: model.SourceMap(
        spans: _mapSpans,
        lineStartOffsets: _lineStartOffsets(text),
        renderedRowCount: rowCount,
      ),
      renderedText: rendered,
      headings: _headings,
    );
  }

  static List<int> _lineStartOffsets(String text) {
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }

  // ── Emission helpers ───────────────────────────────────────────────

  /// Emit rendered [text] mapped 1:1 to `[sourceStart, sourceEnd)`.
  void _emit(String text, TextStyle? style, int sourceStart, int sourceEnd) {
    if (text.isEmpty) return;
    final start = _renderedOffset;
    _spans.add(TextSpan(text: text, style: style));
    _flat.write(text);
    _mapSpans.add(
      model.SourceSpan(
        renderedStart: start,
        renderedEnd: start + text.length,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        newlines: _nl(text),
      ),
    );
  }

  /// Emit rendered [text] that corresponds to no real source range
  /// (block separators, gutters, indentation, code/table chrome).
  /// [anchor] is where boundary lookups should park (usually the node's
  /// start or end offset).
  void _emitSynthetic(String text, TextStyle? style, int anchor) {
    if (text.isEmpty) return;
    final start = _renderedOffset;
    _spans.add(TextSpan(text: text, style: style));
    _flat.write(text);
    _mapSpans.add(
      model.SourceSpan(
        renderedStart: start,
        renderedEnd: start + text.length,
        sourceStart: anchor,
        sourceEnd: anchor,
        isMarker: true,
        newlines: _nl(text),
      ),
    );
  }

  /// Emit a rendered marker (`- ` bullet, `1. ` number, `╭─` header…)
  /// whose source span is known (list bullets, fences) or unknown (pure
  /// chrome falls back to [fallbackAnchor]).
  void _emitMarkerText(
    String text,
    TextStyle? style,
    src.SourceSpan? source, {
    int fallbackAnchor = 0,
  }) {
    if (text.isEmpty) return;
    final start = _renderedOffset;
    _spans.add(TextSpan(text: text, style: style));
    _flat.write(text);
    _mapSpans.add(
      model.SourceSpan(
        renderedStart: start,
        renderedEnd: start + text.length,
        sourceStart: source?.start.offset ?? fallbackAnchor,
        sourceEnd: source?.end.offset ?? fallbackAnchor,
        isMarker: true,
        newlines: _nl(text),
      ),
    );
  }

  static int _nl(String text) => '\n'.allMatches(text).length;

  /// Emit the block's trailing separator: one source-attributed newline
  /// at the block's end position (so flash lookups of the block's
  /// trailing source line hit a rendered row), then [extra] synthetic
  /// newlines as visual spacers.
  void _emitBlockGap(dm.Node node, {int extra = 1}) {
    _emit('\n', null, node.end.offset, node.end.offset);
    for (var i = 0; i < extra; i++) {
      _emitSynthetic('\n', null, node.end.offset);
    }
  }

  /// Record a markdown marker that occupies no rendered width.
  void _recordHiddenMarker(src.SourceSpan? marker) {
    if (marker == null) return;
    _mapSpans.add(
      model.SourceSpan(
        renderedStart: _renderedOffset,
        renderedEnd: _renderedOffset,
        sourceStart: marker.start.offset,
        sourceEnd: marker.end.offset,
        isMarker: true,
      ),
    );
  }

  // ── Block-level walk ───────────────────────────────────────────────

  void _visitBlocks(List<dm.Node> nodes) {
    for (final node in nodes) {
      _visitBlock(node);
    }
  }

  void _visitBlock(dm.Node node) {
    if (node is! dm.Element) {
      // Bare text at top level (rare): emit as paragraph content.
      if (node is dm.Text) {
        _emit(
          node.textContent,
          styleSheet.paragraphStyle,
          node.start.offset,
          node.end.offset,
        );
        _emitBlockGap(node);
      }
      return;
    }
    switch (node.type) {
      case 'atxHeading':
      case 'setextHeading':
        _visitHeading(node);
      case 'paragraph':
        _visitInlines(node.children, styleSheet.paragraphStyle);
        _emitBlockGap(node);
      case 'fencedCodeBlock':
      case 'indentedCodeBlock':
        _visitCodeBlock(node);
      case 'blockquote':
      case 'fencedBlockquote':
        _visitBlockquote(node);
      case 'bulletList':
      case 'orderedList':
        _visitList(node, 0);
        _emitSynthetic('\n', null, node.end.offset);
      case 'thematicBreak':
        _visitThematicBreak(node);
      case 'table':
        _visitTable(node);
      case 'linkReferenceDefinition':
        // Reference definitions don't render in the chat renderer
        // either; skip but keep a marker so source lookups don't
        // jump across it silently.
        _mapSpans.add(
          model.SourceSpan(
            renderedStart: _renderedOffset,
            renderedEnd: _renderedOffset,
            sourceStart: node.start.offset,
            sourceEnd: node.end.offset,
            isMarker: true,
          ),
        );
      default:
        // htmlBlock, footnoteReference, etc. — render text verbatim.
        final content = node.textContent;
        if (content.isNotEmpty) {
          _emit(
            content,
            styleSheet.paragraphStyle,
            node.start.offset,
            node.end.offset,
          );
        }
        _emitBlockGap(node);
    }
  }

  void _visitHeading(dm.Element heading) {
    final level = heading.attributes['level'] ?? '1';
    final style = switch (level) {
      '1' => styleSheet.h1Style,
      '2' => styleSheet.h2Style,
      '3' => styleSheet.h3Style,
      '4' => styleSheet.h4Style,
      '5' => styleSheet.h5Style,
      _ => styleSheet.h6Style,
    };
    // Record the heading's flat row before emitting its content so the
    // pane's scrollbar marker jumps to the heading's first rendered row.
    _headings.add(
      PlanHeading(renderedRow: _currentRow, text: heading.textContent.trim()),
    );
    // Heading markers (`## `) are hidden in the rendered output but
    // recorded so a click where the marker was resolves correctly.
    _recordMarkers(heading);
    _visitInlines(heading.children, style);
    _emitBlockGap(heading);
  }

  void _visitCodeBlock(dm.Element block) {
    final language = block.attributes['language'] ?? '';
    final width = (maxWidth ?? 80).clamp(4, 1 << 20);
    final codeLineWidth = width - 4 < 0 ? 0 : width - 4;
    final headerContent = language.isNotEmpty ? ' $language ' : '';
    final headerPrefix = '╭─$headerContent';
    final headerPadding = width - headerPrefix.length - 1;
    final headerLine =
        '$headerPrefix${'─' * (headerPadding < 0 ? 0 : headerPadding)}╮';
    final footerLine = '╰${'─' * (width - 2 < 0 ? 0 : width - 2)}╯';

    final bg = styleSheet.codeBlockBackground ?? theme.codeBlockBackground;
    final gutterStyle = TextStyle(
      color: theme.codeBlockGutter,
      backgroundColor: bg,
    );
    final codeStyle =
        (styleSheet.codeBlockStyle ?? TextStyle(color: theme.mdCodeBlockText))
            .copyWith(backgroundColor: bg);

    // The opening fence is chrome; it maps to the fence marker's source
    // span (markers.first is the opening fence — see
    // fenced_code_block_syntax.dart).
    final openFence = block.markers.isNotEmpty ? block.markers.first : null;
    _emitMarkerText(
      '$headerLine\n',
      gutterStyle,
      openFence,
      fallbackAnchor: block.start.offset,
    );

    final codeText = block.children.isEmpty
        ? ''
        : block.children.map((c) => c.textContent).join();

    // Diagram languages (mermaid / d2 / stateDiagram-v2) render as
    // ASCII-art inside this same bordered box, mirroring the chat
    // renderer (`_tryRenderDiagramText`). Parse failure (streaming
    // partials!) falls through to the plain code path below.
    final diagramLines = isDiagramLanguage(language)
        ? _tryRenderDiagramLines(codeText, language, codeLineWidth)
        : null;

    if (diagramLines != null) {
      for (final line in diagramLines) {
        _emitSynthetic('│ ', gutterStyle, block.start.offset);
        _emitSynthetic(line, codeStyle, block.start.offset);
        final pad = codeLineWidth - UnicodeWidth.stringWidth(line);
        if (pad > 0) {
          _emitSynthetic(' ' * pad, codeStyle, block.start.offset);
        }
        _emitSynthetic(' │\n', gutterStyle, block.start.offset);
      }
      // Footer for the diagram body, then the shared close below.
      final closeFenceD = block.markers.length > 1
          ? block.markers.last
          : openFence;
      _emitMarkerText(
        '$footerLine\n',
        gutterStyle,
        closeFenceD,
        fallbackAnchor: block.end.offset,
      );
      _emitSynthetic('\n', null, block.end.offset);
      return;
    }

    // Code body: children are one Text node per line (with trailing
    // newline), each carrying its exact source span. Long lines soft-wrap
    // inside the box — the wrap point gets a synthetic gutter so the
    // source mapping of the *content* stays exact.
    //
    // Syntax highlighting reuses the chat renderer's machinery
    // (HighlightService + colorForScopes — theme-driven colors). The
    // tokens are applied via a per-character style lookup built from
    // the code's plain text, so the per-character `_emit` source
    // mapping is untouched: same text, same offsets, better colors.
    final charStyles = _codeCharStyles(codeText, language, codeStyle);

    var colWidth = 0;
    var lineOpen = false;

    void openLine() {
      if (lineOpen) return;
      _emitSynthetic('│ ', gutterStyle, block.start.offset);
      lineOpen = true;
      colWidth = 0;
    }

    void closeLine(int anchor) {
      openLine();
      final padding = codeLineWidth - colWidth;
      if (padding > 0) {
        _emitSynthetic(' ' * padding, codeStyle, anchor);
      }
      _emitSynthetic(' │\n', gutterStyle, anchor);
      lineOpen = false;
      colWidth = 0;
    }

    if (block.children.isEmpty) {
      closeLine(block.start.offset);
    } else {
      var lastAnchor = block.start.offset;
      for (final child in block.children) {
        final text = child.textContent;
        var segStart = child.start.offset;
        for (var i = 0; i < text.length; i++) {
          final ch = text[i];
          if (ch == '\n') {
            closeLine(child.start.offset + i);
            lastAnchor = child.start.offset + i + 1;
            continue;
          }
          openLine();
          final w = UnicodeWidth.stringWidth(ch);
          if (codeLineWidth > 0 &&
              colWidth > 0 &&
              colWidth + w > codeLineWidth) {
            closeLine(child.start.offset + i);
            openLine();
          }
          final charStyle = charStyles.isEmpty
              ? codeStyle
              : (charStyles[child.start.offset + i] ?? codeStyle);
          _emit(ch, charStyle, segStart, child.start.offset + i + 1);
          segStart = child.start.offset + i + 1;
          lastAnchor = segStart;
          colWidth += w;
        }
      }
      if (lineOpen) closeLine(lastAnchor);
    }

    // The closing fence (if any) maps to the footer chrome.
    final closeFence = block.markers.length > 1 ? block.markers.last : null;
    _emitMarkerText(
      '$footerLine\n',
      gutterStyle,
      closeFence ?? openFence,
      fallbackAnchor: block.end.offset,
    );
    _emitSynthetic('\n', null, block.end.offset);
  }

  /// Try to render [code] as a mermaid/d2/stateDiagram graph and return
  /// its ASCII-art lines (warnings included), or null when the source
  /// cannot (yet) be parsed — streaming partials then fall back to the
  /// raw-source path in [_visitCodeBlock], matching the chat renderer's
  /// `_tryRenderDiagramText`.
  List<String>? _tryRenderDiagramLines(
    String code,
    String language,
    int codeLineWidth,
  ) {
    final DiagramRenderResult result;
    try {
      result = renderDiagram(
        code,
        DiagramRenderOptions(maxWidth: codeLineWidth),
        language: language,
      );
    } on DiagramParseException {
      return null;
    }
    return [
      ...result.text.split('\n'),
      for (final warning in result.warnings)
        '⚠ ${warning.message(cycleDetected: (nodes) => strings.t('diagram.cycleWarning', {'nodes': nodes}))}',
    ];
  }

  /// Per-character styles for a code block's [code] plain text:
  /// `sourceOffset → highlighted TextStyle`. Empty when no highlighter
  /// is available (service not initialized / unknown language) — the
  /// caller then falls back to the uniform code style.
  ///
  /// Built from the chat renderer's same machinery: `HighlightService`
  /// tokenizes the whole block as one string (multi-line tokens like
  /// `///` doc comments need the full context), `colorForScopes` maps
  /// scopes to the *theme* colors, and tm styles contribute bold/italic.
  Map<int, TextStyle> _codeCharStyles(
    String code,
    String language,
    TextStyle fallback,
  ) {
    final service = HighlightService.instance;
    if (service == null || language.isEmpty || code.isEmpty) return const {};
    final highlighter = service.highlighterFor(language);
    if (highlighter == null) return const {};
    try {
      final tokens = highlighter.highlight(code);
      if (tokens.isEmpty) return const {};
      final styles = <int, TextStyle>{};
      var lastEnd = 0;
      for (final token in tokens) {
        if (token.start > lastEnd) {
          // Gap before the token: keep the fallback style — no entry.
        }
        final tmStyle = service.styleForScopes(token.scopes);
        final style = TextStyle(
          color: colorForScopes(token.scopes, theme),
          fontWeight: tmStyle?.bold == true
              ? FontWeight.bold
              : FontWeight.normal,
          fontStyle: tmStyle?.italic == true
              ? FontStyle.italic
              : FontStyle.normal,
        );
        for (var i = token.start; i < token.end && i < code.length; i++) {
          styles[i] = style;
        }
        lastEnd = token.end;
      }
      return styles;
    } catch (_) {
      // Highlighting is best-effort decoration; never let it break the
      // render (or the source map) — fall back to the plain style.
      return const {};
    }
  }

  void _visitBlockquote(dm.Element quote) {
    final style = styleSheet.blockquoteStyle;
    // Mirror the chat renderer's `│ ` gutter, one per rendered row of
    // the quote's content. We render the quote's children into a
    // temporary sub-visitor, then replay its spans row by row, prefixing
    // each row with a gutter. Source ranges are shifted proportionally
    // for clipped content spans; markers keep their anchors.
    final sub = _PlanVisitor(theme, maxWidth: maxWidth, strings: strings);
    sub._visitBlocks(quote.children);
    final subFlat = sub._flat.toString();
    final subLines = subFlat.split('\n');
    final quoteAnchor = quote.markers.isNotEmpty
        ? quote.markers.first.start.offset
        : quote.start.offset;

    var wroteRow = false;
    var rowStart = 0;
    for (var i = 0; i < subLines.length; i++) {
      final line = subLines[i];
      final isLast = i == subLines.length - 1;
      if (isLast && line.isEmpty) break; // trailing newline artifact
      final rowEnd = rowStart + line.length;

      // The gutter is synthetic, anchored at the quote's opening marker.
      _emitSynthetic('│ ', style, quoteAnchor);

      for (final m in sub._mapSpans) {
        if (m.renderedStart >= rowEnd || m.renderedEnd <= rowStart) {
          continue;
        }
        // Clip the sub-span to this row.
        final s = m.renderedStart < rowStart ? rowStart : m.renderedStart;
        final e = m.renderedEnd > rowEnd ? rowEnd : m.renderedEnd;
        if (e <= s) continue;
        final text = subFlat.substring(s, e);
        final styleFor = _styleAt(sub._spans, s);
        final start = _renderedOffset;
        _spans.add(TextSpan(text: text, style: styleFor));
        _flat.write(text);
        // Shift the source range proportionally for clipped content
        // spans; markers and synthetics keep their anchor.
        var srcStart = m.sourceStart;
        var srcEnd = m.sourceEnd;
        if (!m.isMarker && m.renderedLength > 0) {
          final rel = s - m.renderedStart;
          final len = e - s;
          srcStart = m.sourceStart + rel;
          srcEnd = srcStart + len.clamp(0, m.sourceEnd - srcStart);
        }
        _mapSpans.add(
          model.SourceSpan(
            renderedStart: start,
            renderedEnd: start + text.length,
            sourceStart: srcStart,
            sourceEnd: srcEnd,
            isMarker: m.isMarker,
            newlines: _nl(text),
          ),
        );
      }
      _emitSynthetic('\n', null, quote.end.offset);
      wroteRow = true;
      rowStart = rowEnd + 1; // skip the '\n' itself
    }
    if (!wroteRow) {
      _emitSynthetic('\n', null, quote.end.offset);
    }
    _emitSynthetic('\n', null, quote.end.offset);
  }

  /// Best-effort style recovery for a sub-span text slice: find the flat
  /// TextSpan containing [offset] in the sub-visitor's output.
  static TextStyle? _styleAt(List<InlineSpan> spans, int offset) {
    var pos = 0;
    for (final span in spans) {
      if (span is TextSpan && span.text != null) {
        final len = span.text!.length;
        if (offset >= pos && offset < pos + len) return span.style;
        pos += len;
      }
    }
    return null;
  }

  void _visitList(dm.Element list, int depth) {
    final ordered = list.type == 'orderedList';
    var index = 0;
    for (final item in list.children) {
      index++;
      if (item is! dm.Element) continue;
      final indent = '  ' * depth;
      final bulletText = ordered ? '$index. ' : styleSheet.listBullet;
      // List markers carry real source spans (the `-` / `1.` token).
      // We render the bullet + indentation as a marker span mapped to
      // that token.
      _emitMarkerText(
        '$indent$bulletText',
        null,
        item.markers.isNotEmpty ? item.markers.first : null,
        fallbackAnchor: item.start.offset,
      );
      _visitListItemChildren(item, depth);
    }
  }

  /// dart_markdown block element types (from the `_visitBlock` switch)
  /// that mean "block-level content inside a list item".
  static bool _isBlockLevelChild(dm.Element e) {
    switch (e.type) {
      case 'atxHeading':
      case 'setextHeading':
      case 'paragraph':
      case 'fencedCodeBlock':
      case 'indentedCodeBlock':
      case 'blockquote':
      case 'fencedBlockquote':
      case 'bulletList':
      case 'orderedList':
      case 'thematicBreak':
      case 'table':
        return true;
      default:
        return false;
    }
  }

  void _visitListItemChildren(dm.Element item, int depth) {
    // Tight lists have bare inline children; loose lists wrap them in
    // `paragraph` blocks (dart_markdown strips the paragraph wrapper for
    // tight lists — see list_syntax.dart). Nested lists recurse.
    //
    // Tight-list items expose their emphasis/code/link nodes as DIRECT
    // children of the list item (no paragraph wrapper). Those are inline
    // nodes: routing them through `_visitBlock`'s default case would emit
    // their text and then a paragraph gap (`\n\n`), shredding the item
    // into one visual paragraph per inline node. So: paragraph-wrapped
    // children use the paragraph branch, block children (code, blockquote,
    // nested lists…) go through `_visitBlock`, and everything else is an
    // inline node visited with the inline walker.
    var first = true;
    for (final child in item.children) {
      if (child is dm.Element &&
          (child.type == 'bulletList' || child.type == 'orderedList')) {
        _emitSynthetic('\n', null, child.start.offset);
        _visitList(child, depth + 1);
        continue;
      }
      if (child is dm.Element && !_isBlockLevelChild(child)) {
        _visitInline(child, styleSheet.paragraphStyle);
        first = false;
        continue;
      }
      if (child is dm.Element && child.type == 'paragraph') {
        if (!first) {
          _emitSynthetic('\n${'  ' * (depth + 1)}', null, child.start.offset);
        }
        _visitInlines(child.children, styleSheet.paragraphStyle);
      } else if (child is dm.Text) {
        _emit(child.textContent, null, child.start.offset, child.end.offset);
      } else if (child is dm.Element) {
        // Fenced code / blockquote / other blocks inside an item.
        _visitBlock(child);
      }
      first = false;
    }
    _emit('\n', null, item.end.offset, item.end.offset);
  }

  void _visitThematicBreak(dm.Element node) {
    final width = maxWidth ?? 40;
    _emitMarkerText(
      '${styleSheet.horizontalRule * width}\n',
      TextStyle(color: theme.outline),
      node.markers.isNotEmpty ? node.markers.first : null,
      fallbackAnchor: node.start.offset,
    );
    _emitSynthetic('\n', null, node.end.offset);
  }

  void _visitTable(dm.Element table) {
    // Mapping (design doc §9.5): each rendered cell maps to the table
    // ROW's source line at row granularity; wrapped cell lines map to
    // their slice of the cell's source range; the grid chrome is
    // synthetic. Visual treatment mirrors the chat renderer (zebra row
    // backgrounds, per-cell word wrap, `├─┼─┤` header separator).
    final rows = <List<dm.Element?>>[];
    for (final section in table.children) {
      if (section is! dm.Element) continue;
      if (section.type != 'tableHead' && section.type != 'tableBody') {
        continue;
      }
      for (final row in section.children) {
        if (row is! dm.Element || row.type != 'tableRow') continue;
        final cells = <dm.Element?>[];
        for (final c in row.children) {
          if (c is dm.Element &&
              (c.type == 'tableHeadCell' || c.type == 'tableBodyCell')) {
            cells.add(c);
          }
        }
        rows.add(cells);
      }
    }
    if (rows.isEmpty) {
      _emitBlockGap(table);
      return;
    }

    final colCount = rows.fold<int>(
      0,
      (max, r) => r.length > max ? r.length : max,
    );
    final natural = List<int>.filled(colCount, 0);
    for (final cells in rows) {
      for (var c = 0; c < cells.length; c++) {
        final w = UnicodeWidth.stringWidth(cells[c]!.textContent);
        if (w > natural[c]) natural[c] = w;
      }
    }
    final widths = _distributeColumnWidths(natural, maxWidth);

    final borderStyle = TextStyle(color: theme.outline);
    final textStyle =
        styleSheet.paragraphStyle ?? TextStyle(color: theme.markdownText);
    final headerStyle = textStyle.copyWith(
      fontWeight: FontWeight.bold,
      backgroundColor: theme.surfaceVariant.withOpacity(0.5),
    );

    void border(String left, String fill, String middle, String right) {
      final buf = StringBuffer(left);
      for (var i = 0; i < widths.length; i++) {
        buf.write(fill * (widths[i] + 2));
        if (i < widths.length - 1) buf.write(middle);
      }
      buf.write('$right\n');
      _emitSynthetic(buf.toString(), borderStyle, table.start.offset);
    }

    border('┌', '─', '┬', '┐');
    for (var r = 0; r < rows.length; r++) {
      final cells = rows[r];
      final isHeader = r == 0;
      // Zebra: header uses surfaceVariant; body rows alternate
      // surface / surfaceVariant (chat renderer's exact recipe).
      final rowBg = isHeader
          ? theme.surfaceVariant.withOpacity(0.5)
          : ((r - 1).isEven ? theme.surface : theme.surfaceVariant).withOpacity(
              0.5,
            );
      final rowStyle = (isHeader ? headerStyle : textStyle).copyWith(
        backgroundColor: rowBg,
      );

      // Wrap each cell into lines of at most `widths[c]` columns.
      final wrapped = <List<(String, int, int)>>[]; // (text, srcStart, srcEnd)
      var rowHeight = 1;
      for (var c = 0; c < widths.length; c++) {
        final cell = c < cells.length ? cells[c] : null;
        final lines = cell == null
            ? <(String, int, int)>[('', 0, 0)]
            : _wrapCell(cell.textContent, widths[c], cell.start.offset);
        wrapped.add(lines);
        if (lines.length > rowHeight) rowHeight = lines.length;
      }

      for (var l = 0; l < rowHeight; l++) {
        _emitSynthetic(
          '│',
          borderStyle,
          cells.first?.start.offset ?? table.start.offset,
        );
        for (var c = 0; c < widths.length; c++) {
          final (text, s, e) = l < wrapped[c].length
              ? wrapped[c][l]
              : ('', 0, 0);
          _emitSynthetic(' ', rowStyle, table.start.offset);
          if (text.isNotEmpty) {
            if (s < e) {
              _emit(text, rowStyle, s, e);
            } else {
              _emitSynthetic(text, rowStyle, table.start.offset);
            }
          }
          final pad = widths[c] - UnicodeWidth.stringWidth(text);
          if (pad > 0) _emitSynthetic(' ' * pad, rowStyle, table.start.offset);
          _emitSynthetic(' ', rowStyle, table.start.offset);
          _emitSynthetic('│', borderStyle, table.start.offset);
        }
        // One newline PER display line — wrapped cells must break
        // between their lines, not only after the row's last one.
        _emitSynthetic('\n', null, table.end.offset);
      }
      if (r == 0 && rows.length > 1) border('├', '─', '┼', '┤');
    }
    border('└', '─', '┴', '┘');
    _emitSynthetic('\n', null, table.end.offset);
  }

  /// Wrap [content] into lines of at most [cellWidth] display columns,
  /// each carrying its `(sourceStart, sourceEnd)` slice — a wrapped
  /// continuation line maps to the exact source sub-range it renders,
  /// keeping the char-granular mapping intact (better than the old
  /// whole-cell mapping when cells wrap).
  ///
  /// Word-greedy wrap (chat renderer's algorithm); words wider than the
  /// cell break at character boundaries. Offsets are tracked per word,
  /// so a line's source range covers exactly the words it contains.
  List<(String, int, int)> _wrapCell(
    String content,
    int cellWidth,
    int sourceStart,
  ) {
    if (cellWidth <= 0) {
      return [(content, sourceStart, sourceStart + content.length)];
    }
    if (UnicodeWidth.stringWidth(content) <= cellWidth) {
      return [(content, sourceStart, sourceStart + content.length)];
    }

    // Tokenize into (word, startOffset, endOffset) — offsets index
    // into [content]; the caller shifts them by [sourceStart].
    final words = <(String, int, int)>[];
    var i = 0;
    while (i < content.length) {
      if (content[i] == ' ') {
        i++;
        continue;
      }
      final start = i;
      while (i < content.length && content[i] != ' ') {
        i++;
      }
      words.add((content.substring(start, i), start, i));
    }

    final lines = <(String, int, int)>[];
    var lineText = '';
    var lineStart = -1; // content offset of the line's first word
    var lineEnd = 0; // content offset after the line's last word
    var lineWidth = 0;

    void flush() {
      if (lineText.isEmpty) return;
      lines.add((lineText, sourceStart + lineStart, sourceStart + lineEnd));
      lineText = '';
      lineStart = -1;
      lineWidth = 0;
    }

    for (final (word, wStart, wEnd) in words) {
      final wordWidth = UnicodeWidth.stringWidth(word);
      if (wordWidth > cellWidth) {
        // Overlong word: flush what we have, then hard-break the word
        // at character boundaries recording each chunk's range.
        flush();
        var off = wStart;
        while (off < wEnd) {
          var chunk = '';
          var chunkW = 0;
          final chunkStart = off;
          while (off < wEnd) {
            final w = UnicodeWidth.stringWidth(content[off]);
            if (chunkW > 0 && chunkW + w > cellWidth) break;
            chunk += content[off];
            chunkW += w;
            off++;
          }
          lines.add((chunk, sourceStart + chunkStart, sourceStart + off));
        }
        lineEnd = wEnd;
        continue;
      }
      final sepWidth = lineText.isEmpty ? 0 : 1;
      if (lineWidth > 0 && lineWidth + sepWidth + wordWidth > cellWidth) {
        flush();
      }
      lineText = lineText.isEmpty ? word : '$lineText $word';
      if (lineStart < 0) lineStart = wStart;
      lineEnd = wEnd;
      lineWidth = UnicodeWidth.stringWidth(lineText);
    }
    flush();
    if (lines.isEmpty) {
      lines.add(('', sourceStart, sourceStart));
    }
    return lines;
  }

  List<int> _distributeColumnWidths(List<int> naturalWidths, int? maxWidth) {
    final numCols = naturalWidths.length;
    final overhead = 3 * numCols + 1;
    final naturalTotal = naturalWidths.fold(0, (sum, w) => sum + w) + overhead;
    if (maxWidth == null || naturalTotal <= maxWidth) {
      return List.of(naturalWidths);
    }
    const minColWidth = 3;
    final available = maxWidth - overhead;
    if (available < numCols * minColWidth) {
      return List.filled(numCols, minColWidth);
    }
    final result = List<int>.filled(numCols, 0);
    final totalNatural = naturalWidths.fold(0, (sum, w) => sum + w);
    for (var i = 0; i < numCols; i++) {
      result[i] = naturalWidths[i] * available ~/ totalNatural;
      if (result[i] < minColWidth) result[i] = minColWidth;
    }
    var remaining = available - result.fold(0, (sum, w) => sum + w);
    while (remaining > 0) {
      var bestIdx = 0;
      var bestDeficit = 0;
      for (var i = 0; i < numCols; i++) {
        final deficit = naturalWidths[i] - result[i];
        if (deficit > bestDeficit) {
          bestDeficit = deficit;
          bestIdx = i;
        }
      }
      if (bestDeficit == 0) break;
      result[bestIdx]++;
      remaining--;
    }
    return result;
  }

  // ── Inline-level walk ──────────────────────────────────────────────

  void _visitInlines(List<dm.Node> nodes, TextStyle? baseStyle) {
    for (final node in nodes) {
      if (node is dm.Text) {
        _emit(node.textContent, baseStyle, node.start.offset, node.end.offset);
      } else if (node is dm.Element) {
        _visitInline(node, baseStyle);
      }
    }
  }

  void _visitInline(dm.Element element, TextStyle? baseStyle) {
    switch (element.type) {
      case 'strongEmphasis':
        _recordMarkers(element);
        _visitInlines(element.children, styleSheet.boldStyle);
      case 'emphasis':
        _recordMarkers(element);
        _visitInlines(element.children, styleSheet.italicStyle);
      case 'strikethrough':
        _recordMarkers(element);
        _visitInlines(element.children, styleSheet.strikethroughStyle);
      case 'codeSpan':
        // The backtick markers are hidden; the code content renders in
        // the inline-code style mapped to its exact source range. Use
        // the first child's range when available (element.start includes
        // the opening backtick).
        _recordMarkers(element);
        final contentStart = element.children.isNotEmpty
            ? element.children.first.start.offset
            : element.start.offset;
        final contentEnd = element.children.isNotEmpty
            ? element.children.last.end.offset
            : element.end.offset;
        _emit(
          element.textContent,
          styleSheet.codeStyle,
          contentStart,
          contentEnd,
        );
      case 'link':
      case 'autolink':
      case 'autolinkExtension':
        _recordMarkers(element);
        final href = element.attributes['href'] ?? '';
        final label = element.textContent;
        final display = label.isNotEmpty ? label : href;
        _emit(
          display,
          styleSheet.linkStyle,
          element.start.offset,
          element.end.offset,
        );
      case 'image':
        _recordMarkers(element);
        final alt = element.attributes['alt'] ?? 'image';
        _emit(
          '[Image: $alt]',
          const TextStyle(fontStyle: FontStyle.italic),
          element.start.offset,
          element.end.offset,
        );
      case 'hardLineBreak':
        _emit('\n', baseStyle, element.start.offset, element.end.offset);
      case 'emoji':
        _emit(
          element.textContent,
          baseStyle,
          element.start.offset,
          element.end.offset,
        );
      default:
        _recordMarkers(element);
        _visitInlines(element.children, baseStyle);
    }
  }

  void _recordMarkers(dm.Element element) {
    for (final marker in element.markers) {
      _recordHiddenMarker(marker);
    }
  }
}

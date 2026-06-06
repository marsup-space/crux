import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/markdown_headings.dart';

/// Converts TLDR [Heading] references to markdown **bold** so they render
/// in the configured `tldrLink` color via [MarkdownStyleSheet.boldStyle].
/// The headings parameter is accepted for backwards compatibility (the
/// caller still extracts them) but is no longer used to gate styling —
/// markdown handles all rendering now.
String _renderTldrAsMarkdown(String tldrText) {
  // Match bracketed, non-empty, non-whitespace-only segments.
  final bracketRegex = RegExp(r'\[([^\]\n]+)\]');
  return tldrText.replaceAllMapped(bracketRegex, (m) {
    final inner = m.group(1)!.trim();
    if (inner.isEmpty) return m.group(0)!;
    return '**$inner**';
  });
}

final MarkdownStyleSheet _tldrStyleSheet = MarkdownStyleSheet(
  paragraphStyle: TextStyle(color: CruxTheme.tldrBody),
  listBullet: '• ',
  // The AI is required to wrap heading references in **...** so this
  // style paints the reference in tldrLink with an underline — keeping
  // the old "clickable heading" affordance visually intact.
  boldStyle: TextStyle(
    color: CruxTheme.tldrLink,
    fontWeight: FontWeight.bold,
    decoration: TextDecoration.underline,
  ),
  italicStyle: TextStyle(
    color: CruxTheme.tldrBody,
    fontStyle: FontStyle.italic,
  ),
  codeStyle: TextStyle(color: CruxTheme.tldrLink),
);

class TldrBubble extends StatelessComponent {
  final String tldrText;
  final List<MarkdownHeading> headings;
  final bool isGenerating;
  final bool hasAuxiliaryModel;

  const TldrBubble({
    required this.tldrText,
    required this.headings,
    required this.isGenerating,
    required this.hasAuxiliaryModel,
  });

  @override
  Component build(BuildContext context) {
    final children = <Component>[];

    if (isGenerating) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ' TLDR: ',
                style: TextStyle(
                  color: CruxTheme.tldrPrefix,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'generating...',
                style: TextStyle(color: CruxTheme.tldrHint),
              ),
            ],
          ),
        ),
      );
    } else if (tldrText.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ' TLDR: ',
                style: TextStyle(
                  color: CruxTheme.tldrPrefix,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(child: _buildTldrBody(tldrText)),
            ],
          ),
        ),
      );
    } else {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ' TLDR: ',
                style: TextStyle(
                  color: CruxTheme.tldrPrefix,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(child: _buildHeadingsFallback()),
            ],
          ),
        ),
      );
    }

    children.add(Divider(color: CruxTheme.divider, height: 1));

    return Column(children: children);
  }

  Component _buildTldrBody(String tldrText) {
    // Normalize: strip leading "- " / "• " from each line so the markdown
    // engine doesn't see a bullet that's already a list marker. Then
    // route the whole text through MarkdownText so bullets, bold (used
    // for [Heading] refs), italic, and inline code all render through
    // nocterm's soft-wrapping paragraph renderer — fixing the original
    // Row-of-Text overflow bug in the process.
    final normalized = tldrText
        .split('\n')
        .map((l) {
          final t = l.trimRight();
          if (t.startsWith('- ')) return t.substring(2);
          if (t.startsWith('• ')) return t.substring(2);
          if (t.startsWith('* ')) return t.substring(2);
          return t;
        })
        .where((l) => l.trim().isNotEmpty)
        .map((l) => '- $l')
        .join('\n');

    final markdown = _renderTldrAsMarkdown(normalized);

    return MarkdownText(
      markdown,
      softWrap: true,
      styleSheet: _tldrStyleSheet,
    );
  }

  Component _buildHeadingsFallback() {
    if (headings.isEmpty) {
      final hint = hasAuxiliaryModel
          ? 'no sections'
          : 'no sections (set /auxiliary for summaries)';
      return Column(
        children: [Text(hint, style: TextStyle(color: CruxTheme.tldrHint))],
      );
    }

    final rows = <Component>[];
    for (final h in headings) {
      final indent = '  ' * (h.level - 1);
      rows.add(
        Row(
          children: [
            Text('$indent• ', style: TextStyle(color: CruxTheme.tldrBody)),
            Text(h.text, style: TextStyle(color: CruxTheme.tldrBody)),
          ],
        ),
      );
    }

    if (!hasAuxiliaryModel) {
      rows.add(
        Text(
          '  (set /auxiliary for summaries)',
          style: TextStyle(color: CruxTheme.tldrHint),
        ),
      );
    }

    return Column(children: rows);
  }
}

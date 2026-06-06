import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/markdown_headings.dart';
import 'ui/response_link_text.dart';

typedef TldrHeadingTapCallback = void Function(String heading, String? url);

class TldrBubble extends StatelessComponent {
  final String tldrText;
  final List<MarkdownHeading> headings;
  final bool isGenerating;
  final bool hasAuxiliaryModel;
  final TldrHeadingTapCallback? onHeadingTap;

  const TldrBubble({
    super.key,
    required this.tldrText,
    required this.headings,
    required this.isGenerating,
    required this.hasAuxiliaryModel,
    this.onHeadingTap,
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
              Expanded(
                child: ResponseLinkText(
                  markdownText: tldrText,
                  onLinkTap: onHeadingTap != null
                      ? (link) => onHeadingTap!(
                            link.anchor ?? link.text,
                            link.url,
                          )
                      : null,
                ),
              ),
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

    return Column(children: children);
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
            Expanded(child: Text(h.text, style: TextStyle(color: CruxTheme.tldrBody))),
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

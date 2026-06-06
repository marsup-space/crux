import 'package:markdown/markdown.dart' as md;

class MarkdownHeading {
  final int level;
  final String text;

  const MarkdownHeading({required this.level, required this.text});
}

List<MarkdownHeading> extractHeadings(String markdown) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubWeb,
    encodeHtml: false,
  );
  final nodes = document.parse(markdown);
  final headings = <MarkdownHeading>[];
  _collectHeadings(nodes, headings);
  return headings;
}

void _collectHeadings(List<md.Node> nodes, List<MarkdownHeading> headings) {
  for (final node in nodes) {
    if (node is md.Element) {
      final tag = node.tag;
      if (tag.startsWith('h') && tag.length == 2) {
        final level = int.tryParse(tag[1]);
        if (level != null) {
          headings.add(
            MarkdownHeading(level: level, text: node.textContent.trim()),
          );
        }
      }
      if (node.children != null) {
        _collectHeadings(node.children!, headings);
      }
    }
  }
}

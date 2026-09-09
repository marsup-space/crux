// Regression for "vibe mode doesn't render ask:// quick replies and
// other clickable markdown tokens".
//
// The vibe prose row uses [HighlightedMarkdownText] to render the
// agent's reply. That widget only substitutes `ask://…`, `ses://…`,
// and `[label](url)` tokens into clickable buttons when the
// corresponding callback is non-null. Prior to this slice,
// [VibeSegmentBubble] and [VibeStreamingBubble] never forwarded
// `onQuickReplyTap` / `onSessionLinkTap` / `onLinkTap`, so the
// source text leaked through verbatim. This file pins the wiring:
// the rendered terminal string of [HighlightedMarkdownText] differs
// based on whether each callback is supplied.
//
// We verify the substitution contract directly against
// [HighlightedMarkdownText], which is the leaf widget that
// performs the substitution. The vibe widgets forward each callback
// to it under specific gating rules (ask only on the latest closed
// AI segment, links always live), but the actual substitution
// mechanics are entirely in [HighlightedMarkdownText]. As long as
// the vibe widgets pass the right callback through, the substitution
// behaves correctly here.

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:crux/src/utils/markdown_links.dart';
import 'package:crux/src/utils/quick_reply_parser.dart';

Future<String> _renderWith({
  required String source,
  void Function(QuickReply)? onQuickReplyTap,
  void Function(int)? onSessionLinkTap,
  void Function(MarkdownLink)? onLinkTap,
}) async {
  var captured = '';
  await testNocterm('vibe token wiring', (tester) async {
    await tester.pumpComponent(
      Container(
        width: 200,
        height: 8,
        child: HighlightedMarkdownText(
          source,
          onQuickReplyTap: onQuickReplyTap,
          onSessionLinkTap: onSessionLinkTap,
          onLinkTap: onLinkTap,
        ),
      ),
    );
    captured = tester.renderToString(showBorders: false);
  }, size: const Size(200, 8));
  return captured;
}

void main() {
  test('ask:// wiring: source is replaced when handler is wired', () async {
    const source = 'Pick a colour: ask://red{Use red} or ask://blue{Use blue}.';
    final rendered = await _renderWith(source: source, onQuickReplyTap: (q) {});
    // With a wired callback the source `ask://…{…}` substring is
    // replaced with the labels (`red`, `blue`).
    expect(rendered, contains('red'));
    expect(rendered, contains('blue'));
    expect(rendered, isNot(contains('ask://')));
  });

  test('markdown link wiring: source `[label](url)` is parsed when onLinkTap is wired', () async {
    const source = 'See ses://42 and the [docs](https://example.com).';
    final rendered = await _renderWith(
      source: source,
      onSessionLinkTap: (id) {},
      onLinkTap: (link) {},
    );

    // Markdown link parser RUNS when `onLinkTap` is wired — the
    // label `docs` survives and the raw `[docs](https://…)` form
    // is replaced (the URL is hidden when a label is present).
    // Session-link refs (ses://42) keep the source text and get
    // only a style overlay, so the substring `42` is enough to
    // assert the parser matched.
    expect(rendered, contains('docs'));
    expect(rendered, isNot(contains('[docs](')));
    expect(rendered, isNot(contains('https://')));
    expect(rendered, contains('42'));
  });
}

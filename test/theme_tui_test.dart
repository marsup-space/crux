import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/ui/button.dart';
import 'package:crux/src/components/ui/highlight_service.dart';
import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/theme/theme_loader.dart';

class _ThemeProbe extends StatelessComponent {
  const _ThemeProbe();

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Container(
      width: 60,
      height: 12,
      color: theme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('body', style: TextStyle(color: theme.text)),
          Button(label: 'button'),
          Container(
            color: theme.toastBgError,
            child: Text('error', style: TextStyle(color: theme.toastTextError)),
          ),
          Container(
            color: theme.queueBackground,
            child: Text('queue', style: TextStyle(color: theme.queuePrefix)),
          ),
          HighlightedMarkdownText(
            '# Heading\n`inline`\n```dart\nfinal value = 1;\n```',
          ),
        ],
      ),
    );
  }
}

void main() {
  Future<CruxThemeData> loadTheme(String id) {
    return ThemeLoader.loadFile(
      File(p.join(Directory.current.path, 'themes', '$id.toml')),
      id: id,
    );
  }

  for (final id in const ['dracula', 'github']) {
    test('renders representative $id colors into terminal cells', () async {
      final theme = await loadTheme(id);
      await HighlightService.initialize();
      await testNocterm('$id theme cells', (tester) async {
        await tester.pumpComponent(
          TuiTheme(
            data: theme.toTuiThemeData(),
            child: CruxTheme(data: theme, child: const _ThemeProbe()),
          ),
        );

        final body = tester.terminalState.findText('body').single;
        final bodyCell = tester.terminalState.getCellAt(body.x, body.y)!;
        expect(bodyCell.style.color, theme.text);
        expect(bodyCell.style.backgroundColor, theme.background);

        final button = tester.terminalState.findText('button').single;
        final buttonCell = tester.terminalState.getCellAt(button.x, button.y)!;
        expect(buttonCell.style.color, theme.buttonTextDisabled);
        expect(buttonCell.style.backgroundColor, theme.buttonBackground);

        final error = tester.terminalState.findText('error').single;
        final errorCell = tester.terminalState.getCellAt(error.x, error.y)!;
        expect(errorCell.style.color, theme.toastTextError);
        expect(errorCell.style.backgroundColor, theme.toastBgError);

        final queue = tester.terminalState.findText('queue').single;
        final queueCell = tester.terminalState.getCellAt(queue.x, queue.y)!;
        expect(queueCell.style.color, theme.queuePrefix);
        expect(queueCell.style.backgroundColor, theme.queueBackground);

        final heading = tester.terminalState.findText('Heading').single;
        expect(
          tester.terminalState.getCellAt(heading.x, heading.y)!.style.color,
          theme.markdownHeading,
        );

        final inline = tester.terminalState.findText('inline').single;
        final inlineCell = tester.terminalState.getCellAt(inline.x, inline.y)!;
        expect(inlineCell.style.color, theme.markdownCode);
        expect(inlineCell.style.backgroundColor, theme.surfaceVariant);

        final keyword = tester.terminalState.findText('final').single;
        final keywordCell = tester.terminalState.getCellAt(
          keyword.x,
          keyword.y,
        )!;
        expect(keywordCell.style.color, theme.syntaxKeyword);
        expect(keywordCell.style.backgroundColor, theme.codeBlockBackground);
      }, size: const Size(60, 12));
    });
  }

  test('highlight foreground is selected by background luminance', () async {
    final dark = await loadTheme('dracula');
    final light = await loadTheme('github');
    expect(dark.onColor(const Color(0xFFFFFF)), const Color(0x111111));
    expect(light.onColor(const Color(0x111111)), const Color(0xFFFFFF));
  });
}

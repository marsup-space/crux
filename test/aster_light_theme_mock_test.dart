import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/theme/theme_loader.dart';

HomeContext _context() => HomeContext.minimal(close: () {});

void main() {
  for (final themeId in const [
    'flexoki',
    'rosepine',
    'electric-orchid',
    'cobalt-bloom',
    'ember-clay',
  ]) {
    test(
      '$themeId renders the home dashboard with readable hierarchy',
      () async {
        final theme = await ThemeLoader.loadFile(
          File(p.join(Directory.current.path, 'themes', '$themeId.toml')),
          id: themeId,
        );

        await testNocterm('$themeId home mock', (tester) async {
          await tester.pumpComponent(
            NoctermApp(
              theme: theme.toTuiThemeData(),
              child: CruxTheme(
                data: theme,
                child: Container(
                  width: 120,
                  height: 30,
                  child: HomeScreen(
                    onExit: () {},
                    context_: _context(),
                    widgets: [
                      StubHomeWidget('Workspace', supportedSpans: const {1, 2}),
                      StubHomeWidget('Recent sessions'),
                      StubHomeWidget('Quick actions'),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          for (final label in [
            'Workspace',
            'Recent sessions',
            'Quick actions',
          ]) {
            // Stub content repeats its title; the first occurrence is the
            // dashboard box heading that carries the UI hierarchy styling.
            final position = tester.terminalState.findText(label).first;
            final cell = tester.terminalState.getCellAt(
              position.x,
              position.y,
            )!;
            expect(
              cell.style.color,
              isNot(theme.background),
              reason: '$label title',
            );
          }

          // Focus feedback must remain visible on the muted light surfaces.
          final border = tester.terminalState.findText('Workspace').first;
          final borderCell = tester.terminalState.getCellAt(
            border.x - 2,
            border.y,
          )!;
          expect(borderCell.style.color, theme.borderActive);
          final workspaceTitle = tester.terminalState.getCellAt(
            border.x,
            border.y,
          )!;
          expect(workspaceTitle.style.color, theme.accent);
          expect(tester.terminalState.containsText('enter open'), isTrue);
        }, size: const Size(120, 30));
      },
    );
  }
}

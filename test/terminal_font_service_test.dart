import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/services/terminal_font_service.dart';

void main() {
  group('detectTerminalHost', () {
    test('WT_SESSION identifies Windows Terminal', () {
      expect(
        detectTerminalHost({'WT_SESSION': '{abc-123}'}),
        TerminalHost.windowsTerminal,
      );
      expect(detectTerminalHost({'WT_SESSION': ''}), isNull);
    });

    test('TERM_PROGRAM maps known hosts', () {
      expect(
        detectTerminalHost(const {'TERM_PROGRAM': 'vscode'}),
        TerminalHost.vscode,
      );
      expect(
        detectTerminalHost(const {'TERM_PROGRAM': 'iTerm.app'}),
        TerminalHost.iterm2,
      );
      expect(
        detectTerminalHost(const {'KITTY_WINDOW_ID': '1'}),
        TerminalHost.kitty,
      );
      expect(detectTerminalHost(const {}), isNull);
    });
  });

  group('TerminalFontService settings round trip', () {
    late Directory tempDir;
    late Directory packagesDir;
    late File settingsFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_wt_font_');
      final wtPackage = Directory(
        p.join(tempDir.path, 'Packages', 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'),
      )..createSync(recursive: true);
      Directory(p.join(wtPackage.path, 'LocalState')).createSync();
      packagesDir = wtPackage;
      settingsFile = File(p.join(wtPackage.path, 'LocalState', 'settings.json'));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    TerminalFontService service() =>
        TerminalFontService(localAppData: () => tempDir.path);

    test('finds the packaged settings file', () {
      settingsFile.writeAsStringSync('{}');
      expect(service().findSettingsFile()?.path, settingsFile.path);
    });

    test('falls back to the unpackaged install path', () async {
      packagesDir.deleteSync(recursive: true);
      final unpackaged = File(
        p.join(tempDir.path, 'Microsoft', 'Windows Terminal', 'settings.json'),
      )..createSync(recursive: true);
      unpackaged.writeAsStringSync('{}');
      expect(service().findSettingsFile()?.path, unpackaged.path);
    });

    test('returns null when no install exists', () async {
      expect(service().findSettingsFile(), isNull);
      expect(await service().loadStatus(), isNull);
      expect(
        await service().applyFontSettings(
          const FontSettingsEdit(cellWidthPreset: CellWidthPreset.tighter),
        ),
        isNull,
      );
    });

    test('reads font face and cellWidth from JSONC with comments', () async {
      settingsFile.writeAsStringSync('''
{
    // typed by the user
    "\$help": "https://aka.ms/terminal-documentation",
    "profiles":
    {
        "defaults":
        {
            "font":
            {
                "face": "Maple Mono NF CN", // trailing comment
                "size": 12,
                "cellWidth": "0.9ch"
            }
        },
        "list": [ /* block comment */ ]
    }
}
''');
      final status = await service().loadStatus();
      expect(status, isNotNull);
      expect(status!.fontFace, 'Maple Mono NF CN');
      expect(status.cellWidth, '0.9ch');
      expect(status.cellWidthPreset, CellWidthPreset.tighter);
    });

    test('apply preserves comments, key order, and untouched keys', () async {
      const original = '''
{
    // typed by the user
    "\$help": "https://aka.ms/terminal-documentation",
    "profiles":
    {
        "defaults":
        {
            "font":
            {
                "face": "Cascadia Mono", // trailing comment
                "size": 12
            }
        },
        "list": []
    }
}
''';
      settingsFile.writeAsStringSync(original);
      await service().applyFontSettings(
        const FontSettingsEdit(
          face: 'Maple Mono NF CN',
          cellWidthPreset: CellWidthPreset.tighter,
        ),
      );
      final after = settingsFile.readAsStringSync();
      expect(after, contains('// typed by the user'));
      // The rebuilt face line drops the trailing comment that sat on the
      // original face entry line; comments elsewhere survive.
      expect(after, isNot(contains('// trailing comment')));
      expect(after, contains('"size": 12'));
      expect(after, contains('"face": "Maple Mono NF CN"'));
      expect(after, contains('"cellWidth": "0.9ch"'));
      expect(after.indexOf('"face"'), lessThan(after.indexOf('"cellWidth"')));

      final status = await service().loadStatus();
      expect(status!.fontFace, 'Maple Mono NF CN');
      expect(status.cellWidth, '0.9ch');
      // JSONC still parses and the untouched structure survived.
      expect(after, contains('"list": []'));
    });

    test('apply removes cellWidth for the default preset', () async {
      settingsFile.writeAsStringSync('''
{
    "profiles":
    {
        "defaults":
        {
            "font":
            {
                "face": "Maple Mono NF CN",
                "cellWidth": "0.9ch"
            }
        }
    }
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(cellWidthPreset: CellWidthPreset.defaultWidth),
      );
      final after = settingsFile.readAsStringSync();
      expect(after, isNot(contains('"cellWidth"')));
      expect(after, contains('"face": "Maple Mono NF CN"'));
    });

    test('apply keeps existing face when only cellWidth is edited', () async {
      settingsFile.writeAsStringSync('''
{
    "profiles":
    {
        "defaults":
        {
            "font":
            {
                "face": "Maple Mono NF CN"
            }
        }
    }
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(cellWidthPreset: CellWidthPreset.compact),
      );
      final status = await service().loadStatus();
      expect(status!.fontFace, 'Maple Mono NF CN');
      expect(status.cellWidth, '0.95ch');
    });

    test('inserts a font object into defaults without one', () async {
      settingsFile.writeAsStringSync('''
{
    "defaultProfile": "{61c54bbd}",
    "profiles":
    {
        "defaults":
        {
            "historySize": 9001
        },
        "list": []
    }
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(
          face: 'Maple Mono NF CN',
          cellWidthPreset: CellWidthPreset.tighter,
        ),
      );
      final status = await service().loadStatus();
      expect(status!.fontFace, 'Maple Mono NF CN');
      expect(status.cellWidth, '0.9ch');
      final after = settingsFile.readAsStringSync();
      expect(after, contains('"historySize": 9001'));
      expect(after, contains('"defaultProfile"'));
    });

    test('inserts defaults when only profiles exists', () async {
      settingsFile.writeAsStringSync('''
{
    "profiles":
    {
        "list": []
    }
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(cellWidthPreset: CellWidthPreset.tighter),
      );
      final status = await service().loadStatus();
      expect(status!.cellWidth, '0.9ch');
    });

    test('inserts a profiles skeleton into an empty root', () async {
      settingsFile.writeAsStringSync('''
{
    "defaultProfile": "{61c54bbd}"
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(cellWidthPreset: CellWidthPreset.tighter),
      );
      final status = await service().loadStatus();
      expect(status!.cellWidth, '0.9ch');
      expect(settingsFile.readAsStringSync(), contains('"defaultProfile"'));
    });

    test('rejects unknown layouts instead of guessing', () {
      settingsFile.writeAsStringSync('not json at all');
      expect(
        () => FontDoc.parse(settingsFile.readAsStringSync()).editDefaultsFont(
          const FontSettingsEdit(cellWidthPreset: CellWidthPreset.tighter),
        ),
        throwsUnsupportedError,
      );
    });

    test('real-world layout from a packaged install round trips', () async {
      settingsFile.writeAsStringSync(r'''
{
    "$help": "https://aka.ms/terminal-documentation",
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "actions":
    [
        {
            "command":
            {
                "action": "copy",
                "singleLine": false
            },
            "id": "User.copy.644BA8F2"
        }
    ],
    "copyFormatting": "none",
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
    "profiles":
    {
        "defaults":
        {
            "font":
            {
                "face": "Maple Mono NF CN"
            }
        },
        "list":
        [
            {
                "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
                "hidden": false,
                "name": "Windows PowerShell"
            }
        ]
    },
    "schemes": [],
    "themes": []
}
''');
      await service().applyFontSettings(
        const FontSettingsEdit(cellWidthPreset: CellWidthPreset.tighter),
      );
      final status = await service().loadStatus();
      expect(status!.fontFace, 'Maple Mono NF CN');
      expect(status.cellWidth, '0.9ch');
      final after = settingsFile.readAsStringSync();
      expect(after, contains('"commandline"'));
      expect(after, contains('User.copy.644BA8F2'));
      expect(after, contains('"schemes": []'));
    });
  });
}

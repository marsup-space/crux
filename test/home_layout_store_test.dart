import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_layout_store.dart';

void main() {
  late Directory tempDir;
  late File configFile;
  late HomeLayoutStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_home_layout_');
    configFile = File(p.join(tempDir.path, 'config.toml'));
    store = HomeLayoutStore(configFile);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('read returns empty config when the file does not exist', () async {
    final config = await store.read();
    expect(config.showOnLaunch, isNull);
    expect(config.layout, isNull);
  });

  test('round-trips show_on_launch and layout', () async {
    await store.write(
      const HomeLayoutConfig(
        showOnLaunch: false,
        layout: [
          HomeLayoutEntry('tokens', 1),
          HomeLayoutEntry('recent-sessions', 2),
        ],
      ),
    );
    final config = await store.read();
    expect(config.showOnLaunch, isFalse);
    expect(config.layout, [
      const HomeLayoutEntry('tokens', 1),
      const HomeLayoutEntry('recent-sessions', 2),
    ]);
  });

  test('preserves other sections on write', () async {
    configFile.writeAsStringSync("[ui]\ntheme = 'dracula'\n");
    await store.write(
      const HomeLayoutConfig(layout: [HomeLayoutEntry('tokens', 1)]),
    );
    final text = configFile.readAsStringSync();
    expect(text, contains('theme'));
    expect(text, contains('dracula'));
    final config = await store.read();
    expect(config.layout, [const HomeLayoutEntry('tokens', 1)]);
  });

  test('null layout removes the layout key but keeps show_on_launch', () async {
    await store.write(
      const HomeLayoutConfig(
        showOnLaunch: false,
        layout: [HomeLayoutEntry('tokens', 1)],
      ),
    );
    await store.write(const HomeLayoutConfig(showOnLaunch: false));
    final config = await store.read();
    expect(config.showOnLaunch, isFalse);
    expect(config.layout, isNull);
  });

  test('read tolerates unparseable TOML as empty config', () async {
    configFile.writeAsStringSync('this is not [valid toml\n');
    final config = await store.read();
    expect(config.showOnLaunch, isNull);
    expect(config.layout, isNull);
  });

  test('read skips malformed layout entries and keeps valid ones', () async {
    configFile.writeAsStringSync('''
[home]
show_on_launch = true

[[home.layout]]
id = "tokens"
span = 1

[[home.layout]]
id = ""
span = 2

[[home.layout]]
span = 3
''');
    final config = await store.read();
    expect(config.showOnLaunch, isTrue);
    // Only the well-formed entry survives.
    expect(config.layout, [const HomeLayoutEntry('tokens', 1)]);
  });

  test('read returns null layout when every entry is malformed', () async {
    configFile.writeAsStringSync('''
[home]
layout = [ 1, 2, 3 ]
''');
    final config = await store.read();
    expect(config.layout, isNull);
  });

  test('write leaves no temp file behind', () async {
    await store.write(
      const HomeLayoutConfig(layout: [HomeLayoutEntry('a', 1)]),
    );
    final leftovers = tempDir
        .listSync()
        .where((e) => e.path.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });
}

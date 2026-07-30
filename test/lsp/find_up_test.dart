import 'dart:io';

import 'package:crux/src/lsp/find_up.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('find_up_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('finds marker in same directory as start', () async {
    final marker = File(p.join(tmp.path, 'pubspec.yaml'))
      ..writeAsStringSync('');
    final result = await findUp(
      markers: const ['pubspec.yaml'],
      start: tmp.path,
      stop: tmp.path,
    );
    expect(result, tmp.path);
    await marker.delete();
  });

  test('walks up to find marker in parent directory', () async {
    final sub = Directory(p.join(tmp.path, 'a', 'b'))
      ..createSync(recursive: true);
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('');
    final result = await findUp(
      markers: const ['pubspec.yaml'],
      start: sub.path,
      stop: tmp.path,
    );
    expect(result, tmp.path);
  });

  test('returns null when no marker found and stop is reached', () async {
    final sub = Directory(p.join(tmp.path, 'a', 'b'))
      ..createSync(recursive: true);
    final result = await findUp(
      markers: const ['pubspec.yaml'],
      start: sub.path,
      stop: tmp.path,
    );
    expect(result, isNull);
  });

  test('returns stop as fallback', () async {
    final sub = Directory(p.join(tmp.path, 'a'))..createSync();
    final result = await findUpOrStop(
      markers: const ['pubspec.yaml'],
      start: sub.path,
      stop: tmp.path,
    );
    expect(result, tmp.path);
  });

  test('respects excludeMarkers', () async {
    // Create /tmp/.../parent/Cargo.toml (excluded)
    //   and  /tmp/.../parent/sub/pubspec.yaml (the one we want)
    final parent = Directory(p.join(tmp.path, 'parent'))..createSync();
    File(p.join(parent.path, 'Cargo.toml')).writeAsStringSync('');
    final sub = Directory(p.join(parent.path, 'sub'))..createSync();
    File(p.join(sub.path, 'pubspec.yaml')).writeAsStringSync('');

    final result = await findUp(
      markers: const ['pubspec.yaml'],
      start: sub.path,
      stop: tmp.path,
      excludeMarkers: const ['Cargo.toml'],
    );
    expect(result, sub.path);
  });
}

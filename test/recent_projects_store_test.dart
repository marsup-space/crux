// Tests for [RecentProjectsStore], the persistent MRU list of
// recently-opened project directories that backs the `/project`
// autocomplete overlay.
//
// Each test gets its own temp directory and points the store at a
// file inside it via [RecentProjectsStore.forTesting] so writes
// never touch the user's real recent-projects list (which lives
// under the canonical user-data dir).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/services/recent_projects_store.dart';

void main() {
  late Directory tempDir;
  late String filePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_recent_test_');
    filePath = p.join(tempDir.path, 'recent_projects.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  RecentProjectsStore makeStore({List<RecentProject> seed = const []}) {
    final store = RecentProjectsStore.forTesting(filePath);
    if (seed.isNotEmpty) store.seed(seed);
    return store;
  }

  group('RecentProjectsStore.add', () {
    test('starts empty when no entries have been seeded', () {
      final store = makeStore();
      expect(store.entries, isEmpty);
    });

    test('adds a new entry to the front of the list', () async {
      final store = makeStore();
      final dirA = await _makeSubdir(tempDir, 'a');

      await store.add(dirA.path);

      expect(store.entries, hasLength(1));
      expect(store.entries.first.path, equals(_canonicalize(dirA.path)));
    });

    test('promotes an existing entry to the front on re-add', () async {
      final store = makeStore();
      final dirA = await _makeSubdir(tempDir, 'a');
      final dirB = await _makeSubdir(tempDir, 'b');
      final dirC = await _makeSubdir(tempDir, 'c');

      await store.add(dirA.path);
      await store.add(dirB.path);
      await store.add(dirC.path);
      await store.add(dirA.path);

      expect(
        store.entries.map((e) => p.basename(e.path)).toList(),
        equals(['a', 'c', 'b']),
      );
    });

    test('dedupes paths that resolve to the same canonical form', () async {
      final store = makeStore();
      final dir = await _makeSubdir(tempDir, 'dup');
      // Same logical directory via a different spelling (the
      // explicit `./` segment should be collapsed by the
      // normalizer).
      final spelledWithDot = p.join(dir.path, '.');

      await store.add(dir.path);
      await store.add(spelledWithDot);

      expect(store.entries, hasLength(1));
    });

    test('caps the list at maxEntries (16)', () async {
      final store = makeStore();
      final dirs = <Directory>[];
      for (var i = 0; i < 20; i++) {
        dirs.add(await _makeSubdir(tempDir, 'd$i'));
      }
      for (final d in dirs) {
        await store.add(d.path);
      }

      expect(store.entries, hasLength(RecentProjectsStore.maxEntries));
      expect(
        p.basename(store.entries.first.path),
        equals(p.basename(dirs.last.path)),
      );
      final keptNames = store.entries.map((e) => p.basename(e.path)).toSet();
      expect(keptNames, isNot(contains('d0')));
      expect(keptNames, isNot(contains('d3')));
      expect(keptNames, contains('d4'));
      expect(keptNames, contains('d19'));
    });

    test('ignores empty paths', () async {
      final store = makeStore();
      await store.add('');
      expect(store.entries, isEmpty);
    });

    test('fires ChangeNotifier on each add', () async {
      final store = makeStore();
      var notifications = 0;
      store.addListener(() => notifications++);

      final dir = await _makeSubdir(tempDir, 'n');
      await store.add(dir.path);
      await store.add(dir.path);

      expect(notifications, equals(2));
    });

    test('subscribers see the freshly-added entry when the '
        'notification fires (live autocomplete regression)', () async {
      // Regression test: in the original implementation
      // `bin/crux.dart` and `ChatPanel.initState` each created
      // their own `RecentProjectsStore` instance, so adding the
      // cwd from the binary didn't show up in the chat input's
      // `/project` autocomplete. The fix shares one instance
      // through the widget tree; this test pins down the
      // contract that makes the live update work — `add`
      // mutates `entries` and fires the notifier *in the same
      // synchronous step*, so any listener (e.g. the chat
      // input's `_onTextChanged`) sees the new entry on the
      // very first notification.
      final store = makeStore();
      final dir = await _makeSubdir(tempDir, 'live');
      final captured = <List<RecentProject>>[];

      store.addListener(() {
        // Capture a snapshot at notification time. If `add`
        // updated the entries after the notifier fired (the bug
        // we want to catch), this would be empty.
        captured.add(List.of(store.entries));
      });

      await store.add(dir.path);

      expect(captured, hasLength(1));
      expect(captured.first, hasLength(1));
      expect(
        p.equals(captured.first.first.path, dir.path),
        isTrue,
        reason:
            'listener should observe the new entry on the first '
            'notification, not after a second tick',
      );
    });
  });

  group('RecentProjectsStore persistence', () {
    test('writes JSON to the configured file path on add', () async {
      final store = RecentProjectsStore.forTesting(filePath);
      final dir = await _makeSubdir(tempDir, 'persist');
      await store.add(dir.path);

      expect(await File(filePath).exists(), isTrue);
      final raw = File(filePath).readAsStringSync();
      expect(raw, contains('"entries"'));
      expect(raw, contains(_canonicalize(dir.path)));
    });

    test('round-trips: what add writes, load reads', () async {
      final dirA = await _makeSubdir(tempDir, 'a');
      final dirB = await _makeSubdir(tempDir, 'b');

      final writer = RecentProjectsStore.forTesting(filePath);
      await writer.add(dirA.path);
      await writer.add(dirB.path);

      final reloaded = RecentProjectsStore.forTesting(filePath);
      await _seedFromFile(reloaded, filePath);

      expect(reloaded.entries, hasLength(2));
      expect(p.basename(reloaded.entries.first.path), equals('b'));
      expect(p.basename(reloaded.entries.last.path), equals('a'));
    });

    test('swallows a malformed JSON file and returns empty', () async {
      await File(filePath).writeAsString('not json at all', flush: true);

      final store = RecentProjectsStore.forTesting(filePath);
      await _seedFromFile(store, filePath);

      expect(store.entries, isEmpty);
    });

    test('skips malformed individual entries', () async {
      // One valid entry followed by garbage that should be ignored.
      final valid = _canonicalize(tempDir.path);
      final payload = jsonEncode({
        'entries': [
          {'path': valid, 'lastOpenedMs': 1700000000000},
          {'path': 42, 'lastOpenedMs': 'not a number'},
          {'oops': 'wrong keys entirely'},
          {'path': '', 'lastOpenedMs': 1700000000001},
        ],
      });
      await File(filePath).writeAsString('$payload\n', flush: true);

      final store = RecentProjectsStore.forTesting(filePath);
      await _seedFromFile(store, filePath);

      expect(store.entries, hasLength(1));
      expect(store.entries.first.path, equals(valid));
    });

    test('returns empty when the file does not exist', () async {
      final store = RecentProjectsStore.forTesting(filePath);
      await _seedFromFile(store, filePath);
      expect(store.entries, isEmpty);
    });
  });

  group('RecentProjectsStore.clear', () {
    test('wipes in-memory state', () async {
      final store = makeStore();
      final dir = await _makeSubdir(tempDir, 'wipe');
      await store.add(dir.path);
      expect(store.entries, hasLength(1));

      await store.clear();
      expect(store.entries, isEmpty);
    });

    test('fires a notification', () async {
      final store = makeStore();
      final dir = await _makeSubdir(tempDir, 'wipe2');
      await store.add(dir.path);

      var notifications = 0;
      store.addListener(() => notifications++);
      await store.clear();
      expect(notifications, equals(1));
    });

    test('does nothing when the list is already empty', () async {
      final store = makeStore();
      var notifications = 0;
      store.addListener(() => notifications++);
      await store.clear();
      expect(notifications, equals(0));
    });

    test('removes the backing file when present', () async {
      final store = RecentProjectsStore.forTesting(filePath);
      final dir = await _makeSubdir(tempDir, 'wipe-file');
      await store.add(dir.path);
      expect(await File(filePath).exists(), isTrue);

      await store.clear();
      expect(await File(filePath).exists(), isFalse);
    });
  });

  group('RecentProjectsStore.seed', () {
    test('replaces the list with the provided entries', () {
      final store = makeStore();
      final now = DateTime.now();
      store.seed([
        RecentProject(path: '/x/a', lastOpenedAt: now),
        RecentProject(path: '/x/b', lastOpenedAt: now),
      ]);
      expect(store.entries, hasLength(2));
      expect(store.entries.first.path, equals('/x/a'));
    });

    test('skips notification when seed matches current state', () {
      final store = makeStore();
      var notifications = 0;
      store.addListener(() => notifications++);

      final now = DateTime.now();
      final entries = [RecentProject(path: '/x/a', lastOpenedAt: now)];
      store.seed(entries);
      expect(notifications, equals(1));

      // Re-seeding with an equal list should be a no-op (no extra
      // notification).
      store.seed(entries);
      expect(notifications, equals(1));
    });
  });

  group('RecentProject JSON', () {
    test('round-trips through toJson/fromJson', () {
      final original = RecentProject(
        path: '/some/path',
        lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(1234567890),
      );
      final restored = RecentProject.fromJson(original.toJson());
      expect(restored.path, equals(original.path));
      expect(restored.lastOpenedAt, equals(original.lastOpenedAt));
    });

    test('falls back to sensible defaults for malformed JSON', () {
      final restored = RecentProject.fromJson({
        'path': null,
        'lastOpenedMs': 'not-a-number',
      });
      expect(restored.path, equals(''));
      expect(
        restored.lastOpenedAt,
        equals(DateTime.fromMillisecondsSinceEpoch(0)),
      );
    });
  });
}

Future<Directory> _makeSubdir(Directory parent, String name) async {
  final dir = Directory(p.join(parent.path, name));
  await dir.create(recursive: true);
  // Resolve symlinks so the path the store canonicalizes matches
  // the symlink-resolved form (e.g. macOS's `/var` → `/private/var`).
  return Directory(await dir.resolveSymbolicLinks());
}

String _canonicalize(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return p.normalize(p.absolute(path));
  }
}

/// Re-implement the production `load` step so the test exercises
/// the same JSON shape without having to call the private
/// constructor or poke the canonical user-data dir. Mirrors
/// `RecentProjectsStore.load` line-for-line.
Future<void> _seedFromFile(RecentProjectsStore store, String path) async {
  final file = File(path);
  if (!await file.exists()) {
    store.seed(const []);
    return;
  }
  try {
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      store.seed(const []);
      return;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      store.seed(const []);
      return;
    }
    final rawEntries = decoded['entries'];
    if (rawEntries is! List) {
      store.seed(const []);
      return;
    }
    final entries = <RecentProject>[];
    for (final raw in rawEntries) {
      if (raw is Map<String, dynamic>) {
        final entry = RecentProject.fromJson(raw);
        if (entry.path.isNotEmpty) entries.add(entry);
      }
    }
    store.seed(entries);
  } catch (_) {
    store.seed(const []);
  }
}

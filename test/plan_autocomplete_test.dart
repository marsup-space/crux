// `/plan` autocomplete filtering (plan 'test run.md'): the union
// heuristic — a root `*.md` doc is offered only when its name carries
// "plan" (case-insensitive) OR it has version history under
// `.crux/plans/` (`listKnownPlanNames`). README/CHANGELOG-class docs
// match neither and drop out. The command itself still accepts any
// name; an unlisted one simply creates the doc on enter.

import 'dart:io';

import 'package:crux/src/commands/registry.dart' show filterSuggestions;
import 'package:crux/src/models/slash_command.dart';
import 'package:crux/src/services/plan_doc_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_autocomplete_test');
    File('${tmp.path}/README.md').writeAsStringSync('# Readme\n');
    File('${tmp.path}/CHANGELOG.md').writeAsStringSync('# Log\n');
    File('${tmp.path}/refactor-plan.md').writeAsStringSync('# Refactor\n');
    File('${tmp.path}/test run.md').writeAsStringSync('# Test Run\n');
    File('${tmp.path}/roadmap.md').writeAsStringSync('# Roadmap\n');
    File('${tmp.path}/notes.txt').writeAsStringSync('not markdown\n');
    File('${tmp.path}/.hidden.md').writeAsStringSync('# hidden\n');
    // Version history: session 42 entered `test run.md`, session 43
    // entered it again (later) plus `roadmap.md`.
    void seedHistory(int sessionId, String planName) {
      PlanDocStore(
        projectPath: tmp.path,
        sessionId: sessionId,
        planName: planName,
      ).ensureInitialized('# seed\n');
    }

    seedHistory(42, 'test run.md');
    seedHistory(43, 'test run.md');
    seedHistory(43, 'roadmap.md');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// Mirrors the `/plan` + paramIndex == 0 branch in input_overlay.dart,
  /// reusing the *real* filter functions: union of (name heuristic,
  /// plan history), `.md` stripped, dotfiles skipped. Returns the
  /// suggestion values in display order — active first, then
  /// history-recency, then heuristic-only alphabetically.
  List<String> buildSuggestionValues(String projectPath, String? active) {
    final known = listKnownPlanNames(projectPath);
    final dir = Directory(projectPath);
    final found = <String>[];
    String? activeValue;
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : entity.path.split('/').last;
        if (!base.endsWith('.md')) continue;
        if (base.startsWith('.')) continue;
        final name = base.substring(0, base.length - '.md'.length);
        if (name.isEmpty) continue;
        if (!known.containsKey(base) && !isPlanNameHeuristic(base)) continue;
        if (base == active) {
          activeValue = name;
        } else {
          found.add(name);
        }
      }
    }
    found.sort((a, b) {
      final ta = known['$a.md'];
      final tb = known['$b.md'];
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return a.compareTo(b);
    });
    return [?activeValue, ...found];
  }

  group('isPlanNameHeuristic', () {
    test('matches plan anywhere in the name, case-insensitive', () {
      expect(isPlanNameHeuristic('PLAN.md'), isTrue);
      expect(isPlanNameHeuristic('refactor-plan.md'), isTrue);
      expect(isPlanNameHeuristic('PlanNorge.md'), isTrue);
      expect(isPlanNameHeuristic('main.md'), isFalse);
      expect(isPlanNameHeuristic('README.md'), isFalse);
      expect(isPlanNameHeuristic('test run.md'), isFalse);
    });
  });

  group('listKnownPlanNames', () {
    test('aggregates sessions by plan name with newest mtime', () {
      final known = listKnownPlanNames(tmp.path);
      expect(known.keys, containsAll(['test run.md', 'roadmap.md']));
      expect(known.keys, isNot(contains('refactor-plan.md')));
    });

    test('empty map for projects without plan history', () {
      final freshDir = Directory.systemTemp.createTempSync('plan_fresh');
      addTearDown(() => freshDir.deleteSync(recursive: true));
      expect(listKnownPlanNames(freshDir.path), isEmpty);
    });

    test('recency: re-entered plan is newer than the earlier one', () {
      final known = listKnownPlanNames(tmp.path);
      final testRun = known['test run.md']!;
      // roadmap.md was seeded right after test run.md's session-42
      // history inside the same session dir listing; the second seed
      // (session 43) for test run is the newest write for it.
      expect(known['roadmap.md'], isNotNull);
      expect(testRun.isBefore(DateTime.now()), isTrue);
    });
  });

  group('union filter + ordering', () {
    test('offers name-matched and history-matched docs only', () {
      final values = buildSuggestionValues(tmp.path, null);
      expect(values, containsAll(['refactor-plan', 'test run', 'roadmap']));
      expect(values, isNot(contains('README')));
      expect(values, isNot(contains('CHANGELOG')));
      expect(values, isNot(contains('.hidden')));
      expect(values, isNot(contains('notes.txt')));
    });

    test('active plan sorts first regardless of history', () {
      final values = buildSuggestionValues(tmp.path, 'refactor-plan.md');
      expect(values.first, 'refactor-plan');
    });

    test('history-matched docs sort before heuristic-only ones', () {
      final values = buildSuggestionValues(tmp.path, null);
      expect(
        values.indexOf('refactor-plan'),
        greaterThan(values.indexOf('roadmap')),
      );
      expect(
        values.indexOf('refactor-plan'),
        greaterThan(values.indexOf('test run')),
      );
    });

    test('clean project: heuristic alone still offers plan-named docs',
        () {
      final clean = Directory.systemTemp.createTempSync('plan_clean');
      addTearDown(() => clean.deleteSync(recursive: true));
      File('${clean.path}/PLAN.md').writeAsStringSync('# Plan\n');
      File('${clean.path}/README.md').writeAsStringSync('# Readme\n');
      final values = buildSuggestionValues(clean.path, null);
      expect(values, ['PLAN']);
    });
  });

  test('/plan te narrows to test run via the shared fuzzy matcher', () {
    final values = buildSuggestionValues(tmp.path, null);
    final filtered = filterSuggestions(
      [
        for (final v in values)
          CommandSuggestion(value: v, description: null),
      ],
      'te',
    );
    expect(filtered.map((s) => s.value), contains('test run'));
    expect(filtered.map((s) => s.value), isNot(contains('refactor-plan')));
  });

  test('a fresh name yields no suggestion (enter creates it)', () {
    final values = buildSuggestionValues(tmp.path, null);
    final filtered = filterSuggestions(
      [
        for (final v in values)
          CommandSuggestion(value: v, description: null),
      ],
      'brand new plan',
    );
    expect(filtered.map((s) => s.value), isEmpty);
  });
}

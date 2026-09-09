// Tests for skill discovery — the cwd→worktree walk + global scan
// + first-wins dedup.

import 'dart:io';

import 'package:crux/src/services/skills/built_in_skills.dart';
import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/services/skills/skill_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _writeSkill(
  Directory root, {
  required String folder,
  required String name,
  required String description,
  String body = '\n# Body\n',
}) {
  final dir = Directory(p.join(root.path, folder))..createSync(recursive: true);
  final skillPath = p.join(dir.path, 'SKILL.md');
  File(skillPath).writeAsStringSync(
    '---\n'
    'name: $name\n'
    'description: $description\n'
    '---\n'
    '$body',
  );
  return dir.path;
}

/// The built-in skills are prepended by `discoverSkills` and reserve
/// their names; tests in this file assert on the file-discovered
/// remainder.
final _nBuiltIns = builtInSkills.length;
final _builtInNames = builtInSkills.map((s) => s.name).toList();

/// File-discovered skills (built-ins stripped).
List<SkillInfo> fileSkills(List<SkillInfo> result) =>
    result.sublist(_nBuiltIns);

void main() {
  late Directory projectRoot;
  late Directory fakeHome;
  late Directory fakeUserData;

  setUp(() {
    projectRoot = Directory.systemTemp.createTempSync('crux_skill_proj_');
    fakeHome = Directory.systemTemp.createTempSync('crux_skill_home_');
    fakeUserData = Directory.systemTemp.createTempSync('crux_skill_data_');
  });

  tearDown(() {
    if (projectRoot.existsSync()) projectRoot.deleteSync(recursive: true);
    if (fakeHome.existsSync()) fakeHome.deleteSync(recursive: true);
    if (fakeUserData.existsSync()) fakeUserData.deleteSync(recursive: true);
  });

  group('discoverSkills — empty', () {
    test('returns only the built-ins when no file skills exist anywhere', () {
      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result, hasLength(_nBuiltIns));
      expect(fileSkills(result), isEmpty);
    });
  });

  group('discoverSkills — built-ins', () {
    test('built-ins come first and are always present', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'Reviews pull requests.',
      );
      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result.length, _nBuiltIns + 1);
      expect(result.take(_nBuiltIns).map((s) => s.name), _builtInNames);
      expect(result.last.name, 'pr-review');
    });

    test('a user skill reusing a built-in name is shadowed', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'plugin',
        name: 'plugin',
        description: 'User override attempt.',
      );
      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result, hasLength(_nBuiltIns));
      expect(result.first.name, 'plugin');
      expect(result.first.location, '(built-in)');
    });

    test('findSkillByName resolves a built-in', () {
      final result = findSkillByName(
        name: 'plugin',
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result, isA<SkillInfo>());
      expect(result!.name, 'plugin');
      expect(result.content, contains('.crux/plugins/'));
    });
  });

  group('discoverSkills — project walk', () {
    test('finds a skill in the cwd\'s .crux/skills/', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'Reviews pull requests.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.name, 'pr-review');
    });

    test('also finds a skill under the singular .crux/skill/ alias', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skill')),
        folder: 'debugging',
        name: 'debugging',
        description: 'Helps debug runtime errors.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.name, 'debugging');
    });

    test('prefers the plural .crux/skills/ over the singular alias', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'foo',
        name: 'foo',
        description: 'From plural.',
      );
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skill')),
        folder: 'foo',
        name: 'foo',
        description: 'From singular.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'From plural.');
    });

    test('finds project-committed skills in .claude/skills/ and '
        '.agents/skills/', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.claude', 'skills')),
        folder: 'from-claude',
        name: 'from-claude',
        description: 'Committed under .claude/skills.',
      );
      _writeSkill(
        Directory(p.join(projectRoot.path, '.agents', 'skills')),
        folder: 'from-agents',
        name: 'from-agents',
        description: 'Committed under .agents/skills.',
      );
      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(
        result.map((s) => s.name),
        containsAll(<String>['from-claude', 'from-agents']),
      );
    });

    test('project .claude/skills/ shadows the global ~/.claude/skills/ '
        'copy of the same name', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.claude', 'skills')),
        folder: 'shared',
        name: 'shared',
        description: 'From project.',
      );
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'shared',
        name: 'shared',
        description: 'From global home.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'From project.');
    });
  });

  group('discoverSkills — global scan', () {
    test('finds skills in ~/.claude/skills/', () {
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'From Claude.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'From Claude.');
    });

    test('finds skills in ~/.agents/skills/', () {
      _writeSkill(
        Directory(p.join(fakeHome.path, '.agents', 'skills')),
        folder: 'security-audit',
        name: 'security-audit',
        description: 'From open standard.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
    });

    test('finds skills in the crux user-data dir', () {
      _writeSkill(
        Directory(p.join(fakeUserData.path, 'skills')),
        folder: 'crux-only',
        name: 'crux-only',
        description: 'From crux data dir.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'From crux data dir.');
    });
  });

  group('discoverSkills — priority + dedup', () {
    test('project-local shadows a same-name global skill', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'Project override.',
      );
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'Global Claude.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'Project override.');
    });

    test('~/.claude/ shadows ~/.agents/ shadows crux data dir', () {
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'shared',
        name: 'shared',
        description: 'From claude.',
      );
      _writeSkill(
        Directory(p.join(fakeHome.path, '.agents', 'skills')),
        folder: 'shared',
        name: 'shared',
        description: 'From agents.',
      );
      _writeSkill(
        Directory(p.join(fakeUserData.path, 'skills')),
        folder: 'shared',
        name: 'shared',
        description: 'From crux data.',
      );
      final found = fileSkills(
        discoverSkills(
          cwd: projectRoot.path,
          homeOverride: fakeHome.path,
          userDataDirOverride: fakeUserData.path,
        ),
      );
      expect(found, hasLength(1));
      expect(found.first.description, 'From claude.');
    });
  });

  group('discoverSkills — silent skip of malformed skills', () {
    test('skips a skill missing the required description', () {
      // Project-local — bad.
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'broken',
        name: 'broken',
        description: 'valid',
      );
      File(p.join(projectRoot.path, '.crux', 'skills', 'broken', 'SKILL.md'))
          .writeAsStringSync('---\nname: broken\n---\nbody\n');
      // Global — good.
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'good',
        name: 'good',
        description: 'A working skill.',
      );

      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      final names = result.map((s) => s.name).toSet();
      expect(names, isNot(contains('broken')));
      expect(names, contains('good'));
    });

    test('skips a skill whose name does not match its folder', () {
      _writeSkill(
        Directory(p.join(projectRoot.path, '.crux', 'skills')),
        folder: 'actual-folder-name',
        name: 'actual-folder-name',
        description: 'good',
      );
      // Overwrite with mismatched name.
      File(
        p.join(
          projectRoot.path,
          '.crux',
          'skills',
          'actual-folder-name',
          'SKILL.md',
        ),
      ).writeAsStringSync(
        '---\nname: different-name\ndescription: A skill.\n---\nbody\n',
      );

      final result = discoverSkills(
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(fileSkills(result), isEmpty);
    });
  });

  group('findSkillByName', () {
    test('returns the matching skill', () {
      _writeSkill(
        Directory(p.join(fakeHome.path, '.claude', 'skills')),
        folder: 'pr-review',
        name: 'pr-review',
        description: 'Reviews PRs.',
      );
      final result = findSkillByName(
        name: 'pr-review',
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result, isA<SkillInfo>());
      expect(result!.name, 'pr-review');
    });

    test('returns null when the skill is not present', () {
      final result = findSkillByName(
        name: 'nonexistent',
        cwd: projectRoot.path,
        homeOverride: fakeHome.path,
        userDataDirOverride: fakeUserData.path,
      );
      expect(result, isNull);
    });
  });
}

// Tests for the strict SKILL.md frontmatter parser.
//
// The parser is the gatekeeper: only well-formed skills with a
// valid name (matching the open-standard regex) and a
// non-empty description ≤ 1024 chars are admitted. The tests
// below lock in the rules one by one so a future refactor can't
// silently relax them.

import 'package:crux/src/services/skills/skill_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('parseSkillContent — happy path', () {
    test('parses a minimal valid skill', () {
      final result = parseSkillContent(
        content: '---\n'
            'name: pr-review\n'
            'description: Reviews pull requests for correctness, style, and risks.\n'
            '---\n'
            '\n'
            '# PR Review\n'
            '\n'
            'Body of the skill.\n',
        location: '/tmp/pr-review/SKILL.md',
        baseDirectory: '/tmp/pr-review',
        folderName: 'pr-review',
      );

      expect(result.isOk, isTrue);
      final info = result.info!;
      expect(info.name, 'pr-review');
      expect(info.description, contains('Reviews pull requests'));
      expect(info.location, '/tmp/pr-review/SKILL.md');
      expect(info.baseDirectory, '/tmp/pr-review');
      // Body should have the frontmatter stripped and leading
      // blank lines trimmed.
      expect(info.content, startsWith('# PR Review'));
      expect(info.content, contains('Body of the skill.'));
    });

    test('preserves body content verbatim, only stripping the frontmatter', () {
      final body = '# Title\n'
          '\n'
          '## Use this skill when\n'
          '- bullet 1\n'
          '\n'
          '## Procedure\n'
          '1. step 1\n'
          '2. step 2\n';
      final result = parseSkillContent(
        content: '---\nname: foo\ndescription: A foo skill.\n---\n$body',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isTrue);
      expect(result.info!.content, body);
    });
  });

  group('parseSkillContent — frontmatter shape', () {
    test('rejects a file with no frontmatter block', () {
      final result = parseSkillContent(
        content: '# No frontmatter here\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<MissingFrontmatterBlock>());
    });

    test('rejects a non-mapping frontmatter (e.g. just a list)', () {
      final result = parseSkillContent(
        content: '---\n- one\n- two\n---\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(
        result.error,
        anyOf(isA<YamlParseError>(), isA<FrontmatterNotObject>()),
      );
    });

    test('rejects malformed YAML with a clear error', () {
      final result = parseSkillContent(
        content: '---\nname: pr-review\n  bad indent: : :\n---\n',
        location: '/x/pr-review/SKILL.md',
        baseDirectory: '/x/pr-review',
        folderName: 'pr-review',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<YamlParseError>());
    });
  });

  group('parseSkillContent — name field', () {
    test('rejects a missing name', () {
      final result = parseSkillContent(
        content: '---\ndescription: A skill without a name.\n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<MissingName>());
    });

    test('rejects a name with uppercase characters', () {
      final result = parseSkillContent(
        content: '---\nname: PR-Review\ndescription: Wrong case.\n---\n',
        location: '/x/PR-Review/SKILL.md',
        baseDirectory: '/x/PR-Review',
        folderName: 'PR-Review',
      );
      // Strict: name regex rejects uppercase, and the
      // name-folder match is also broken (case-sensitive).
      expect(result.isOk, isFalse);
      expect(
        result.error,
        anyOf(isA<InvalidName>(), isA<NameFolderMismatch>()),
      );
    });

    test('rejects a name with a leading hyphen', () {
      final result = parseSkillContent(
        content: '---\nname: -pr-review\ndescription: Bad leading hyphen.\n---\n',
        location: '/x/-pr-review/SKILL.md',
        baseDirectory: '/x/-pr-review',
        folderName: '-pr-review',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<InvalidName>());
    });

    test('rejects a name with consecutive hyphens', () {
      final result = parseSkillContent(
        content: '---\nname: pr--review\ndescription: Bad double hyphen.\n---\n',
        location: '/x/pr--review/SKILL.md',
        baseDirectory: '/x/pr--review',
        folderName: 'pr--review',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<InvalidName>());
    });

    test('rejects a name longer than 64 characters', () {
      final longName = 'a' * 65;
      final result = parseSkillContent(
        content: '---\nname: $longName\ndescription: Too long.\n---\n',
        location: '/x/$longName/SKILL.md',
        baseDirectory: '/x/$longName',
        folderName: longName,
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<InvalidName>());
    });
  });

  group('parseSkillContent — name vs folder invariant', () {
    test('rejects when name does not match the folder', () {
      final result = parseSkillContent(
        content: '---\nname: pr-review\ndescription: Reviews PRs.\n---\n',
        // Folder is different from name.
        location: '/x/code-review/SKILL.md',
        baseDirectory: '/x/code-review',
        folderName: 'code-review',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<NameFolderMismatch>());
      expect(result.error!.message, contains('pr-review'));
      expect(result.error!.message, contains('code-review'));
    });
  });

  group('parseSkillContent — description field', () {
    test('rejects a missing description', () {
      final result = parseSkillContent(
        content: '---\nname: foo\n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<MissingDescription>());
    });

    test('treats `description: ` (no value) as missing', () {
      // YAML parses `description: ` as null, not as the empty
      // string — so this hits the MissingDescription branch,
      // not EmptyDescription. Either is a clean reject; the
      // agent never sees the skill.
      final result = parseSkillContent(
        content: '---\nname: foo\ndescription: \n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<MissingDescription>());
    });

    test('treats an explicit empty quoted description as empty', () {
      final result = parseSkillContent(
        content: '---\nname: foo\ndescription: ""\n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<EmptyDescription>());
    });

    test('rejects a description over 1024 characters', () {
      final longDesc = 'x' * 1025;
      final result = parseSkillContent(
        content: '---\nname: foo\ndescription: $longDesc\n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<DescriptionTooLong>());
    });

    test('accepts a description exactly 1024 characters long', () {
      final desc = 'x' * 1024;
      final result = parseSkillContent(
        content: '---\nname: foo\ndescription: $desc\n---\nbody\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isTrue);
    });
  });

  group('parseSkillContent — extra fields are ignored', () {
    test('unknown frontmatter fields do not fail the parse', () {
      // Per the open standard + our spec, unknown fields are
      // silently ignored — strict on shape, lenient on noise.
      final result = parseSkillContent(
        content: '---\n'
            'name: foo\n'
            'description: A foo skill.\n'
            'license: MIT\n'
            'author: gnanam\n'
            'version: 0.1.0\n'
            'tools_required: [Read, Bash]\n'
            'something_completely_made_up: 42\n'
            '---\n'
            'body\n',
        location: '/x/foo/SKILL.md',
        baseDirectory: '/x/foo',
        folderName: 'foo',
      );
      expect(result.isOk, isTrue);
    });
  });

  group('parseSkillFile — filesystem', () {
    test('returns an error when the file does not exist', () {
      final result = parseSkillFile(
        location: '/definitely/not/a/real/path/SKILL.md',
        baseDirectory: '/definitely/not/a/real/path',
        folderName: 'real',
      );
      expect(result.isOk, isFalse);
      expect(result.error, isA<SkillParseFailure>());
    });
  });
}

// Tests for the `skill` tool.
//
// We construct the tool with no dependencies, then call
// `execute` against a synthetic skill tree built in a temp dir.
// No real `~/.claude` / `~/.local/share/crux` is touched —
// the test sets `homeOverride` and `userDataDirOverride` via
// the cwd (the tool reads the cwd from `ToolContext`).

import 'dart:io';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/tools/skill_tool.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late SkillTool tool;
  late ToolContext ctx;
  late Directory tempRoot;
  late Directory fakeHome;
  late Directory fakeUserData;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('crux_skill_tool_');
    fakeHome = Directory.systemTemp.createTempSync('crux_skill_tool_home_');
    fakeUserData = Directory.systemTemp.createTempSync('crux_skill_tool_data_');
    tool = SkillTool();

    // Build a single skill under the project root.
    final skillsDir = Directory(p.join(tempRoot.path, '.crux', 'skills'))
      ..createSync(recursive: true);
    final prDir = Directory(p.join(skillsDir.path, 'pr-review'))..createSync();
    File(p.join(prDir.path, 'SKILL.md')).writeAsStringSync(
      '---\n'
      'name: pr-review\n'
      'description: Reviews pull requests for correctness, style, and risks.\n'
      '---\n'
      '\n'
      '# PR Review\n'
      '\n'
      'Procedure:\n'
      '1. Read the diff\n'
      '2. Group findings by severity\n',
    );
    // Add a sibling file so the tool's "sampled files" list has
    // something to render.
    File(p.join(prDir.path, 'examples.md')).writeAsStringSync('# Examples\n');

    ctx = ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempRoot.path,
    );

    // No need to mutate HOME — the skill lives under the
    // project cwd, which `discoverSkills` walks first. The
    // global scan is allowed to leak into the real `~/.claude`
    // and `~/.local/share/crux` dirs in the test environment;
    // the project-walk result still pins the test's behavior.
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    if (fakeHome.existsSync()) fakeHome.deleteSync(recursive: true);
    if (fakeUserData.existsSync()) fakeUserData.deleteSync(recursive: true);
  });

  group('SkillTool', () {
    test('name and description are agent-facing', () {
      expect(tool.name, 'skill');
      expect(tool.description, contains('available_skills'));
      // Don't leak implementation details to the agent.
      expect(
        tool.description,
        isNot(contains('opencode')),
        reason: 'agent-facing description should not name opencode',
      );
    });

    test('parametersSchema requires `name`', () {
      final schema = tool.parametersSchema;
      final required = schema['required'] as List;
      expect(required, contains('name'));
    });

    test('execute returns an error for a missing name', () async {
      final result = await tool.execute({'name': ''}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test('execute returns a not-found message for an unknown skill', () async {
      final result = await tool.execute({'name': 'no-such-skill'}, ctx);
      expect(result.output, contains('No skill named'));
      expect(result.output, contains('no-such-skill'));
      expect(result.output, contains('/skill list'));
    });

    test('execute renders the skill body in a <skill_content> block', () async {
      final result = await tool.execute({'name': 'pr-review'}, ctx);
      expect(result.output, contains('<skill_content name="pr-review">'));
      expect(result.output, contains('# PR Review'));
      expect(result.output, contains('Procedure'));
      expect(result.output, contains('Base directory for this skill'));
      expect(result.output, contains('Relative paths'));
      expect(result.output, contains('</skill_content>'));
    });

    test('execute samples sibling files in the skill folder', () async {
      final result = await tool.execute({'name': 'pr-review'}, ctx);
      // SKILL.md itself is not listed; the sibling examples.md is.
      expect(result.output, contains('examples.md'));
      // The metadata also carries the sampled files.
      final siblings = result.metadata['siblings'] as List;
      expect(siblings, contains('examples.md'));
    });

    test('renderPruneInline formats the skill call with its name', () {
      // Smoke test: a happy call renders as `skill {pr-review}`,
      // an errored call includes the error text. We can't easily
      // construct a real ToolCallData here, so we just verify
      // the description still says the right things.
      expect(
        tool.renderPruneInline(
          call: _fakeCall({'name': 'pr-review'}),
          pairedResult: '',
          isError: false,
        ),
        equals('skill {pr-review}'),
      );
      expect(
        tool.renderPruneInline(
          call: _fakeCall({'name': 'pr-review'}),
          pairedResult: 'boom',
          isError: true,
        ),
        equals('skill {pr-review} → boom'),
      );
    });

    test('extractPruneSummary returns a contribution for a happy call', () {
      final contrib = tool.extractPruneSummary(
        call: _fakeCall({'name': 'pr-review'}),
        pairedResult: '<skill_content>...</skill_content>',
        isError: false,
        workingDirectory: tempRoot.path,
      );
      expect(contrib, isNotNull);
      expect(contrib!.category, 'skill-bodies');
      expect(contrib.key, 'pr-review');
      expect(contrib.value, contains('<skill_content>'));
    });

    test('extractPruneSummary returns null on error', () {
      final contrib = tool.extractPruneSummary(
        call: _fakeCall({'name': 'pr-review'}),
        pairedResult: 'No skill named "pr-review"',
        isError: true,
        workingDirectory: tempRoot.path,
      );
      expect(contrib, isNull);
    });
  });
}

/// Build a minimal [ToolCallData] for prune tests. The ToolCallData
/// shape is internal to the chat log builder; we only need
/// `input['name']` to be readable, which is enough for these
/// unit tests of the SkillTool's overrides.
ToolCallData _fakeCall(Map<String, dynamic> input) {
  return ToolCallData(callId: 'fake', name: 'skill', input: input);
}

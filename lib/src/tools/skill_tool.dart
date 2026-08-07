/// `skill` tool — load a discovered skill's full body into context.
///
/// Mirrors opencode's `tool/skill.ts`:
///   - input: `{ name: string }`
///   - output: `<skill_content name="…">…</skill_content>` block
///     containing the body, base directory, and a sample of the
///     sibling files (so the LLM knows what's in the folder).
///
/// The LLM only ever sees the names + descriptions in the
/// `<available_skills>` block of the system prompt. Calling this
/// tool is the explicit "load this skill" gesture. Until then,
/// the body is paid for in zero tokens.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../services/skills/built_in_skills.dart';
import '../services/skills/skill.dart';
import '../services/skills/skill_discovery.dart';
import 'tool_def.dart';

const _maxSampledSiblings = 10;

class SkillTool extends ToolDef {
  @override
  String get name => 'skill';

  @override
  String get description =>
      '🚨 Load a specialized skill when the user task matches '
      'one of the names listed in `<available_skills>` in the system prompt.\n'
      '\n'
      'The system prompt exposes skill NAMES and one-line DESCRIPTIONS only. '
      'This tool is the only way to read a skill\'s full body — the procedure, '
      'examples, and references — into the current context.\n'
      '\n'
      'WHEN TO USE:\n'
      '  • The user explicitly asks you to load or apply a skill.\n'
      '  • The user\'s request matches the description of a skill in '
      '`<available_skills>` — the description is the trigger phrase.\n'
      '  • You are about to perform a multi-step task that the skill was '
      'written to guide you through (e.g. a code review, a security audit, '
      'a deploy).\n'
      '\n'
      'WHEN NOT TO USE:\n'
      '  • The user asks a general question with no skill match — just answer.\n'
      '  • You already loaded the skill in this conversation — the body is '
      'still in your context, no need to re-fetch.\n'
      '\n'
      'INPUT:\n'
      '  { name: string }   — the skill\'s name from `<available_skills>`. '
      'Must match exactly (case-sensitive).\n'
      '\n'
      'OUTPUT:\n'
      '  A `<skill_content name="…">` block containing the skill body, the '
      'absolute base directory, and a sampled list of sibling files. Use '
      '`read` on any of the listed files to load their full contents.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description':
            'The skill name, exactly as it appears in `<available_skills>` '
            'in the system prompt. Case-sensitive.',
      },
    },
    'required': ['name'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final name = args['name'];
    if (name is! String || name.isEmpty) {
      return ToolResult.error('Missing required parameter: name');
    }

    final skill = findSkillByName(name: name, cwd: ctx.workingDirectory);
    if (skill == null) {
      return ToolResult(
        title: 'skill: not found',
        output:
            'No skill named "$name" is available. Run `/skill list` to see '
            'the skills discovered in the current working directory and '
            'global skill roots.',
      );
    }

    final siblingFiles = _sampleSiblings(skill);
    final output = _renderSkillContent(skill, siblingFiles);

    // Mirror onto the runtime's loaded-skill set so the [ContextBar]
    // hover hint reflects "this skill is now active in the
    // conversation context". Failure paths (unknown name, missing
    // parameter) deliberately skip this — the LLM didn't actually
    // pull a body into context. Idempotent: re-loading an already
    // loaded skill is a no-op for the hint, and the same is true for
    // `Set.add`. The next chat-panel `_refresh()` (called from the
    // tool-round callback) picks up the mutation and the bar's
    // tooltip re-renders on the next mouse move / refresh.
    ctx.sessionRuntime?.loadedSkillNames.add(skill.name);

    return ToolResult(
      title: 'skill: ${skill.name}',
      output: output,
      metadata: {
        'skillName': skill.name,
        'location': skill.location,
        'baseDirectory': skill.baseDirectory,
        'siblings': siblingFiles,
      },
    );
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final name = (call.input['name'] as String?) ?? '';
    if (isError) return 'skill {$name} → $pairedResult';
    return 'skill {$name}';
  }

  // skill bodies are durable prompt content (the LLM should keep
  // them across compaction); surface them in the bottom-of-log
  // summary so a post-compact session can re-orient.
  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) {
    if (isError) return null;
    final name = (call.input['name'] as String?) ?? '';
    if (name.isEmpty) return null;
    return SummaryContribution(
      category: 'skill-bodies',
      key: name,
      value: pairedResult,
    );
  }
}

/// Sample up to [_maxSampledSiblings] regular files in the skill's
/// base directory, skipping `SKILL.md` itself. Sorted for
/// deterministic output.
List<String> _sampleSiblings(SkillInfo skill) {
  final dir = Directory(skill.baseDirectory);
  if (!dir.existsSync()) return const [];

  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return const [];
  }

  final files = <String>[];
  for (final entry in entries) {
    if (entry is! File) continue;
    final name = p.basename(entry.path);
    if (name == 'SKILL.md') continue;
    files.add(p.relative(entry.path, from: skill.baseDirectory));
  }
  files.sort();
  if (files.length > _maxSampledSiblings) {
    return files.sublist(0, _maxSampledSiblings);
  }
  return files;
}

/// Render the body in the opencode-compatible `<skill_content>` shape
/// so any LLM trained on opencode/openclaude skill transcripts
/// pattern-matches the structure. Built-in skills have no base
/// directory — the "base directory" lines are omitted for them.
String _renderSkillContent(SkillInfo skill, List<String> siblings) {
  final baseDir = skill.baseDirectory;
  final body = skill.content.trim();
  final isBuiltIn = baseDir == kBuiltInSkillLocation;

  final lines = <String>[
    '<skill_content name="${skill.name}">',
    '# Skill: ${skill.name}',
    '',
    body,
    '',
    if (!isBuiltIn) ...[
      'Base directory for this skill: $baseDir',
      'Relative paths in this skill (e.g., scripts/, reference/, assets/) '
          'are relative to this base directory.',
    ] else
      'This skill is built into Crux — it has no files on disk.',
    if (siblings.isNotEmpty) ...[
      '',
      '<skill_files>',
      for (final s in siblings) '<file>$s</file>',
      '</skill_files>',
    ],
    '</skill_content>',
  ];
  return lines.join('\n');
}

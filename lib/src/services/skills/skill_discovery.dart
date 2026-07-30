/// Skill discovery and frontmatter parsing.
///
/// Discovers `SKILL.md` files in the conventional project + global
/// locations, parses their YAML frontmatter with **strict**
/// validation (name must match folder, description required, name
/// must satisfy the open-standard regex), and returns the merged,
/// deduped list.
///
/// Discovery order (first match wins for any given skill name):
///
///     1. Project .crux/skills/<name>/SKILL.md   (walking cwd → worktree,
///                                                closer-to-cwd wins)
///     2. Project .crux/skill/<name>/SKILL.md    (singular alias, same walk)
///     3. Project .claude/skills/<name>/SKILL.md (cross-agent, committed, same walk)
///     4. Project .agents/skills/<name>/SKILL.md (open-standard, committed, same walk)
///     5. Global  ~/.claude/skills/<name>/SKILL.md   (cross-agent, portable)
///     6. Global  ~/.agents/skills/<name>/SKILL.md   (open-standard portable)
///     7. Global  ~/.local/share/crux/skills/<name>/SKILL.md   (crux-native)
///
/// Malformed skills (bad YAML, missing `name`/`description`, name
/// doesn't match the folder, etc.) are silently skipped — same
/// policy as `project_notes_discovery.dart` for unreadable
/// project notes. Crux does not fail a session over a misconfigured
/// skill.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'skill.dart';

// =============================================================================
// Frontmatter
// =============================================================================

/// Reason a SKILL.md was rejected during parsing. Each value
/// carries enough detail for a debug overlay; the user-facing
/// layer (system prompt) never surfaces these.
///
/// Subclasses are public so tests can pattern-match on the
/// concrete type (e.g. `expect(err, isA<InvalidName>())`). In
/// production code, consumers should treat the sealed base as
/// opaque — they only need the [message].
sealed class SkillParseError {
  const SkillParseError(this.message);
  final String message;
}

/// Generic catch-all for filesystem + unsupported errors that
/// don't fit one of the specific validation categories below.
class SkillParseFailure extends SkillParseError {
  const SkillParseFailure(super.message);
}

class MissingFrontmatterBlock extends SkillParseError {
  const MissingFrontmatterBlock() : super('SKILL.md must start with `---`.');
}

class YamlParseError extends SkillParseError {
  const YamlParseError(this.cause)
    : super('Frontmatter is not valid YAML: $cause');
  final String cause;
}

class FrontmatterNotObject extends SkillParseError {
  const FrontmatterNotObject()
    : super('Frontmatter must be a YAML mapping (key: value pairs).');
}

class MissingName extends SkillParseError {
  const MissingName() : super('Missing required field `name`.');
}

class InvalidName extends SkillParseError {
  const InvalidName(this.name)
    : super(
        'Field `name` must match `[a-z0-9][a-z0-9-]*` (lowercase '
        'letters, digits, hyphens; no leading hyphen). Got: $name.',
      );
  final String name;
}

class NameFolderMismatch extends SkillParseError {
  const NameFolderMismatch(this.frontmatterName, this.folderName)
    : super(
        'Frontmatter `name` ($frontmatterName) must match the '
        'folder name ($folderName).',
      );
  final String frontmatterName;
  final String folderName;
}

class MissingDescription extends SkillParseError {
  const MissingDescription() : super('Missing required field `description`.');
}

class EmptyDescription extends SkillParseError {
  const EmptyDescription() : super('Field `description` must be non-empty.');
}

class DescriptionTooLong extends SkillParseError {
  const DescriptionTooLong(this.length)
    : super(
        'Field `description` must be ≤ 1024 characters '
        '(got $length).',
      );
  final int length;
}

/// Strict, per-spec regex from
/// <https://agentskills.io/specification#name-field>:
///   1-64 chars, lowercase alnum + hyphens, no leading/trailing
///   hyphen, no consecutive hyphens. (We additionally require
/// `name` to match the folder name, enforced at the call site.)
///
/// Implemented as an explicit alternation rather than a clever
/// single regex: the alternative `a` matches 1 char, the
/// alternative `a(...)(?!--)[a-z0-9]` matches 2+ chars, and the
/// negative lookahead blocks the second-to-last position from
/// being a hyphen. Cleaner than fighting a single character class.
final _nameRe = RegExp(
  r'^[a-z0-9]$|^[a-z0-9](?:[a-z0-9-](?!--)){0,62}[a-z0-9]$',
);

const _maxDescriptionChars = 1024;

/// Split the file body into frontmatter and content. Returns
/// `(null, error)` if the file doesn't start with a `---` block.
///
/// Mirrors the `splitFrontmatter` step in
/// `openclaude-skills/packages/validator/src/frontmatter.ts`.
({String yaml, String body})? _splitFrontmatter(String content) {
  // Normalize line endings for the split only.
  final normalized = content.replaceAll('\r\n', '\n');
  if (!normalized.startsWith('---\n') && normalized != '---') return null;
  final after = normalized.substring(4);
  final endIdx = after.indexOf('\n---');
  if (endIdx == -1) return null;
  final yamlText = after.substring(0, endIdx);
  // Strip the closing `---` line and any leading blank lines so
  // the body starts with the first content character. Authors
  // conventionally leave one or two blank lines between the
  // frontmatter and the body; we don't want those to leak into
  // the rendered text.
  var body = after.substring(endIdx + 4);
  while (body.startsWith('\n')) {
    body = body.substring(1);
  }
  return (yaml: yamlText, body: body);
}

/// Parse a single SKILL.md file. Returns the validated
/// [SkillInfo] or an error explaining why it was rejected.
///
/// [location] is the absolute path to the file (used for error
/// messages and as `SkillInfo.location`).
/// [baseDirectory] is the parent folder (the skill's root).
/// [folderName] is `p.basename(baseDirectory)` — used to enforce
/// the strict name == folder invariant.
SkillParseResult parseSkillFile({
  required String location,
  required String baseDirectory,
  required String folderName,
}) {
  final file = File(location);
  if (!file.existsSync()) {
    return SkillParseResult.error(
      SkillParseFailure('SKILL.md does not exist: $location'),
    );
  }
  String content;
  try {
    content = file.readAsStringSync();
  } on FileSystemException catch (e) {
    return SkillParseResult.error(
      SkillParseFailure('Could not read SKILL.md: ${e.message}'),
    );
  }

  return parseSkillContent(
    content: content,
    location: location,
    baseDirectory: baseDirectory,
    folderName: folderName,
  );
}

/// Parse the body of a SKILL.md string. Split out from
/// [parseSkillFile] so tests can exercise the parser without
/// touching the filesystem.
SkillParseResult parseSkillContent({
  required String content,
  required String location,
  required String baseDirectory,
  required String folderName,
}) {
  final split = _splitFrontmatter(content);
  if (split == null) {
    return SkillParseResult.error(const MissingFrontmatterBlock());
  }

  final Object? raw;
  try {
    raw = loadYaml(split.yaml);
  } on YamlException catch (e) {
    return SkillParseResult.error(YamlParseError(e.message));
  } on FormatException catch (e) {
    return SkillParseResult.error(YamlParseError(e.message));
  }

  if (raw == null || raw is! Map) {
    return SkillParseResult.error(const FrontmatterNotObject());
  }
  final fm = raw;

  // name
  final name = fm['name'];
  if (name == null) {
    return SkillParseResult.error(const MissingName());
  }
  if (name is! String) {
    return SkillParseResult.error(
      InvalidName('<non-string: ${name.runtimeType}>'),
    );
  }
  if (!_nameRe.hasMatch(name)) {
    return SkillParseResult.error(InvalidName(name));
  }
  if (name != folderName) {
    return SkillParseResult.error(NameFolderMismatch(name, folderName));
  }

  // description
  final description = fm['description'];
  if (description == null) {
    return SkillParseResult.error(const MissingDescription());
  }
  if (description is! String) {
    return SkillParseResult.error(const MissingDescription());
  }
  if (description.isEmpty) {
    return SkillParseResult.error(const EmptyDescription());
  }
  if (description.length > _maxDescriptionChars) {
    return SkillParseResult.error(DescriptionTooLong(description.length));
  }

  return SkillParseResult.ok(
    SkillInfo(
      name: name,
      description: description,
      location: location,
      baseDirectory: baseDirectory,
      content: split.body,
    ),
  );
}

/// Result of parsing one SKILL.md. Either [info] is non-null (parse
/// succeeded) or [error] is non-null (parse failed). Returned by
/// [parseSkillFile] / [parseSkillContent] for use by tests and the
/// `/skill validate` command in v2.
class SkillParseResult {
  final SkillInfo? info;
  final SkillParseError? error;

  const SkillParseResult._({this.info, this.error});

  factory SkillParseResult.ok(SkillInfo info) => SkillParseResult._(info: info);

  factory SkillParseResult.error(SkillParseError error) =>
      SkillParseResult._(error: error);

  bool get isOk => info != null;
}

// =============================================================================
// Discovery
// =============================================================================

/// Project-local skills roots, in priority order. The crux-native
/// spellings come first (plural matches the open standard and
/// opencode; the singular is kept as an alias for users who
/// happened to spell it that way), then the portable / cross-agent
/// conventions that projects commit alongside their code
/// (`.claude/skills`, `.agents/skills`) — the same folders scanned
/// globally under `$HOME`, but resolved relative to each level of
/// the project walk so a repo can ship its own skills.
const _projectSkillsDirNames = [
  '.crux/skills',
  '.crux/skill',
  '.claude/skills',
  '.agents/skills',
];

/// Global skills roots, in priority order. Portable / cross-agent
/// locations come first (largest existing user base, most likely
/// to be the "official" version of a skill), then the
/// crux-specific user-data-dir location.
///
/// [home] and [userDataDir] let callers (notably tests) override
/// the values that would normally be derived from the process
/// environment. `Platform.environment` is unmodifiable in Dart,
/// so we can't mutate it from inside `discoverSkills` — the
/// override path passes the alternative values through here.
List<String> _globalSkillsRoots({String? home, String? userDataDir}) {
  final h = home ?? _homeDir();
  final d = userDataDir ?? _resolveCruxUserDataDir(home: h);
  return <String>[
    p.join(h, '.claude', 'skills'),
    p.join(h, '.agents', 'skills'),
    p.join(d, 'skills'),
  ];
}

String _homeDir() {
  // `Platform.environment['HOME']` is read-only, so test
  // overrides must be passed explicitly via [discoverSkills].
  // On Windows the user-data resolver already does its own
  // thing; for the global dirs here we use whatever `HOME` /
  // `USERPROFILE` says, since `.claude/` and `.agents/` are
  // XDG-style cross-platform.
  return Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
}

String _resolveCruxUserDataDir({String? home}) {
  // Deliberately local copy to avoid an import cycle with
  // `lib/src/utils/user_data_directory.dart`. The env lookup is
  // bypassed when [home] is provided so the test path can
  // exercise XDG resolution deterministically.
  final xdg = Platform.environment['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'crux');
  final h = home ?? _homeDir();
  if (h.isNotEmpty) return p.join(h, '.local', 'share', 'crux');
  return p.join(Directory.systemTemp.path, 'crux');
}

/// Discover every skill reachable from [cwd].
///
/// Walks the directory tree from [cwd] upward, stopping at the
/// git root (`.git` directory) when present, otherwise at the
/// filesystem root. At each level it checks the project skill
/// roots (`.crux/skills`, `.crux/skill`, `.claude/skills`,
/// `.agents/skills`). After the project walk, it always scans
/// the three global roots.
///
/// Returned order: project skills first (closer-to-cwd first),
/// then global skills (in the global order above). Skill names
/// are deduped by the first match — the same name appearing in a
/// higher-priority location shadows the lower-priority copy.
///
/// [homeOverride], [userDataDirOverride], and [projectSkillsDirNamesOverride]
/// exist purely to make the discovery logic testable without
/// touching the real `~/.claude` or `~/.local/share/crux` dirs.
List<SkillInfo> discoverSkills({
  required String cwd,
  String? homeOverride,
  String? userDataDirOverride,
  List<String>? projectSkillsDirNamesOverride,
}) {
  final seen = <String>{};
  final result = <SkillInfo>[];

  // --- 1. Project walk: cwd → worktree ---
  final projectDirs = projectSkillsDirNamesOverride ?? _projectSkillsDirNames;
  for (final dir in _walkUpFromCwd(cwd)) {
    for (final sub in projectDirs) {
      _absorbSkillsFromRoot(p.join(dir, sub), seen, result);
    }
  }

  // --- 2. Global roots (always-scanned, fixed order) ---
  final globalRoots = _globalSkillsRoots(
    home: homeOverride,
    userDataDir: userDataDirOverride,
  );
  for (final root in globalRoots) {
    _absorbSkillsFromRoot(root, seen, result);
  }

  return result;
}

/// Walk from [cwd] up to (and including) the git root when one
/// exists, otherwise up to the filesystem root. Closer-to-cwd
/// first.
List<String> _walkUpFromCwd(String cwd) {
  final result = <String>[];
  String? current = _tryCanonicalize(cwd);
  while (current != null) {
    result.add(current);
    final parent = p.dirname(current);
    if (parent == current) break; // filesystem root
    if (_isGitRoot(current)) break; // stop at the project boundary
    current = parent;
  }
  return result;
}

String? _tryCanonicalize(String path) {
  try {
    return p.canonicalize(path);
  } on FileSystemException {
    return null;
  }
}

bool _isGitRoot(String dir) {
  final gitPath = p.join(dir, '.git');
  return Directory(gitPath).existsSync() || File(gitPath).existsSync();
}

/// For each subdirectory of [root] that contains a `SKILL.md`,
/// parse the file and add it to [result] (deduped by name in
/// [seen]). Silently skips malformed skills.
void _absorbSkillsFromRoot(
  String root,
  Set<String> seen,
  List<SkillInfo> result,
) {
  final dir = Directory(root);
  if (!dir.existsSync()) return;

  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }

  // Stable order — sort so a run with the same skills gives the
  // same result regardless of the FS's directory iteration order.
  entries.sort((a, b) => a.path.compareTo(b.path));

  for (final entry in entries) {
    if (entry is! Directory) continue;
    final folderName = p.basename(entry.path);
    final skillPath = p.join(entry.path, 'SKILL.md');
    final parseResult = parseSkillFile(
      location: skillPath,
      baseDirectory: entry.path,
      folderName: folderName,
    );
    final info = parseResult.info;
    if (info == null) continue; // malformed — skip silently
    if (seen.contains(info.name)) continue; // shadowed
    seen.add(info.name);
    result.add(info);
  }
}

/// Look up a single skill by name. Returns `null` if not found.
/// Convenience wrapper around [discoverSkills] for the `skill`
/// tool and the `/skill show <name>` command.
SkillInfo? findSkillByName({
  required String name,
  required String cwd,
  String? homeOverride,
  String? userDataDirOverride,
}) {
  final all = discoverSkills(
    cwd: cwd,
    homeOverride: homeOverride,
    userDataDirOverride: userDataDirOverride,
  );
  for (final s in all) {
    if (s.name == name) return s;
  }
  return null;
}

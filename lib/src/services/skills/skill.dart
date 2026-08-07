/// A discovered skill, ready to be rendered into the system prompt
/// (name + description) or loaded by the `skill` tool (full body).
///
/// [name] is the skill's canonical identifier — also the folder
/// name under the skills root, and the key the LLM uses when
/// calling the `skill` tool. Must match the open standard's
/// `[a-z0-9][a-z0-9-]*` regex (strictly enforced in
/// [parseSkillFrontmatter]).
///
/// [description] is a short, agent-facing summary of *what* the
/// skill does and *when* to use it. Surfaces in the `<available_skills>`
/// block of the system prompt; the LLM pattern-matches it to decide
/// whether to call the `skill` tool.
///
/// [location] is the absolute path to the `SKILL.md` file on disk,
/// or the sentinel `(built-in)` for file-less built-in skills (see
/// `built_in_skills.dart`). [baseDirectory] is the parent folder (the
/// skill's root); for built-ins it is the same sentinel. Sibling
/// files in this folder (e.g. `references/`, `scripts/`) are exposed
/// to the LLM by the `skill` tool — built-ins have none.
///
/// [content] is the full file body, frontmatter stripped.
class SkillInfo {
  final String name;
  final String description;
  final String location;
  final String baseDirectory;
  final String content;

  const SkillInfo({
    required this.name,
    required this.description,
    required this.location,
    required this.baseDirectory,
    required this.content,
  });
}

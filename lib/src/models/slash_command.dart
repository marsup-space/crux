class CommandSuggestion {
  final String value;
  final String? description;

  const CommandSuggestion({required this.value, this.description});
}

class SlashCommand {
  final String name;
  final String description;
  final List<String> params;
  final List<List<CommandSuggestion>> suggestionsPerParam;
  final bool availableDuringResponse;

  /// Alternative names that dispatch to the same command. Aliases are
  /// accepted by the command executor (e.g. `/继续` → `/continue`) and
  /// are also matched by the suggestion overlay so users can discover
  /// the primary command by typing its alias. The primary [name] is
  /// always shown in the overlay and is the canonical form used by
  /// tests and persisted logs.
  final List<String> aliases;

  const SlashCommand({
    required this.name,
    required this.description,
    this.params = const [],
    this.suggestionsPerParam = const [],
    this.availableDuringResponse = false,
    this.aliases = const [],
  });

  /// All names that can be used to invoke this command — the primary
  /// [name] plus any [aliases]. Exposed so the executor can decide
  /// whether an incoming input matches a known invocation without
  /// walking the registry again.
  Iterable<String> get allNames sync* {
    yield name;
    yield* aliases;
  }

  /// Returns the full command string with parameter placeholders.
  String get displayName =>
      params.isEmpty ? name : '$name ${params.map((p) => '<$p>').join(' ')}';

  /// Whether this command has parameter suggestions for the given param index.
  bool hasSuggestionsForParam(int index) =>
      index < suggestionsPerParam.length &&
      suggestionsPerParam[index].isNotEmpty;
}

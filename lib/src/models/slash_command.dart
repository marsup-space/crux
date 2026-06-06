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

  const SlashCommand({
    required this.name,
    required this.description,
    this.params = const [],
    this.suggestionsPerParam = const [],
    this.availableDuringResponse = false,
  });

  /// Returns the full command string with parameter placeholders.
  String get displayName =>
      params.isEmpty ? name : '$name ${params.map((p) => '<$p>').join(' ')}';

  /// Whether this command has parameter suggestions for the given param index.
  bool hasSuggestionsForParam(int index) =>
      index < suggestionsPerParam.length &&
      suggestionsPerParam[index].isNotEmpty;
}

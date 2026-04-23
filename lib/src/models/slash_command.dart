class SlashCommand {
  final String name;
  final String description;
  final List<String> params;

  const SlashCommand({
    required this.name,
    required this.description,
    this.params = const [],
  });

  /// Returns the full command string with parameter placeholders.
  String get displayName => params.isEmpty
      ? name
      : '$name ${params.map((p) => '<$p>').join(' ')}';

  /// Checks if this command's name starts with the given prefix.
  bool matches(String prefix) => name.startsWith(prefix);
}

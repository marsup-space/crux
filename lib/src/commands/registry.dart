import '../models/slash_command.dart';

/// Registry of all available slash commands.
const List<SlashCommand> slashCommands = [
  SlashCommand(
    name: '/model',
    description: 'Switch the AI model',
    params: ['name'],
    suggestionsPerParam: [
      [],
    ],
  ),
  SlashCommand(
    name: '/new',
    description: 'Create a new session',
  ),
  SlashCommand(
    name: '/session',
    description: 'Switch to a session',
    params: ['id'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: '#1', description: 'Build a TUI chat app'),
        CommandSuggestion(value: '#2', description: 'Debug rendering pipeline'),
        CommandSuggestion(value: '#3', description: 'Add markdown support'),
        CommandSuggestion(value: '#4', description: 'Refactor command registry'),
      ],
    ],
  ),
  SlashCommand(
    name: '/clear',
    description: 'Clear the chat log',
  ),
  SlashCommand(
    name: '/compact',
    description: 'Compact the context window',
  ),
  SlashCommand(
    name: '/help',
    description: 'Show help information',
    params: ['topic'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'commands', description: 'Show available commands'),
        CommandSuggestion(value: 'models', description: 'Show model information'),
        CommandSuggestion(value: 'shortcuts', description: 'Show keyboard shortcuts'),
      ],
    ],
  ),
  SlashCommand(
    name: '/config',
    description: 'View or edit configuration',
    params: ['key', 'value'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'model', description: 'Default model configuration'),
        CommandSuggestion(value: 'theme', description: 'UI theme settings'),
        CommandSuggestion(value: 'api', description: 'API endpoint settings'),
        CommandSuggestion(value: 'output', description: 'Output format settings'),
      ],
      [
        CommandSuggestion(value: 'default', description: 'Reset to default value'),
      ],
    ],
  ),
  SlashCommand(
    name: '/theme',
    description: 'Change the UI theme',
    params: ['name'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'dark', description: 'Dark color scheme'),
        CommandSuggestion(value: 'light', description: 'Light color scheme'),
        CommandSuggestion(value: 'monokai', description: 'Monokai-inspired theme'),
        CommandSuggestion(value: 'dracula', description: 'Dracula theme'),
      ],
    ],
  ),
  SlashCommand(
    name: '/quit',
    description: 'Exit the application',
  ),
  SlashCommand(
    name: '/history',
    description: 'Show conversation history',
    params: ['limit'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: '10', description: 'Last 10 messages'),
        CommandSuggestion(value: '20', description: 'Last 20 messages'),
        CommandSuggestion(value: '50', description: 'Last 50 messages'),
        CommandSuggestion(value: 'all', description: 'Show all messages'),
      ],
    ],
  ),
  SlashCommand(
    name: '/provider',
    description: 'Connect a built-in provider or manage custom providers',
    params: ['name'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'deepseek', description: 'DeepSeek (V4 Flash / V4 Pro)'),
        CommandSuggestion(value: 'infinigence', description: 'Infinigence (coming soon)'),
        CommandSuggestion(value: 'volcengine', description: 'Volcengine (coming soon)'),
        CommandSuggestion(value: 'custom', description: 'Add, modify, or remove a custom provider'),
      ],
    ],
  ),
];

/// Returns commands whose name starts with the given prefix.
List<SlashCommand> filterCommands(String prefix) {
  if (prefix.isEmpty) return slashCommands;
  return slashCommands.where((cmd) => cmd.name.startsWith(prefix)).toList();
}

/// Returns the SlashCommand matching the exact given name, or null if not found.
SlashCommand? findCommand(String name) {
  for (final cmd in slashCommands) {
    if (cmd.name == name) return cmd;
  }
  return null;
}

/// Filters suggestions by a prefix string.
List<CommandSuggestion> filterSuggestions(
  List<CommandSuggestion> suggestions,
  String prefix,
) {
  if (prefix.isEmpty) return suggestions;
  return suggestions.where((s) => s.value.startsWith(prefix)).toList();
}

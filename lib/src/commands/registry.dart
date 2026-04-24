import '../models/slash_command.dart';

/// Registry of all available slash commands.
const List<SlashCommand> slashCommands = [
  SlashCommand(
    name: '/model',
    description: 'Switch the AI model',
    params: ['name'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'openai/gpt-4o', description: 'Latest multimodal GPT model'),
        CommandSuggestion(value: 'openai/gpt-4', description: 'Most capable GPT model'),
        CommandSuggestion(value: 'openai/gpt-3.5-turbo', description: 'Fast and affordable'),
        CommandSuggestion(value: 'anthropic/claude-3.5', description: 'Latest Claude model'),
        CommandSuggestion(value: 'anthropic/claude-3', description: 'Balanced performance'),
        CommandSuggestion(value: 'google/gemini-pro', description: 'Google Pro model'),
        CommandSuggestion(value: 'google/gemini-flash', description: 'Fast Gemini model'),
        CommandSuggestion(value: 'local/llama3', description: 'Local Llama 3 model'),
        CommandSuggestion(value: 'local/mistral', description: 'Local Mistral model'),
      ],
    ],
  ),
  SlashCommand(
    name: '/session',
    description: 'Manage sessions',
    params: ['action'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'new', description: 'Start a new session'),
        CommandSuggestion(value: 'list', description: 'List all sessions'),
        CommandSuggestion(value: 'resume', description: 'Resume a previous session'),
        CommandSuggestion(value: 'delete', description: 'Delete a session'),
      ],
    ],
  ),
  SlashCommand(
    name: '/clear',
    description: 'Clear the chat log',
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

import '../models/slash_command.dart';

/// Registry of all available slash commands.
const List<SlashCommand> slashCommands = [
  SlashCommand(
    name: '/model',
    description: 'Switch the AI model',
    params: ['name'],
  ),
  SlashCommand(
    name: '/session',
    description: 'Manage sessions (new, list, resume)',
    params: ['action'],
  ),
  SlashCommand(
    name: '/clear',
    description: 'Clear the chat log',
  ),
  SlashCommand(
    name: '/help',
    description: 'Show help information',
    params: ['topic'],
  ),
  SlashCommand(
    name: '/config',
    description: 'View or edit configuration',
    params: ['key', 'value'],
  ),
  SlashCommand(
    name: '/theme',
    description: 'Change the UI theme',
    params: ['name'],
  ),
  SlashCommand(
    name: '/quit',
    description: 'Exit the application',
  ),
  SlashCommand(
    name: '/history',
    description: 'Show conversation history',
    params: ['limit'],
  ),
];

/// Returns commands whose name starts with the given prefix.
List<SlashCommand> filterCommands(String prefix) {
  if (prefix.isEmpty) return slashCommands;
  return slashCommands.where((cmd) => cmd.name.startsWith(prefix)).toList();
}

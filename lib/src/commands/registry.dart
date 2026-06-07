import 'package:nocterm/nocterm.dart';
import '../models/slash_command.dart';

/// Mutable registry of all available slash commands.
///
/// The base list is always present. Debug commands are dynamically
/// registered or unregistered by the `/debug` command.
class CommandRegistry extends ChangeNotifier {
  CommandRegistry._() {
    _base.addAll(_baseCommands);
  }

  static final CommandRegistry instance = CommandRegistry._();

  final List<SlashCommand> _base = [];
  final List<SlashCommand> _debug = [];
  bool _debugEnabled = false;

  /// Whether debug commands are currently registered.
  bool get debugEnabled => _debugEnabled;

  /// All currently registered commands (base + debug if enabled).
  List<SlashCommand> get all => _debugEnabled
      ? <SlashCommand>[..._base, ..._debug]
      : List<SlashCommand>.unmodifiable(_base);

  /// Backwards-compatible view of the currently registered commands.
  List<SlashCommand> get slashCommands => all;

  /// Enable debug mode and register the debug command set.
  void enableDebug() {
    if (_debugEnabled) return;
    _debug
      ..clear()
      ..addAll(_debugCommands);
    _debugEnabled = true;
    notifyListeners();
  }

  /// Disable debug mode and unregister the debug command set.
  void disableDebug() {
    if (!_debugEnabled) return;
    _debugEnabled = false;
    notifyListeners();
  }

  /// Toggle debug mode. Returns the new state (true = enabled).
  bool toggleDebug() {
    if (_debugEnabled) {
      disableDebug();
    } else {
      enableDebug();
    }
    return _debugEnabled;
  }

  /// Returns commands whose name starts with the given prefix.
  List<SlashCommand> filterCommands(String prefix) {
    final list = all;
    if (prefix.isEmpty) return list;
    return list.where((cmd) => cmd.name.startsWith(prefix)).toList();
  }

  /// Returns the SlashCommand matching the exact given name, or null if not found.
  SlashCommand? findCommand(String name) {
    for (final cmd in all) {
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
}

// Re-export the singleton helpers so call sites can use them as before.
List<SlashCommand> get slashCommands => CommandRegistry.instance.all;
List<SlashCommand> filterCommands(String prefix) =>
    CommandRegistry.instance.filterCommands(prefix);
SlashCommand? findCommand(String name) =>
    CommandRegistry.instance.findCommand(name);
List<CommandSuggestion> filterSuggestions(
  List<CommandSuggestion> suggestions,
  String prefix,
) =>
    CommandRegistry.instance.filterSuggestions(suggestions, prefix);

/// Base command set — always present.
const List<SlashCommand> _baseCommands = [
  SlashCommand(
    name: '/model',
    description: 'Switch the AI model',
    params: ['provider/model'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/new',
    description: 'Create a new session',
    availableDuringResponse: true,
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
        CommandSuggestion(
          value: '#4',
          description: 'Refactor command registry',
        ),
      ],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(name: '/clear', description: 'Clear the chat log'),
  SlashCommand(name: '/compact', description: 'Compact the context window'),
  SlashCommand(
    name: '/help',
    description: 'Show help information',
    params: ['topic'],
    suggestionsPerParam: [
      [
        CommandSuggestion(
          value: 'commands',
          description: 'Show available commands',
        ),
        CommandSuggestion(
          value: 'models',
          description: 'Show model information',
        ),
        CommandSuggestion(
          value: 'shortcuts',
          description: 'Show keyboard shortcuts',
        ),
      ],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/theme',
    description: 'Change the UI theme',
    params: ['name'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'dark', description: 'Dark color scheme'),
        CommandSuggestion(value: 'light', description: 'Light color scheme'),
        CommandSuggestion(
          value: 'monokai',
          description: 'Monokai-inspired theme',
        ),
        CommandSuggestion(value: 'dracula', description: 'Dracula theme'),
      ],
    ],
    availableDuringResponse: true,
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
    description: 'Connect a provider by entering your API key',
    params: ['name'],
    suggestionsPerParam: [
      [],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/think',
    description: 'Toggle thinking mode (off/normal/high/max)',
    params: ['effort'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'off', description: 'Disable thinking mode'),
        CommandSuggestion(
          value: 'normal',
          description: 'Normal reasoning effort (default)',
        ),
        CommandSuggestion(value: 'high', description: 'High reasoning effort'),
        CommandSuggestion(
          value: 'max',
          description: 'Maximum reasoning effort',
        ),
      ],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/auxiliary',
    description: 'Select the auxiliary model (for summaries, session names)',
    params: ['auxiliary model'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/tldr',
    description: 'Generate TLDR for the last AI response',
    params: ['level'],
    suggestionsPerParam: [
      [
        CommandSuggestion(
          value: 'concise',
          description: 'Fewer bullets, focus on the core message',
        ),
        CommandSuggestion(
          value: 'default',
          description: 'Balanced summary (default if no level is given)',
        ),
        CommandSuggestion(
          value: 'detailed',
          description: 'Thorough summary covering every section',
        ),
      ],
    ],
  ),
  SlashCommand(
    name: '/project',
    description: 'Switch to a different project directory',
    params: ['path'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/debug',
    description: 'Toggle debug commands on/off',
    availableDuringResponse: true,
  ),
];

/// Debug command set — only registered when debug mode is on.
const List<SlashCommand> _debugCommands = [
  SlashCommand(
    name: '/d-state',
    description: '[debug] Dump current session state',
  ),
  SlashCommand(
    name: '/d-messages',
    description: '[debug] Dump all messages in current session',
  ),
  SlashCommand(
    name: '/d-context',
    description: '[debug] Dump context window info and token estimates',
  ),
  SlashCommand(
    name: '/d-runtime',
    description: '[debug] Dump runtime state (TTFT, tok/s, etc.)',
  ),
  SlashCommand(
    name: '/d-providers',
    description: '[debug] List all loaded providers and models',
  ),
  SlashCommand(
    name: '/d-tools',
    description: '[debug] List all registered tools',
  ),
  SlashCommand(
    name: '/d-paths',
    description: '[debug] Print relevant file paths (DB, providers, project)',
  ),
  SlashCommand(
    name: '/d-env',
    description: '[debug] Print environment info (Dart version, platform)',
  ),
  SlashCommand(
    name: '/d-toast',
    description:
        '[debug] Display a toast — mode (info/error/status) is auto-detected from the message',
    params: ['message'],
    availableDuringResponse: true,
  ),
];

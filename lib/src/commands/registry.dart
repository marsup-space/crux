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

  /// Returns commands whose name (or any alias) starts with the given
  /// prefix. The primary [SlashCommand.name] is always what shows up
  /// in the suggestion list — the alias is only used as a way to
  /// discover the command (e.g. typing `/继续` reveals `/continue`).
  List<SlashCommand> filterCommands(String prefix) {
    final list = all;
    if (prefix.isEmpty) return list;
    return list
        .where(
          (cmd) => cmd.allNames.any((n) => n.startsWith(prefix)),
        )
        .toList();
  }

  /// Returns the SlashCommand matching the exact given name, or any
  /// of its aliases, or null if not found. When the lookup hits an
  /// alias, the same [SlashCommand] instance is returned (i.e. the
  /// caller does not need to care which name the user typed).
  SlashCommand? findCommand(String name) {
    for (final cmd in all) {
      for (final n in cmd.allNames) {
        if (n == name) return cmd;
      }
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
  // Resubmit the current context so the LLM continues generating.
  // The Chinese alias `/继续` is the natural form for Chinese-speaking
  // users; the English name is the canonical one shown in the
  // suggestion overlay. `availableDuringResponse: false` because
  // running it mid-stream would race with the active chat service
  // call.
  //
  // The executor is smart about what to send back: if the last
  // segment in the history is a `tool` result (or a `user` turn
  // that the API accepts as a trailing turn), it round-trips the
  // history verbatim — no synthetic user nudge — so an interrupted
  // tool flow picks up cleanly. Only when the last segment is `ai`
  // (round finished) does it append a small "请继续" user turn to
  // satisfy the LLM APIs' role-alternation rule.
  SlashCommand(
    name: '/continue',
    description: '继续生成 (resubmit context so the LLM keeps generating)',
    aliases: ['/继续'],
  ),
  // Re-send the last user input, discarding whatever the previous
  // round produced (the AI response, any tool calls, etc.). Best used
  // after a turn has properly finished but the answer was
  // unsatisfactory; also useful for recovering from an interrupted
  // generation. Alias `/重试` matches the semantics of a typical
  // "retry last request" affordance in chat UIs.
  SlashCommand(
    name: '/retry',
    description: '重试 (re-send the last user input from scratch)',
    aliases: ['/重试'],
  ),
  // Ephemeral side-question: ask the model a quick question without
  // polluting the real conversation. The AI's reply is rendered in a
  // boxed, dim bubble and lives only in memory. Consecutive `/btw`
  // calls chain (each one sees the prior btw turns as context). The
  // whole chain evaporates the moment the user sends a non-`/btw`
  // message or switches sessions — nothing is ever persisted.
  // `availableDuringResponse: false` so it never races with the
  // main model's in-flight stream.
  SlashCommand(
    name: '/btw',
    description:
        'Ephemeral side-question — not saved, discarded on next real turn',
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

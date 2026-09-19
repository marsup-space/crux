import 'package:nocterm/nocterm.dart';

import '../models/slash_command.dart';
import '../utils/fuzzy_match.dart';

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

  /// Returns commands whose name (or any alias) fuzzy-matches the
  /// given [query], ordered by match quality (best match first).
  ///
  /// Matching is case-insensitive and accepts several flavors of
  /// "fuzzy" beyond plain prefix: substring, subsequence, and
  /// acronym-style initials. The strongest match wins, so typing
  /// `/con` still ranks `/continue` first (prefix tier), but typing
  /// `/cnt` (a missing-letter typo) or `/cunt` still finds
  /// `/continue` via the subsequence tier.
  ///
  /// The primary [SlashCommand.name] is always what shows up in
  /// the suggestion list — aliases are only used as a way to
  /// discover the command (e.g. typing `/继续` reveals
  /// `/continue`).
  ///
  /// An empty or whitespace-only [query] returns every registered
  /// command in registry order, so the overlay shows the full
  /// catalog before the user has typed anything.
  List<SlashCommand> filterCommands(String query) {
    final list = all;
    return fuzzyRankMulti<SlashCommand>(list, (cmd) => cmd.allNames, query);
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

  /// Filters suggestions by fuzzy-matching their [CommandSuggestion.value]
  /// against [query], ordered by match quality (best match first).
  ///
  /// The match uses the same tiered scoring as [filterCommands]:
  /// exact, prefix, substring, initials prefix, initials
  /// subsequence, subsequence. An empty [query] returns the input
  /// list unchanged so the overlay shows every suggestion before
  /// the user has typed anything.
  List<CommandSuggestion> filterSuggestions(
    List<CommandSuggestion> suggestions,
    String query,
  ) {
    return fuzzyRank<CommandSuggestion>(suggestions, (s) => s.value, query);
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
) => CommandRegistry.instance.filterSuggestions(suggestions, prefix);

/// Base command set — always present.
const List<SlashCommand> _baseCommands = [
  SlashCommand(
    name: '/model',
    description: 'cmd.model.desc',
    params: ['provider/model'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/new',
    description: 'cmd.new.desc',
    availableDuringResponse: true,
  ),
  // Chat mode: a workspace-free conversation. The session gets the
  // minimal system prompt (no AGENTS.md / CLAUDE.md project notes,
  // no skills), is not tied to the current project directory, and
  // lands in the global "Chats" section (visible in every Crux
  // instance) instead of the project "Sessions" list. The running
  // lease keeps one chat from being open in two instances at once.
  SlashCommand(
    name: '/chat',
    description: 'cmd.chat.desc',
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/session',
    description: 'cmd.session.desc',
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
  SlashCommand(name: '/compact', description: 'cmd.compact.desc'),
  // Print the help sheet into the chat history as a local info
  // message. The sheet is generated from this registry at call time
  // (see cmd_help.dart), so `/help` can never drift from what Tab
  // completion actually offers. No params — the previous entry
  // promised `commands|models|shortcuts` topics that were never
  // implemented.
  SlashCommand(
    name: '/help',
    description: 'cmd.help.desc',
    availableDuringResponse: true,
  ),
  // Open the home-screen dashboard overlay. Available mid-stream
  // because it only flips an overlay flag — the chat body keeps
  // rendering live underneath; session-mutating *actions* inside
  // home are separately guarded at the HomeContext.runCommand seam.
  SlashCommand(
    name: '/home',
    description: 'cmd.home.desc',
    availableDuringResponse: true,
  ),
  // Replace the installed binary with the latest release. Deliberately
  // NOT available during a response: swapping the executable mid-turn is
  // technically safe (the running process keeps its inode) but leaves the
  // user unsure which version is answering them.
  SlashCommand(
    name: '/upgrade',
    description: 'cmd.upgrade.desc',
    aliases: ['/升级'],
  ),
  SlashCommand(
    name: '/setup',
    description: 'cmd.setup.desc',
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/theme',
    description: 'cmd.theme.desc',
    params: ['name'],
    availableDuringResponse: true,
  ),
  // Switch the UI language. `availableDuringResponse: true` because it
  // only flips the catalog + persists a key — it never touches the
  // in-flight stream, and the chat body re-renders on the next frame.
  SlashCommand(
    name: '/language',
    description: 'cmd.language.desc',
    params: ['code'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'en', description: 'English'),
        CommandSuggestion(value: 'zh', description: '中文'),
      ],
    ],
    availableDuringResponse: true,
  ),
  // Switch the agent's reply-language policy: `follow` (reply in the
  // configured UI language) or `auto` (match the user's input
  // language). Only flips a key + rebuilds the cached system prompt;
  // it never touches the in-flight stream, so it's available mid-turn.
  SlashCommand(
    name: '/reply-language',
    description: 'cmd.replyLanguage.desc',
    params: ['mode'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'follow', description: 'replylang.follow'),
        CommandSuggestion(value: 'auto', description: 'replylang.auto'),
      ],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/provider',
    description: 'cmd.provider.desc',
    params: ['name', 'key|remove|sync?'],
    suggestionsPerParam: [
      // First param: name (autocompleted from registered providers
      // in the chat panel — see chat_panel.dart's suggestion handler).
      [],
    ],
    availableDuringResponse: true,
  ),
  // Configure web-search / web-fetch providers. Provider-agnostic on
  // purpose: every provider exposes the same `<provider> key …`
  // sub-form, so adding Exa / Firecrawl / etc. needs no command
  // change — just register another [WebServiceProvider]. Today only
  // TinyFish is wired up; the registered provider ids come from
  // [WebServiceProvider.id] (see `services/providers/`).
  SlashCommand(
    name: '/web-provider',
    description: 'cmd.webProvider.desc',
    params: ['<name>', '<value>|key <value>|remove'],
    suggestionsPerParam: [
      // First positional arg: provider id, autocompleted from
      // registered providers in the chat panel.
      [],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/think',
    description: 'cmd.think.desc',
    params: ['effort'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'off', description: 'sug.think.off'),
        CommandSuggestion(value: 'low', description: 'sug.think.low'),
        CommandSuggestion(value: 'normal', description: 'sug.think.normal'),
        CommandSuggestion(value: 'adaptive', description: 'sug.think.adaptive'),
        CommandSuggestion(value: 'high', description: 'sug.think.high'),
        CommandSuggestion(value: 'max', description: 'sug.think.max'),
      ],
    ],
    availableDuringResponse: true,
  ),
  // Toggle the chat log display mode between verbose (per-call
  // detail) and vibe (aggregated metadata boxes). Pure viewer-mode
  // setting — never touches the in-flight stream. `/view` with no
  // arg reports the current mode.
  SlashCommand(
    name: '/view',
    description: 'cmd.view.desc',
    params: ['mode'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'verbose', description: 'sug.view.verbose'),
        CommandSuggestion(value: 'vibe', description: 'sug.view.vibe'),
      ],
    ],
    availableDuringResponse: true,
  ),
  // Enter or leave plan mode: split the chat surface into a plan doc
  // pane (left) and the vibe view (right). `/plan` with no argument
  // opens `<projectPath>/PLAN.md`; while active it exits (toggle).
  // Available during a response because it only flips pane state — the
  // plan-mode guards take effect on the *next* tool call.
  SlashCommand(
    name: '/plan',
    description: 'cmd.plan.desc',
    params: ['name?'],
    availableDuringResponse: true,
  ),
  // Toggle the two independent subagent-mode switches. Available
  // mid-response: flipping a switch changes nothing about the
  // in-flight turn — the first-message announcement rides the next
  // user message regardless.
  SlashCommand(
    name: '/subagent',
    description: 'cmd.subagent.desc',
    params: ['role', 'state'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'workers', description: 'sug.subagent.workers'),
        CommandSuggestion(value: 'experts', description: 'sug.subagent.experts'),
      ],
      [
        CommandSuggestion(value: 'on', description: 'sug.subagent.on'),
        CommandSuggestion(value: 'off', description: 'sug.subagent.off'),
      ],
    ],
    availableDuringResponse: true,
  ),
  // Override the LLM sampling temperature for the rest of the
  // session. Input is clamped to [0.0, 1.0] regardless of what is
  // typed — the underlying APIs accept up to 2.0, but Crux
  // intentionally narrows the user-facing range to the well-trodden
  // 0–1 "deterministic ↔ creative" axis. The override wins over
  // the model's TOML-configured `temperature` default at API-call
  // time and persists in the session row, so it outlives an app
  // restart. `availableDuringResponse: true` because changing the
  // sampling temperature doesn't touch the in-flight stream — the
  // new value only takes effect on the *next* turn anyway.
  SlashCommand(
    name: '/temperature',
    description: 'cmd.temperature.desc',
    params: ['value'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: '0.0', description: 'sug.temp.0.0'),
        CommandSuggestion(value: '0.3', description: 'sug.temp.0.3'),
        CommandSuggestion(value: '0.7', description: 'sug.temp.0.7'),
        CommandSuggestion(value: '1.0', description: 'sug.temp.1.0'),
      ],
    ],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/auxiliary',
    description: 'cmd.auxiliary.desc',
    params: ['auxiliary model'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/tldr',
    description: 'cmd.tldr.desc',
    params: ['level'],
    suggestionsPerParam: [
      [
        CommandSuggestion(value: 'concise', description: 'sug.tldr.concise'),
        CommandSuggestion(value: 'default', description: 'sug.tldr.default'),
        CommandSuggestion(value: 'detailed', description: 'sug.tldr.detailed'),
      ],
    ],
  ),
  SlashCommand(
    name: '/project',
    description: 'cmd.project.desc',
    params: ['path'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/debug',
    description: 'cmd.debug.desc',
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
    description: 'cmd.continue.desc',
    aliases: ['/继续'],
  ),
  // Re-send the last user input, discarding whatever the previous
  // round produced (the AI response, any tool calls, etc.). Best used
  // after a turn has properly finished but the answer was
  // unsatisfactory; also useful for recovering from an interrupted
  // generation. Alias `/重试` matches the semantics of a typical
  // "retry last request" affordance in chat UIs.
  SlashCommand(name: '/retry', description: 'cmd.retry.desc', aliases: ['/重试']),
  // Wipe the last round (the user prompt plus everything it
  // produced) and copy the original prompt back into the input box
  // for editing — unlike /retry, nothing is re-sent automatically.
  // Alias `/撤销` mirrors /retry's `/重试`. Not available mid-stream:
  // the executor refuses while a response is in flight, so the
  // overlay hides it too.
  SlashCommand(name: '/undo', description: 'cmd.undo.desc', aliases: ['/撤销']),
  // Ephemeral side-question: ask the model a quick question without
  // polluting the real conversation. The AI's reply is rendered in a
  // boxed, dim bubble and lives only in memory. Consecutive `/btw`
  // calls chain (each one sees the prior btw turns as context). The
  // whole chain evaporates the moment the user sends a non-`/btw`
  // message or switches sessions — nothing is ever persisted.
  // `availableDuringResponse: false` so it never races with the
  // main model's in-flight stream.
  SlashCommand(name: '/btw', description: 'cmd.btw.desc'),
  SlashCommand(
    name: '/archive',
    description: 'cmd.archive.desc',
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/unarchive',
    description: 'cmd.unarchive.desc',
    params: ['id'],
    suggestionsPerParam: [[]],
    availableDuringResponse: true,
  ),
  // Rename the current session. Reuses the same persistence path as
  // the rename overlay in the session-management panel (Ctrl+R over
  // a session row), so the title change is reflected both in the
  // sidebar and in any open chat panel immediately. Multi-word
  // titles are supported (the executor joins `parts[1..]` with
  // spaces), so `/rename Ship the parser today` works verbatim.
  // Available during an active response because it doesn't touch
  // the in-flight stream.
  SlashCommand(
    name: '/rename',
    description: 'cmd.rename.desc',
    params: ['title'],
    aliases: ['/重命名'],
    availableDuringResponse: true,
  ),
  // Exit Crux cleanly. When the agent is streaming, the
  // command is rejected with a toast that points at the
  // keyboard affordances: clicking the flashing model button
  // interrupts the in-flight response, and pressing Ctrl+C
  // twice in quick succession exits the app.
  // Otherwise it calls `shutdownApp()` from
  // nocterm, which tears down the alt-screen, then
  // `runApp()` returns to `bin/crux.dart` and the per-run
  // summary is printed to stdout. `/exit` is registered as
  // an alias for muscle-memory parity with other shells.
  SlashCommand(
    name: '/quit',
    description: 'cmd.quit.desc',
    aliases: ['/exit'],
    availableDuringResponse: false,
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
  // Inspect the aux shell-monitor's recent verdict history. Reads
  // `shell_monitor_logs` (one row per check) and prints the last few
  // monitored runs — command, per-check verdict/interval/reason, and
  // how the run ended — so you can verify the monitor is judging
  // progress correctly without tailing a log file. `[n]` caps how
  // many runs to show (default 5, max 20).
  SlashCommand(
    name: '/d-monitor',
    description: '[debug] Show recent aux shell-monitor runs',
    params: ['n?'],
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
    description: '[debug] Display a toast — mode (info/error/status) is auto-detected from the message',
    params: ['message'],
    availableDuringResponse: true,
  ),
  SlashCommand(
    name: '/d-fullpane',
    description: '[debug] Open the fullpane (near-full-screen modal) overlay',
    availableDuringResponse: true,
  ),
  // Record per-frame timings for the given duration (default 5s),
  // then dump a JSON report under the user data dir.
  // Usage:
  //   /d-profiler              → status
  //   /d-profiler <secs>       → record for <secs> seconds
  //   /d-profiler <secs> <path>→ record for <secs> seconds, write
  //                              report to <path>
  //   /d-profiler stop         → stop the active recording and
  //                              dump the report immediately
  SlashCommand(
    name: '/d-profiler',
    description: '[debug] Record per-frame timings: /d-profiler <secs> [path], /d-profiler stop',
    params: ['secs', 'path?'],
    availableDuringResponse: true,
  ),
];

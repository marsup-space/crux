import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../models/slash_command.dart';
import '../models/session.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/skills/skill.dart';
import '../services/skills/skill_discovery.dart';
import '../services/web_provider_registry.dart';
import '../i18n/strings.dart';
import '../theme/theme_controller.dart';
import '../utils/at_mention_parser.dart';
import '../utils/file_searcher.dart';
import '../utils/skill_chip_parser.dart';
import '../utils/session_mention.dart';
import '../commands/registry.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';

/// Manages overlay state for the chat input: detects @-mentions, command
/// mode, parameter mode, and builds suggestion lists.
///
/// Extracted from `ChatInputState` so the 230-line `_onTextChanged` method
/// and its helpers live in their own class.
class InputOverlay {
  final OverlayController overlayController;
  final SessionController sessionController;
  final ProviderService providerService;
  final WebProviderRegistry webProviderRegistry;
  final ThemeController themeController;
  final bool providerServiceReady;
  final RecentProjectsStore? recentProjectsStore;
  final TextEditingController textController;
  final String projectPath;
  final VoidCallback refresh;
  final void Function() onStateChanged;
  final Strings strings;

  /// Basename (e.g. `test run.md`) of the currently-active plan doc, or
  /// null when plan mode is off. Used by the `/plan` autocomplete branch
  /// to flag the active plan among the suggestions. Optional so tests
  /// and the home quick-chat input don't need a plan controller.
  final String? Function()? activePlanName;

  // @-mention state
  final FileSearcher _fileSearcher;
  Timer? _atMentionDebouncer;
  int _atMentionSearchSeq = 0;

  // #-mention (session) state
  Timer? _sessionMentionDebouncer;
  int _sessionMentionSearchSeq = 0;

  InputOverlay({
    required this.overlayController,
    required this.sessionController,
    required this.providerService,
    required this.webProviderRegistry,
    required this.themeController,
    required this.providerServiceReady,
    required this.recentProjectsStore,
    required this.textController,
    required this.projectPath,
    required this.refresh,
    required this.onStateChanged,
    this.activePlanName,
    Strings strings = kEnglishStrings,
  })  : strings = strings,
        _fileSearcher = FileSearcher(rootPath: projectPath);

  void dispose() {
    _atMentionDebouncer?.cancel();
    _sessionMentionDebouncer?.cancel();
    _fileSearcher.dispose();
  }

  /// Called when the text changes. Updates the overlay state based on
  /// the current text and cursor position.
  void onTextChanged() {
    final text = textController.text;
    overlayController.pruneMentionChips(text);

    // First, check for a `$` skill chip. The chip is the only
    // trigger that can be active at the same time as an at-mention
    // (they have different trigger chars), but for clarity we
    // check it before the at-mention.
    final chip = findActiveSkillChip(
      text,
      textController.selection.extentOffset,
    );
    if (chip != null) {
      _showSkillChip(chip);
      _maybeRefresh();
      return;
    }

    // Then check for an @-mention trigger.
    final mention = _findActiveMention();
    if (mention != null &&
        !overlayController.isMentionClosed(mention.atOffset)) {
      _showAtMention(mention);
      _maybeRefresh();
      return;
    }

    // Then check for a #-mention (session) trigger.
    final sessionMention = _findActiveSessionMention();
    if (sessionMention != null &&
        !overlayController.isMentionClosed(sessionMention.hashOffset)) {
      _showSessionMention(sessionMention);
      _maybeRefresh();
      return;
    }

    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      overlayController.setOverlayOff();
      _maybeRefresh();
      return;
    }

    final spaceIndex = trimmed.indexOf(' ');

    if (spaceIndex == -1) {
      overlayController.filteredCommands = filterCommands(trimmed);
      if (overlayController.filteredCommands.isEmpty) {
        overlayController.setOverlayOff();
      } else {
        overlayController.overlayMode = OverlayMode.command;
        overlayController.selectedCommandIndex = 0;
        overlayController.commandScrollOffset = 0;
      }
      _maybeRefresh();
      return;
    }

    final commandName = trimmed.substring(0, spaceIndex);
    final command = findCommand(commandName);

    // A '/' token with arguments that doesn't resolve to a command is
    // not a command at all — it's a pasted path or plain text the user
    // prepended onto. Leave the overlay off so it behaves as a normal
    // message (and submits as text) instead of a broken command.
    if (command == null) {
      overlayController.setOverlayOff();
      _maybeRefresh();
      return;
    }

    if (!command.hasSuggestionsForParam(0) &&
        commandName != '/model' &&
        commandName != '/auxiliary' &&
        commandName != '/provider' &&
        commandName != '/web-provider' &&
        commandName != '/theme' &&
        commandName != '/plan' &&
        commandName != '/project') {
      overlayController.setOverlayOff();
      _maybeRefresh();
      return;
    }

    final afterCommand = trimmed.substring(spaceIndex + 1);
    int paramIndex;
    String currentInput;

    if (afterCommand.isEmpty) {
      paramIndex = 0;
      currentInput = '';
    } else if (afterCommand.endsWith(' ')) {
      final completedParts = afterCommand
          .trimRight()
          .split(' ')
          .where((s) => s.isNotEmpty)
          .toList();
      paramIndex = completedParts.length;
      currentInput = '';
    } else {
      final parts = afterCommand.split(' ');
      currentInput = parts.last;
      paramIndex = parts.length - 1;
    }

    if (!command.hasSuggestionsForParam(paramIndex) &&
        !(commandName == '/model' && paramIndex == 0) &&
        !(commandName == '/auxiliary' && paramIndex == 0) &&
        !(commandName == '/provider' && paramIndex == 0) &&
        !(commandName == '/web-provider' && paramIndex == 0) &&
        !(commandName == '/theme' && paramIndex == 0) &&
        !(commandName == '/plan' && paramIndex == 0) &&
        !(commandName == '/project' && paramIndex == 0)) {
      overlayController.setOverlayOff();
      _maybeRefresh();
      return;
    }

    final List<CommandSuggestion> suggestions;
    if (commandName == '/session' && paramIndex == 0) {
      suggestions = sessionController.sessions
          .map(
            (s) => CommandSuggestion(value: s.displayId, description: s.title),
          )
          .toList();
    } else if (commandName == '/auxiliary' && paramIndex == 0) {
      if (providerServiceReady) {
        suggestions = [
          CommandSuggestion(value: 'none', description: 'No auxiliary model'),
          ...providerService
              .allModelEntries()
              .where((e) => providerService.getApiKey(e.providerName) != null)
              .map((e) {
                final ctx = e.model.contextSize >= 1000000
                    ? '${(e.model.contextSize / 1048576).toStringAsFixed(0)}M'
                    : '${(e.model.contextSize / 1000).toStringAsFixed(0)}K';
                final img = e.model.imageSupport ? ', img' : '';
                final think = e.model.thinking ? ', think' : '';
                return CommandSuggestion(
                  value: e.compositeKey,
                  description: '${e.model.name} ($ctx ctx$img$think)',
                );
              }),
        ];
      } else {
        suggestions = [];
      }
    } else if (commandName == '/provider' && paramIndex == 0) {
      if (providerServiceReady) {
        suggestions = providerService
            .providerNames()
            .map(
              (name) => CommandSuggestion(
                value: name,
                description: providerService.getApiKey(name) != null
                    ? 'key set'
                    : null,
              ),
            )
            .toList();
      } else {
        suggestions = [];
      }
    } else if (commandName == '/web-provider' && paramIndex == 0) {
      suggestions = webProviderRegistry.allProviders
          .map(
            (p) => CommandSuggestion(
              value: p.id,
              description: p.isConfigured ? 'key set' : null,
            ),
          )
          .toList();
    } else if (commandName == '/theme' && paramIndex == 0) {
      suggestions = themeController.registry.themes
          .map(
            (theme) => CommandSuggestion(
              value: theme.id,
              description: '${theme.name} (${theme.brightness.name})',
            ),
          )
          .toList();
    } else if (commandName == '/model' && paramIndex == 0) {
      if (providerServiceReady) {
        suggestions = providerService
            .allModelEntries()
            .where((e) => providerService.getApiKey(e.providerName) != null)
            .map((e) {
              final ctx = e.model.contextSize >= 1000000
                  ? '${(e.model.contextSize / 1048576).toStringAsFixed(0)}M'
                  : '${(e.model.contextSize / 1000).toStringAsFixed(0)}K';
              final img = e.model.imageSupport ? ', img' : '';
              final think = e.model.thinking ? ', think' : '';
              return CommandSuggestion(
                value: e.compositeKey,
                description: '${e.model.name} ($ctx ctx$img$think)',
              );
            })
            .toList();
      } else {
        suggestions = [];
      }
    } else if (commandName == '/project' && paramIndex == 0) {
      final store = recentProjectsStore;
      if (store == null) {
        suggestions = const [];
      } else {
        final now = DateTime.now();
        suggestions = [
          for (final entry in store.entries)
            CommandSuggestion(
              value: entry.path,
              description: _describeRecentProject(entry, now, strings),
            ),
        ];
      }
    } else if (commandName == '/plan' && paramIndex == 0) {
      // List the existing plan docs in the project root (non-recursive —
      // that's where `PlanModeController.enter` resolves names). Each
      // value is the file name with the `.md` suffix stripped so the
      // command receives the bare plan name. The active plan is flagged
      // so re-entering it is obvious. A fresh name simply gets no match
      // (the fuzzy filter drops it), which is correct — `enter` creates it.
      final active = activePlanName?.call();
      final dir = Directory(projectPath);
      final found = <CommandSuggestion>[];
      if (dir.existsSync()) {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final base = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : entity.path.split('/').last;
          if (!base.endsWith('.md')) continue;
          if (base.startsWith('.')) continue;
          final name = base.substring(0, base.length - '.md'.length);
          if (name.isEmpty) continue;
          found.add(
            CommandSuggestion(
              value: name,
              description: base == active
                  ? strings.t('cmd.plan.sug.active')
                  : strings.t('cmd.plan.sug.existing'),
            ),
          );
        }
      }
      // Surface the active plan first, then the rest alphabetically.
      found.sort((a, b) {
        final aActive = a.description == strings.t('cmd.plan.sug.active');
        final bActive = b.description == strings.t('cmd.plan.sug.active');
        if (aActive != bActive) return aActive ? -1 : 1;
        return a.value.compareTo(b.value);
      });
      suggestions = found;
    } else {
      suggestions = command.suggestionsPerParam[paramIndex];
    }
    overlayController.filteredSuggestions = filterSuggestions(
      suggestions,
      currentInput,
    );

    if (overlayController.filteredSuggestions.isEmpty) {
      overlayController.setOverlayOff();
      refresh();
      return;
    }

    overlayController.overlayMode = OverlayMode.parameter;
    overlayController.activeCommand = command;
    overlayController.currentParamIndex = paramIndex;
    overlayController.selectedSuggestionIndex = 0;
    overlayController.suggestionScrollOffset = 0;
    refresh();
  }

  AtMentionPosition? _findActiveMention() {
    return findActiveMentionInText(
      textController.text,
      textController.selection.extentOffset,
    );
  }

  void _showSkillChip(SkillChipPosition chip) {
    // Discover synchronously — the skill set is static for the
    // duration of the picker. For very large projects the walk
    // can take a few hundred ms, but typing `$` is a deliberate
    // gesture, so the latency is acceptable. (We can move this
    // to a Future + cached set later if profiles show a problem.)
    final available = discoverSkills(cwd: projectPath);
    final filtered = _filterSkills(available, chip.query);
    if (filtered.isEmpty) {
      overlayController.setOverlayOff();
      return;
    }

    final stayingOnSameChip =
        overlayController.overlayMode == OverlayMode.skillPicker &&
        overlayController.skillChipDollarOffset == chip.dollarOffset;
    if (!stayingOnSameChip) {
      overlayController.selectedSkillIndex = 0;
      overlayController.skillScrollOffset = 0;
    }

    overlayController.overlayMode = OverlayMode.skillPicker;
    overlayController.skillChipDollarOffset = chip.dollarOffset;
    overlayController.skillChipQuery = chip.query;
    overlayController.filteredSkills = filtered;
  }

  /// Filter [available] by [query]: empty query returns everything;
  /// otherwise the skill name must start with the query (case-
  /// sensitive, matches the open-standard name shape).
  List<SkillInfo> _filterSkills(List<SkillInfo> available, String query) {
    if (query.isEmpty) return available;
    final lower = query.toLowerCase();
    return available
        .where((s) => _fuzzyMatch(s.name, lower))
        .toList(growable: false);
  }

  /// True if [query] is a fuzzy subsequence of [target]. Each char
  /// in [query] must appear in [target] in order, but not
  /// necessarily adjacent. Case-insensitive.
  static bool _fuzzyMatch(String target, String query) {
    final t = target.toLowerCase();
    var ti = 0;
    for (var qi = 0; qi < query.length; qi++) {
      final ch = query[qi];
      var found = false;
      while (ti < t.length) {
        if (t[ti] == ch) {
          ti++;
          found = true;
          break;
        }
        ti++;
      }
      if (!found) return false;
    }
    return true;
  }

  void _showAtMention(AtMentionPosition mention) {
    final stayingOnSameAt =
        overlayController.overlayMode == OverlayMode.atMention &&
        overlayController.atMentionOffset == mention.atOffset;
    if (!stayingOnSameAt) {
      overlayController.selectedFileIndex = 0;
      overlayController.fileScrollOffset = 0;
      overlayController.filteredFiles = const [];
    }

    overlayController.overlayMode = OverlayMode.atMention;
    overlayController.atMentionOffset = mention.atOffset;
    overlayController.atMentionQuery = mention.query;

    _fileSearcher.ensureIndex();

    overlayController.isSearching = true;

    _atMentionDebouncer?.cancel();
    final seq = ++_atMentionSearchSeq;
    _atMentionDebouncer = Timer(const Duration(milliseconds: 60), () {
      _runAtMentionSearch(mention, seq);
    });
  }

  Future<void> _runAtMentionSearch(AtMentionPosition mention, int seq) async {
    if (seq != _atMentionSearchSeq) return;
    if (overlayController.overlayMode != OverlayMode.atMention) return;
    if (overlayController.atMentionQuery != mention.query) return;

    overlayController.isSearching = true;
    refresh();

    List<FileMatch> results = const [];
    try {
      if (_fileSearcher.isIndexing) {
        await _fileSearcher.ready;
      }
      if (seq != _atMentionSearchSeq) return;
      if (overlayController.overlayMode != OverlayMode.atMention) return;
      if (overlayController.atMentionQuery != mention.query) return;
      results = await _fileSearcher.searchAsync(mention.query);
    } catch (_) {}
    if (seq != _atMentionSearchSeq) return;
    if (overlayController.overlayMode != OverlayMode.atMention) return;
    if (overlayController.atMentionQuery != mention.query) return;

    overlayController.filteredFiles = results;
    overlayController.isSearching = false;
    refresh();
  }

  SessionMentionPosition? _findActiveSessionMention() {
    return findActiveSessionMention(
      textController.text,
      textController.selection.extentOffset,
    );
  }

  void _showSessionMention(SessionMentionPosition mention) {
    final stayingOnSameHash =
        overlayController.overlayMode == OverlayMode.sessionMention &&
        overlayController.sessionMentionHashOffset == mention.hashOffset;
    if (!stayingOnSameHash) {
      overlayController.selectedSessionMentionIndex = 0;
      overlayController.sessionMentionScrollOffset = 0;
    }

    overlayController.overlayMode = OverlayMode.sessionMention;
    overlayController.sessionMentionHashOffset = mention.hashOffset;
    overlayController.sessionMentionQuery = mention.query;

    // Seed synchronously from the in-memory sessions/chats so the
    // popover paints instantly; archived candidates arrive via the
    // debounced async pass below.
    final inMemory = <Session>[
      ...sessionController.sessions,
      ...sessionController.chats,
    ];
    overlayController.filteredSessionMentions = rankSessionMentions(
      inMemory,
      mention.query,
    );

    _sessionMentionDebouncer?.cancel();
    final seq = ++_sessionMentionSearchSeq;
    _sessionMentionDebouncer = Timer(const Duration(milliseconds: 40), () {
      _runSessionMentionSearch(mention, seq);
    });
  }

  Future<void> _runSessionMentionSearch(
    SessionMentionPosition mention,
    int seq,
  ) async {
    if (seq != _sessionMentionSearchSeq) return;
    if (overlayController.overlayMode != OverlayMode.sessionMention) return;
    if (overlayController.sessionMentionQuery != mention.query) return;

    List<Session> candidates = const [];
    try {
      candidates = await sessionController.loadSessionMentionCandidates();
    } catch (_) {}

    if (seq != _sessionMentionSearchSeq) return;
    if (overlayController.overlayMode != OverlayMode.sessionMention) return;
    if (overlayController.sessionMentionQuery != mention.query) return;

    overlayController.filteredSessionMentions = rankSessionMentions(
      candidates,
      mention.query,
    );
    refresh();
  }

  void _maybeRefresh() {
    // Always refresh for now — the snapshot optimization can be added later.
    refresh();
  }

  static String _describeRecentProject(
    RecentProject entry,
    DateTime now,
    Strings strings,
  ) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final displayPath =
        (home != null && home.isNotEmpty && entry.path.startsWith(home))
        ? '~${entry.path.substring(home.length)}'
        : entry.path;

    final ageMs = now.difference(entry.lastOpenedAt).inMilliseconds;
    final String? relative;
    if (entry.lastOpenedAt.millisecondsSinceEpoch == 0) {
      relative = null;
    } else if (ageMs < 60 * 1000) {
      relative = strings.t('chat.time.justNow');
    } else if (ageMs < 60 * 60 * 1000) {
      relative = strings.t('chat.time.minutesAgo', {'n': '${ageMs ~/ (60 * 1000)}'});
    } else if (ageMs < 24 * 60 * 60 * 1000) {
      relative = strings.t('chat.time.hoursAgo', {'n': '${ageMs ~/ (60 * 60 * 1000)}'});
    } else if (ageMs < 7 * 24 * 60 * 60 * 1000) {
      relative = strings.t('chat.time.daysAgo', {'n': '${ageMs ~/ (24 * 60 * 60 * 1000)}'});
    } else {
      relative = null;
    }

    if (relative == null) return displayPath;
    return '$displayPath — $relative';
  }
}

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../models/slash_command.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/skills/skill.dart';
import '../services/skills/skill_discovery.dart';
import '../services/web_provider_registry.dart';
import '../theme/theme_controller.dart';
import '../utils/at_mention_parser.dart';
import '../utils/file_searcher.dart';
import '../utils/skill_chip_parser.dart';
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

  // @-mention state
  final FileSearcher _fileSearcher;
  Timer? _atMentionDebouncer;
  int _atMentionSearchSeq = 0;

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
  }) : _fileSearcher = FileSearcher(rootPath: projectPath);

  void dispose() {
    _atMentionDebouncer?.cancel();
    _fileSearcher.dispose();
  }

  /// Called when the text changes. Updates the overlay state based on
  /// the current text and cursor position.
  void onTextChanged() {
    final text = textController.text;

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
    if (mention != null) {
      _showAtMention(mention);
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
              description: _describeRecentProject(entry, now),
            ),
        ];
      }
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

  void _maybeRefresh() {
    // Always refresh for now — the snapshot optimization can be added later.
    refresh();
  }

  static String _describeRecentProject(RecentProject entry, DateTime now) {
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
    } else if (ageMs < 0) {
      relative = 'just now';
    } else if (ageMs < 60 * 1000) {
      relative = 'just now';
    } else if (ageMs < 60 * 60 * 1000) {
      relative = '${ageMs ~/ (60 * 1000)}m ago';
    } else if (ageMs < 24 * 60 * 60 * 1000) {
      relative = '${ageMs ~/ (60 * 60 * 1000)}h ago';
    } else if (ageMs < 7 * 24 * 60 * 60 * 1000) {
      relative = '${ageMs ~/ (24 * 60 * 60 * 1000)}d ago';
    } else {
      relative = null;
    }

    if (relative == null) return displayPath;
    return '$displayPath — $relative';
  }
}

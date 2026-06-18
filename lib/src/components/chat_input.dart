import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../models/image_attachment.dart';
import '../models/slash_command.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/at_mention_parser.dart';
import '../utils/clipboard_image.dart';
import '../utils/clipboard_text.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/dropped_file_handler.dart';
import '../utils/file_searcher.dart';
import '../utils/frame_profiler.dart';
import '../commands/registry.dart';
import 'chat_turn_orchestrator.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/toast.dart';

/// The chat input box at the bottom of the chat panel.
///
/// Handles keyboard events (Enter to send, Shift+Enter for newline,
/// ESC×2 to interrupt, arrow keys for overlay navigation), text-change
/// driven autocomplete/overlay logic, and renders the command/suggestion
/// overlays.
///
/// Use [ChatInputState] with a [GlobalKey] to call
/// [ChatInputState.stashAndSetCommand] from parent widgets (e.g. when a
/// toolbar button replaces the input text with a '/' command).
class ChatInput extends StatefulComponent {
  final TextEditingController textController;
  final OverlayController overlayController;
  final SessionController sessionController;
  final StreamingController streamingController;
  final ChatTurnOrchestrator turnOrchestrator;
  final ProviderService providerService;
  final bool providerServiceReady;
  final ThemeController themeController;
  final AutoScrollController scrollController;
  final void Function() refresh;
  final void Function(String text) onSendTurn;
  final void Function(String text) onExecuteCommand;
  final Future<void> Function(int sessionId) onSwitchSession;
  final Future<void> Function() onInitSessions;
  final Future<void> Function() onCreateNewSession;
  final void Function(ImageAttachment image)? onAttachClipboardImage;

  /// Absolute path of the project root, used by the @-mention file
  /// browser to scope its fuzzy search. Defaults to the current
  /// working directory when not provided.
  final String projectPath;

  /// Source of `/project` autocomplete suggestions. When provided,
  /// typing `/project ` shows the recently-opened directories as
  /// pickable items (most-recent first) instead of an empty list.
  /// Optional so legacy/test harnesses that don't care about recent
  /// projects can still construct a `ChatInput`.
  final RecentProjectsStore? recentProjectsStore;

  const ChatInput({
    super.key,
    required this.textController,
    required this.overlayController,
    required this.sessionController,
    required this.streamingController,
    required this.turnOrchestrator,
    required this.providerService,
    required this.providerServiceReady,
    required this.themeController,
    required this.scrollController,
    required this.refresh,
    required this.onSendTurn,
    required this.onExecuteCommand,
    required this.onSwitchSession,
    required this.onInitSessions,
    required this.onCreateNewSession,
    this.onAttachClipboardImage,
    this.projectPath = '.',
    this.recentProjectsStore,
  });

  @override
  State<ChatInput> createState() => ChatInputState();
}

/// Local alias for [AtMentionPosition], the value object returned by
/// [findActiveMentionInText] (and previously the private `_AtMention`
/// class). Used at the call sites inside [ChatInputState] to keep the
/// rest of the file from leaking the parser's type name.
typedef _AtMention = AtMentionPosition;

/// Lightweight snapshot of just the [OverlayController] fields
/// the chat panel actually reads when rendering the overlay
/// popover. Captured before mutating the overlay and compared
/// after, so [_ChatInputState._onTextChanged] can skip the
/// chat-panel refresh for the 95% of keystrokes that don't
/// actually change what's shown above the input.
///
/// Lives at top level (not nested in [ChatInputState]) because
/// Dart disallows nested class declarations. Equality is
/// field-by-field via [ChatInputState._overlayChanged] so the
/// snapshot can be a plain data class without overriding
/// `==`/`hashCode` (avoiding allocations in the hot path).
class OverlaySnapshot {
  const OverlaySnapshot({
    required this.mode,
    required this.commandsLen,
    required this.suggestionsLen,
    required this.filesLen,
    required this.isSearching,
    required this.selectedCommandIndex,
    required this.selectedSuggestionIndex,
    required this.selectedFileIndex,
    required this.atMentionQuery,
    required this.showSessionManager,
    required this.showFullpane,
  });

  final OverlayMode mode;
  final int commandsLen;
  final int suggestionsLen;
  final int filesLen;
  final bool isSearching;
  final int selectedCommandIndex;
  final int selectedSuggestionIndex;
  final int selectedFileIndex;
  final String atMentionQuery;
  final bool showSessionManager;
  final bool showFullpane;
}

class ChatInputState extends State<ChatInput> {
  static final RegExp _imageMarkerPattern = RegExp(r'\[ image (\d+) \]');

  /// Timestamp of the last ESC key press while the agent was streaming.
  DateTime? _lastEscPressTime;

  /// True briefly after the first ESC press while streaming, so the
  /// UI can show a "Press ESC again to interrupt" hint.
  bool _escInterruptHint = false;

  /// Timestamp of the last Ctrl+C key press while the agent was streaming.
  /// Used to implement a two-step quit guard: first Ctrl+C shows a toast,
  /// second Ctrl+C within the timeout actually quits the app.
  DateTime? _lastCtrlCPressTime;

  /// True briefly after the first Ctrl+C press while streaming, so the
  /// UI can show a "Press Ctrl+C again to quit" hint.
  bool _ctrlCQuitHint = false;

  /// Lazily-built file/directory index for the @-mention browser.
  /// Scoped to [ChatInput.projectPath] so different project roots
  /// don't bleed into each other. Re-walked on demand if the user
  /// switches projects (via `/project`); the caller is expected to
  /// call [_fileSearcher.invalidate] in that case, but for now we
  /// just rebuild from the constructor's path on first use.
  late FileSearcher _fileSearcher = FileSearcher(
    rootPath: component.projectPath,
  );

  /// Debounce timer for the @-mention search. We don't want to
  /// run the fuzzy scan on every keystroke (it can scan 50k
  /// paths); 60ms of quiet settles the burst and is well below
  /// the human-perceptible lag threshold (~100ms).
  Timer? _atMentionDebouncer;

  /// Monotonic counter used to discard stale async search results.
  /// Each keystroke bumps the counter; if a search started under
  /// an older counter finishes, we ignore its result so the UI
  /// doesn't flicker with out-of-date matches.
  int _atMentionSearchSeq = 0;

  /// Text that was in the input box before the user entered command mode
  /// (by typing '/' as the first character or by pressing a toolbar button
  /// that places a '/' command in the box). This text is restored when the
  /// user deletes all characters while in command mode, giving them back
  /// their work-in-progress message.
  String? _commandStashedText;

  bool _syncingImageMarkers = false;

  /// Public read-only access to the command-stashed text. Used by
  /// ChatPanel when switching sessions to preserve the user's message
  /// that was hidden behind a '/' command.
  String? get commandStashedText => _commandStashedText;

  /// Decide what to rebuild after [_onTextChanged] mutated the
  /// overlay state. If the panel-visible state actually
  /// changed, kick the chat panel so it can re-render the
  /// overlay popover. Otherwise just refresh this input
  /// (for placeholder / pending-image changes) — the chat
  /// history with 606 messages does NOT need to be rebuilt.
  void _maybeRefresh(OverlaySnapshot prev, OverlayController overlay) {
    if (_overlayChanged(prev, overlay)) {
      component.refresh();
    } else {
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    component.textController.addListener(_onTextChanged);
    CommandRegistry.instance.addListener(component.refresh);
    // `component.refresh` alone rebuilds the panel but doesn't
    // re-evaluate the suggestion overlay (suggestions are only
    // repopulated when `_onTextChanged` runs). When the store
    // changes — most commonly right after a successful
    // `/project <path>` switch — we want the suggestion list
    // to refresh even if the user hasn't typed anything new,
    // so a freshly-added entry appears immediately. Calling
    // `_onTextChanged` re-reads the current text and rebuilds
    // the overlay against the new store state; if no command
    // is being composed, the overlay just gets cleared, which
    // is the correct no-op behavior.
    component.recentProjectsStore?.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    component.textController.removeListener(_onTextChanged);
    CommandRegistry.instance.removeListener(component.refresh);
    component.recentProjectsStore?.removeListener(_onTextChanged);
    _atMentionDebouncer?.cancel();
    super.dispose();
  }

  /// Public API for parent widgets (e.g. ChatPanel) to stash any current
  /// input text and replace it with a command string. This is used when a
  /// toolbar button (model selector, compact, auxiliary) is pressed — the
  /// user's work-in-progress text is preserved and will be restored when
  /// the command is dismissed.
  void stashAndSetCommand(String commandText) {
    final currentText = component.textController.text;
    if (currentText.isNotEmpty && !currentText.startsWith('/')) {
      _commandStashedText = currentText;
    }
    component.textController.text = commandText;
    component.textController.selection = TextSelection.collapsed(
      offset: commandText.length,
    );
  }

  /// Load the stashed input text for the given session. Called after
  /// switching sessions.
  void loadSessionStash(int sessionId) {
    final stashedText = component.sessionController.inputTextStash[sessionId];
    if (stashedText != null && stashedText.isNotEmpty) {
      component.textController.text = stashedText;
      component.textController.selection = TextSelection.collapsed(
        offset: stashedText.length,
      );
    } else {
      component.textController.clear();
    }
    // Clear command stash when switching sessions — it's session-local.
    _commandStashedText = null;
  }

  /// Restore the command-stashed text into the input box. Called when a
  /// command finishes executing (the user's original message should return
  /// to the input box) and when the user dismisses command mode (ESC,
  /// backspace-to-empty). If there is no stash, this is a no-op and the
  /// input stays cleared.
  void restoreCommandStash() {
    if (_commandStashedText != null && _commandStashedText!.isNotEmpty) {
      component.textController.text = _commandStashedText!;
      component.textController.selection = TextSelection.collapsed(
        offset: _commandStashedText!.length,
      );
    }
    _commandStashedText = null;
  }

  /// Restore stashed text into the input box and clear the stash.
  void _restoreStashedText() {
    restoreCommandStash();
  }

  /// Capture the overlay's "what the panel needs to redraw"
  /// state right before we mutate it, so [_onTextChanged] can
  /// tell whether a chat-panel rebuild is actually needed.
  ///
  /// Without this, every keystroke calls `component.refresh()`,
  /// which causes a full chat-panel rebuild (rebuilding the
  /// chat history with all 606 messages, layouting the
  /// visible ones in ~30ms). Most keystrokes don't change
  /// what's shown above the input — typing `hello` keeps the
  /// overlay mode at `off` the whole time — so the chat
  /// panel rebuild is wasted work. Comparing the snapshot
  /// before/after each keystroke lets us skip the chat-panel
  /// refresh for the 95% of keystrokes that don't actually
  /// change the overlay.
  ///
  /// Captured fields are intentionally restricted to the
  /// subset that the chat panel's overlay rendering reads
  /// (see `chat_panel._buildOverlays`). Anything not in here
  /// doesn't affect the panel.
  OverlaySnapshot _snapshotOverlay(OverlayController o) {
    return OverlaySnapshot(
      mode: o.overlayMode,
      commandsLen: o.filteredCommands.length,
      suggestionsLen: o.filteredSuggestions.length,
      filesLen: o.filteredFiles.length,
      isSearching: o.isSearching,
      selectedCommandIndex: o.selectedCommandIndex,
      selectedSuggestionIndex: o.selectedSuggestionIndex,
      selectedFileIndex: o.selectedFileIndex,
      atMentionQuery: o.atMentionQuery,
      showSessionManager: o.showSessionManager,
      showFullpane: o.showFullpane,
    );
  }

  /// Returns true iff the panel-rendered overlay state
  /// changed since [prev]. Cheap field-by-field comparison;
  /// lists are compared by length (the panel only needs to
  /// know "are there items to render?", and equality on
  /// lists would also work but does a full element-by-element
  /// walk we don't need).
  bool _overlayChanged(OverlaySnapshot prev, OverlayController o) {
    return prev.mode != o.overlayMode ||
        prev.commandsLen != o.filteredCommands.length ||
        prev.suggestionsLen != o.filteredSuggestions.length ||
        prev.filesLen != o.filteredFiles.length ||
        prev.isSearching != o.isSearching ||
        prev.selectedCommandIndex != o.selectedCommandIndex ||
        prev.selectedSuggestionIndex != o.selectedSuggestionIndex ||
        prev.selectedFileIndex != o.selectedFileIndex ||
        prev.atMentionQuery != o.atMentionQuery ||
        prev.showSessionManager != o.showSessionManager ||
        prev.showFullpane != o.showFullpane;
  }

  void _onTextChanged() {
    if (!_syncingImageMarkers) {
      _syncPendingImagesWithMarkers();
    }

    final text = component.textController.text;
    final overlay = component.overlayController;

    // Snapshot the overlay state before mutating it so we
    // can compare afterwards and decide whether a
    // chat-panel-wide refresh is actually needed. Most
    // keystrokes leave every field of this snapshot
    // identical, so the refresh is skipped and only the
    // chat input itself rebuilds (via setState below).
    final prev = _snapshotOverlay(overlay);

    // First, check for an @-mention trigger. The `@` doesn't have
    // to be at offset 0 — it can appear anywhere in the text. We
    // look for the last `@` at or before the cursor that's preceded
    // by a non-identifier char (so emails don't trigger).
    final mention = _findActiveMention();
    if (mention != null) {
      _showAtMention(mention);
      _maybeRefresh(prev, overlay);
      return;
    }

    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      overlay.setOverlayOff();
      _maybeRefresh(prev, overlay);
      return;
    }

    final spaceIndex = trimmed.indexOf(' ');

    if (spaceIndex == -1) {
      overlay.filteredCommands = filterCommands(trimmed);
      if (overlay.filteredCommands.isEmpty) {
        overlay.setOverlayOff();
      } else {
        overlay.overlayMode = OverlayMode.command;
        overlay.selectedCommandIndex = 0;
        overlay.commandScrollOffset = 0;
      }
      _maybeRefresh(prev, overlay);
      return;
    }

    final commandName = trimmed.substring(0, spaceIndex);
    final command = findCommand(commandName);

    if (command == null ||
        (!command.hasSuggestionsForParam(0) &&
            commandName != '/model' &&
            commandName != '/auxiliary' &&
            commandName != '/provider' &&
            commandName != '/theme' &&
            commandName != '/project')) {
      overlay.setOverlayOff();
      _maybeRefresh(prev, overlay);
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
        !(commandName == '/theme' && paramIndex == 0) &&
        !(commandName == '/project' && paramIndex == 0)) {
      overlay.setOverlayOff();
      _maybeRefresh(prev, overlay);
      return;
    }

    final List<CommandSuggestion> suggestions;
    if (commandName == '/session' && paramIndex == 0) {
      suggestions = component.sessionController.sessions
          .map(
            (s) => CommandSuggestion(value: s.displayId, description: s.title),
          )
          .toList();
    } else if (commandName == '/auxiliary' && paramIndex == 0) {
      if (component.providerServiceReady) {
        suggestions = [
          CommandSuggestion(value: 'none', description: 'No auxiliary model'),
          ...component.providerService
              .allModelEntries()
              .where(
                (e) =>
                    component.providerService.getApiKey(e.providerName) != null,
              )
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
      if (component.providerServiceReady) {
        suggestions = component.providerService
            .providerNames()
            .map(
              (name) => CommandSuggestion(
                value: name,
                description: component.providerService.getApiKey(name) != null
                    ? 'key set'
                    : null,
              ),
            )
            .toList();
      } else {
        suggestions = [];
      }
    } else if (commandName == '/theme' && paramIndex == 0) {
      suggestions = component.themeController.registry.themes
          .map(
            (theme) => CommandSuggestion(
              value: theme.id,
              description: '${theme.name} (${theme.brightness.name})',
            ),
          )
          .toList();
    } else if (commandName == '/model' && paramIndex == 0) {
      if (component.providerServiceReady) {
        suggestions = component.providerService
            .allModelEntries()
            .where(
              (e) =>
                  component.providerService.getApiKey(e.providerName) != null,
            )
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
      // Surface the recently-opened directories so the user can hop
      // back into a prior project without retyping its path. The
      // list comes from `RecentProjectsStore` (which itself is fed
      // by successful `/project` switches and by direct `crux
      // <path>` launches), so it's never empty after the first
      // session has ever opened a project.
      final store = component.recentProjectsStore;
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
    overlay.filteredSuggestions = filterSuggestions(suggestions, currentInput);

    if (overlay.filteredSuggestions.isEmpty) {
      overlay.setOverlayOff();
      component.refresh();
      return;
    }

    overlay.overlayMode = OverlayMode.parameter;
    overlay.activeCommand = command;
    overlay.currentParamIndex = paramIndex;
    overlay.selectedSuggestionIndex = 0;
    overlay.suggestionScrollOffset = 0;
    component.refresh();
  }

  /// Build the secondary line shown next to a `/project` suggestion.
  ///
  /// The path itself goes in the suggestion's `value` (which the
  /// suggestion-overlay fills into the input box), so the description
  /// is free to be a friendly, shorter form: a `~`-shortened absolute
  /// path plus a relative-time hint so the user can scan the list and
  /// pick the right one without re-reading every full path.
  ///
  /// Falls back to the raw path on Windows (no `HOME`) and to just
  /// the shortened path when the timestamp is the epoch (a sentinel
  /// we emit when an entry was loaded from a malformed JSON record).
  String _describeRecentProject(RecentProject entry, DateTime now) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final displayPath = (home != null && home.isNotEmpty && entry.path.startsWith(home))
        ? '~${entry.path.substring(home.length)}'
        : entry.path;

    final ageMs = now.difference(entry.lastOpenedAt).inMilliseconds;
    final String? relative;
    if (entry.lastOpenedAt.millisecondsSinceEpoch == 0) {
      relative = null;
    } else if (ageMs < 0) {
      // Clock went backwards since the entry was written; show
      // "just now" rather than a negative duration.
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

  // ─────────────────────────────────────────────────────────────────────
  // @-mention detection
  // ─────────────────────────────────────────────────────────────────────

  /// Scan the input text for an active `@<query>` fragment ending at
  /// the current cursor. Returns `null` if there is no mention the
  /// user is currently editing (e.g. they backspaced out of it, or
  /// they typed whitespace inside the query, or there is no `@`).
  ///
  /// "Active" means: there's an `@` somewhere at or before the
  /// cursor, no terminator between it and the cursor, and the
  /// char before the `@` is either nothing or a non-identifier
  /// char (so `foo@bar` doesn't trigger).
  ///
  /// Whitespace inside a multi-word path component (`My Documents`)
  /// is allowed so users can @-mention files inside directories
  /// whose names contain spaces. See [findActiveMentionInText] for
  /// the exact rules.
  _AtMention? _findActiveMention() {
    final tc = component.textController;
    return findActiveMentionInText(
      tc.text,
      tc.selection.extentOffset,
    );
  }

  /// Open (or refresh) the @-mention file browser with the matches
  /// for [mention.query]. If the popover is already open for a
  /// Trigger the @-mention popover for [mention]. Two-phase:
  ///
  /// 1. Immediately flip the popover into atMention mode and show
  ///    a "Searching..." placeholder if the index is still
  ///    building. This gives the user instant visual feedback
  ///    that their `@` was recognized.
  /// 2. Schedule the actual search on a 60ms debounce so a burst
  ///    of keystrokes coalesces into a single scan. The scan
  ///    itself is async (it `await`s the index build on first
  ///    use) and tagged with a sequence number so an older
  ///    in-flight result can't clobber a fresher one.
  void _showAtMention(_AtMention mention) {
    final overlay = component.overlayController;

    // If the popover is already in atMention mode and the user is
    // just refining the same query (extending it), keep their
    // selected index. Only reset when the atOffset moved (i.e. a
    // different `@` is now active — a stale result from a prior
    // mention shouldn't follow the cursor).
    final stayingOnSameAt =
        overlay.overlayMode == OverlayMode.atMention &&
        overlay.atMentionQuery.length <= mention.query.length;
    if (!stayingOnSameAt) {
      overlay.selectedFileIndex = 0;
      overlay.fileScrollOffset = 0;
    }

    overlay.overlayMode = OverlayMode.atMention;
    overlay.atMentionQuery = mention.query;

    // Kick off async indexing if it hasn't started. The first
    // search is the slow one (file-system walk); after that,
    // every subsequent search is purely in-memory.
    _fileSearcher.ensureIndex();

    // Show "Searching..." while the index is still building or
    // while the debounce timer is pending. The real results
    // replace this once the async search completes.
    if (_fileSearcher.isIndexing) {
      overlay.filteredFiles = const [];
      overlay.isSearching = true;
    } else {
      // Index is warm — we can run the search synchronously and
      // it'll be a few ms even on 50k paths.
      overlay.filteredFiles = _fileSearcher.search(mention.query);
      overlay.isSearching = false;
    }

    // Schedule a debounced re-run so subsequent keystrokes
    // (which clear the index flag) get a fresh result if the
    // index finished building in the meantime.
    _atMentionDebouncer?.cancel();
    final seq = ++_atMentionSearchSeq;
    _atMentionDebouncer = Timer(const Duration(milliseconds: 60), () {
      _runAtMentionSearch(mention, seq);
    });
  }

  /// Async search runner. Awaited by [_showAtMention]'s debounced
  /// timer. If the index isn't ready, this just waits for it,
  /// then runs the search. If the user kept typing (the seq
  /// moved on), the result is discarded.
  Future<void> _runAtMentionSearch(_AtMention mention, int seq) async {
    final overlay = component.overlayController;
    if (seq != _atMentionSearchSeq) return; // stale
    if (overlay.overlayMode != OverlayMode.atMention) return;
    if (overlay.atMentionQuery != mention.query) return;

    // If we're still indexing, wait for it.
    if (_fileSearcher.isIndexing) {
      overlay.isSearching = true;
      component.refresh();
      try {
        await _fileSearcher.ready;
      } catch (_) {
        // ignore — search will just return empty
      }
    }
    if (seq != _atMentionSearchSeq) return;
    if (overlay.overlayMode != OverlayMode.atMention) return;
    if (overlay.atMentionQuery != mention.query) return;

    overlay.filteredFiles = _fileSearcher.search(mention.query);
    overlay.isSearching = false;
    component.refresh();
  }

  bool _handleKeyEvent(KeyboardEvent event) {
    // --- Ctrl+C double-press-to-quit guard ---
    // When any session is currently streaming/responding, the first Ctrl+C
    // shows a toast warning instead of quitting. A second Ctrl+C within
    // 3 seconds (while the toast is active) really quits. When no session
    // is streaming, Ctrl+C passes through and quits immediately (the
    // default TerminalBinding.immediateExit behaviour).
    if (event.logicalKey == LogicalKey.keyC &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed &&
        !event.isMetaPressed) {
      final sessionId = component.sessionController.currentSessionId;
      final isStreaming =
          sessionId != null &&
          component.sessionController.runtime(sessionId).isResponding;

      if (isStreaming) {
        final now = DateTime.now();
        if (_lastCtrlCPressTime != null &&
            now.difference(_lastCtrlCPressTime!).inMilliseconds < 3000 &&
            _ctrlCQuitHint) {
          // Second press within 3s — let it through so the app exits.
          _lastCtrlCPressTime = null;
          _ctrlCQuitHint = false;
          return false;
        } else {
          // First press — show warning toast, don't quit.
          _lastCtrlCPressTime = now;
          _ctrlCQuitHint = true;
          component.turnOrchestrator.showToast(
            'Agent is running. Press Ctrl+C again to quit.',
            mode: ToastMode.info,
          );
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && _ctrlCQuitHint) {
              _ctrlCQuitHint = false;
              setState(() {});
            }
          });
          setState(() {});
          return true; // consume — don't quit
        }
      }

      // No session streaming — let Ctrl+C bubble up (app exits).
      return false;
    }

    // Any other key resets the Ctrl+C quit hint.
    if (_ctrlCQuitHint) {
      _ctrlCQuitHint = false;
      _lastCtrlCPressTime = null;
      setState(() {});
    }

    final overlay = component.overlayController;
    if (overlay.showSessionManager) return true;

    // --- Ctrl+V: try clipboard image if current model supports it ---
    if (event.logicalKey == LogicalKey.keyV &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed) {
      final sessionId = component.sessionController.currentSessionId;
      if (sessionId != null && component.onAttachClipboardImage != null) {
        // Check if the current model supports images
        final modelKey = component.sessionController.currentSession.model;
        final imageKeys = component.providerServiceReady
            ? component.providerService.imageModelKeys()
            : <String>{};
        if (imageKeys.contains(modelKey)) {
          // Try reading an image from the clipboard asynchronously.
          // This is best-effort — if no image is on the clipboard,
          // the text paste falls through to the default handler.
          _tryClipboardImage(sessionId);
        }
      }
      // Don't consume the event — let the default text paste proceed.
      // If a clipboard image was found, it's handled asynchronously.
    }

    final tc = component.textController;
    final text = tc.text;
    final selection = tc.selection;
    final cursorOffset = selection.extentOffset.clamp(0, text.length);
    final inCommandMode = text.startsWith('/');

    // --- Command mode: intercept character insertion before the '/' ---
    // If we're in command mode, block any character insertion at position 0
    // (which would push text before the '/'). This includes typing, pasting,
    // and newline insertion.
    if (inCommandMode) {
      final isCharacterInput =
          event.character != null || _getCharFromKey(event.logicalKey) != null;
      final isPaste =
          event.logicalKey == LogicalKey.keyV && event.isControlPressed;
      final isModifiedEnter =
          (event.logicalKey == LogicalKey.enter ||
              event.logicalKey == LogicalKey.numpadEnter) &&
          (event.isShiftPressed ||
              event.isControlPressed ||
              event.isAltPressed);
      final isCtrlJ = event.matches(LogicalKey.keyJ, ctrl: true);

      if (isCharacterInput || isPaste || isModifiedEnter || isCtrlJ) {
        // If the selection starts at 0 (collapsed at 0, or selection covers
        // from 0), the insertion would go before the '/'. Block it.
        final selStart = selection.start.clamp(0, text.length);
        if (selStart == 0) {
          return true; // consume the event, don't insert before '/'
        }
      }
    }

    // --- Detect entering command mode: typing '/' at position 0 ---
    // When the user types '/' at position 0 (or has a selection starting at
    // 0) and the current text does NOT already start with '/', we stash the
    // existing text and replace the input with '/'.
    if (!inCommandMode &&
        (event.character == '/' || event.logicalKey == LogicalKey.slash)) {
      final selStart = selection.start.clamp(0, text.length);
      if (selStart == 0) {
        // The user is typing '/' at the beginning. If there's existing text,
        // stash it so it can be restored when the command is dismissed.
        if (text.isNotEmpty) {
          _commandStashedText = text;
        }
        // Replace the selection with '/' only (discard the rest of the text
        // since we're entering command mode).
        tc.text = '/';
        tc.selection = const TextSelection.collapsed(offset: 1);
        return true;
      }
    }

    // --- Backspace in command mode that empties the field ---
    // When the user backspaces and the result would be an empty string,
    // restore the stashed text instead of leaving the field empty.
    if (inCommandMode &&
        event.logicalKey == LogicalKey.backspace &&
        !event.isControlPressed &&
        !event.isAltPressed) {
      final selStart = selection.start.clamp(0, text.length);
      final selEnd = selection.end.clamp(0, text.length);
      final isCollapsed = selStart == selEnd;

      if (!isCollapsed && selStart == 0) {
        // Non-collapsed selection starting at position 0: this would
        // delete the '/' along with selected text. If the selection
        // covers the entire text, restore stash; otherwise, just
        // delete the selection but keep the '/'.
        if (selEnd >= text.length) {
          // Selection covers everything — restore stash.
          if (_commandStashedText != null) {
            _restoreStashedText();
          } else {
            tc.text = '';
            tc.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          // Partial selection from 0 — delete but preserve the '/'.
          tc.text = '/${text.substring(selEnd)}';
          tc.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      } else if (isCollapsed && cursorOffset == 1) {
        // Backspace at position 1 (right after '/'): this would delete the
        // '/' and leave an empty field. Restore stashed text if available.
        if (_commandStashedText != null) {
          _restoreStashedText();
        } else {
          tc.text = '';
          tc.selection = const TextSelection.collapsed(offset: 0);
        }
        return true;
      } else if (isCollapsed && cursorOffset == 0) {
        // Backspace at position 0 in command mode: nothing to delete, but
        // also don't let the default handler move cursor before '/'.
        return true;
      }
    }

    // --- Ctrl+Backspace / Alt+Backspace / Ctrl+W in command mode ---
    // These delete a word backward. If they would delete the leading '/',
    // restore stashed text instead.
    if (inCommandMode &&
        ((event.logicalKey == LogicalKey.backspace &&
                (event.isControlPressed || event.isAltPressed)) ||
            event.matches(LogicalKey.keyW, ctrl: true))) {
      // If the cursor is at or before the '/' position (offset 1) after
      // word deletion, we'd lose the '/'. Restore stash instead.
      if (cursorOffset <= 1) {
        if (_commandStashedText != null) {
          _restoreStashedText();
        } else {
          tc.text = '';
          tc.selection = const TextSelection.collapsed(offset: 0);
        }
        return true;
      }
    }

    // --- Delete key in command mode at position 0 ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.delete &&
        !event.isControlPressed &&
        !event.isAltPressed) {
      final selStart = selection.start.clamp(0, text.length);
      final selEnd = selection.end.clamp(0, text.length);
      final isCollapsed = selStart == selEnd;

      if (isCollapsed && cursorOffset == 0) {
        // Don't delete the '/' from position 0
        return true;
      } else if (!isCollapsed && selStart == 0) {
        // Non-collapsed selection starting at position 0 that includes '/'.
        if (selEnd >= text.length) {
          // Covers everything — restore stash.
          if (_commandStashedText != null) {
            _restoreStashedText();
          } else {
            tc.text = '';
            tc.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          // Partial — keep the '/'.
          tc.text = '/${text.substring(selEnd)}';
          tc.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      }
    }

    // --- Ctrl+Delete / Alt+Delete in command mode ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.delete &&
        (event.isControlPressed || event.isAltPressed)) {
      if (cursorOffset <= 0) {
        // Would delete the '/' — restore stash.
        if (_commandStashedText != null) {
          _restoreStashedText();
        } else {
          tc.text = '';
          tc.selection = const TextSelection.collapsed(offset: 0);
        }
        return true;
      }
    }

    // --- Home key in command mode: move to after the '/' ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.home &&
        !event.isControlPressed) {
      tc.selection = const TextSelection.collapsed(offset: 1);
      return true;
    }

    // --- Cut (Ctrl+X) in command mode when selection includes position 0 ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.keyX &&
        event.isControlPressed) {
      final selStart = selection.start.clamp(0, text.length);
      final selEnd = selection.end.clamp(0, text.length);
      if (!selection.isCollapsed && selStart == 0) {
        if (selEnd >= text.length) {
          // Cuts everything — restore stash.
          if (_commandStashedText != null) {
            _restoreStashedText();
          } else {
            tc.text = '';
            tc.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          // Partial cut from 0 — keep the '/'.
          tc.text = '/${text.substring(selEnd)}';
          tc.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      }
    }

    if (overlay.overlayMode == OverlayMode.off) {
      // Double-ESC interrupt logic.
      if (event.logicalKey == LogicalKey.escape) {
        final sessionId = component.sessionController.currentSessionId;
        final isStreaming =
            sessionId != null &&
            component.sessionController.runtime(sessionId).isResponding;
        if (isStreaming) {
          final now = DateTime.now();
          if (_lastEscPressTime != null &&
              now.difference(_lastEscPressTime!).inMilliseconds < 1000) {
            _lastEscPressTime = null;
            _escInterruptHint = false;
            component.turnOrchestrator.interruptResponse(
              textController: component.textController,
            );
          } else {
            _lastEscPressTime = now;
            _escInterruptHint = true;
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted && _escInterruptHint) {
                _escInterruptHint = false;
                setState(() {});
              }
            });
            setState(() {});
          }
          return true;
        }
        // ESC while in command mode (no overlay): restore stashed text,
        // or clear the command text if there's no stash.
        if (inCommandMode) {
          if (_commandStashedText != null) {
            _restoreStashedText();
          } else {
            tc.clear();
          }
          return true;
        }
        return false;
      } else {
        _lastEscPressTime = null;
        _escInterruptHint = false;
      }

      final isEnter =
          event.logicalKey == LogicalKey.enter ||
          event.logicalKey == LogicalKey.numpadEnter;
      final isModifiedEnter =
          isEnter &&
          (event.isShiftPressed ||
              event.isControlPressed ||
              event.isAltPressed);
      final isCtrlJ = event.matches(LogicalKey.keyJ, ctrl: true);

      // Send on plain Enter.
      if (isEnter && !isModifiedEnter) {
        _sendMessage();
        return true;
      }

      // Insert a literal newline on modified Enter or Ctrl+J.
      if (isModifiedEnter || isCtrlJ) {
        final newText = tc.text.replaceRange(
          selection.start,
          selection.end,
          '\n',
        );
        final newOffset = selection.start + 1;
        tc.text = newText;
        tc.selection = TextSelection.collapsed(offset: newOffset);
        return true;
      }

      if (event.logicalKey == LogicalKey.pageUp &&
          (event.isControlPressed || event.isAltPressed)) {
        _jumpToPreviousUserInput();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown &&
          (event.isControlPressed || event.isAltPressed)) {
        _jumpToNextUserInput();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageUp) {
        component.scrollController.pageUp();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown) {
        component.scrollController.pageDown();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowUp && event.isControlPressed) {
        component.scrollController.scrollUp(
          component.scrollController.viewportDimension / 2,
        );
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown && event.isControlPressed) {
        component.scrollController.scrollDown(
          component.scrollController.viewportDimension / 2,
        );
        return true;
      }
      if (event.logicalKey == LogicalKey.home && event.isControlPressed) {
        component.scrollController.scrollToStart();
        return true;
      }
      if (event.logicalKey == LogicalKey.end && event.isControlPressed) {
        component.scrollController.scrollToBottom();
        return true;
      }
      return false;
    }

    if (overlay.overlayMode == OverlayMode.command) {
      if (overlay.filteredCommands.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlay.moveCommandSelectionUp();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlay.moveCommandSelectionDown();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlay.onTapCommand(overlay.selectedCommandIndex);
        // Note: stash restoration is handled by _executeCommand (via
        // executeCommandCallback) when the command is fully executed.
        // For commands with params, onTapCommand just sets the text
        // and the stash is preserved until the command completes.
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        // ESC dismisses command overlay — restore stashed text if any,
        // otherwise clear the command text.
        if (_commandStashedText != null) {
          _restoreStashedText();
        } else {
          tc.clear();
        }
        overlay.setOverlayOff();
        component.refresh();
        return true;
      }
      return false;
    }

    if (overlay.overlayMode == OverlayMode.parameter) {
      if (overlay.filteredSuggestions.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlay.moveSuggestionSelectionUp();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlay.moveSuggestionSelectionDown();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlay.onTapSuggestion(overlay.selectedSuggestionIndex);
        // Note: stash restoration is handled by _executeCommand (via
        // executeCommandCallback) when the command is fully executed.
        // For multi-param commands, onTapSuggestion just appends the
        // value and the stash is preserved.
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        // ESC dismisses parameter overlay — restore stashed text if any,
        // otherwise clear the command text.
        if (_commandStashedText != null) {
          _restoreStashedText();
        } else {
          tc.clear();
        }
        overlay.setOverlayOff();
        component.refresh();
        return true;
      }
      return false;
    }

    if (overlay.overlayMode == OverlayMode.atMention) {
      // Empty result set: only Enter and Esc do anything useful;
      // arrow keys are no-ops. The popover shows "no matches" so
      // the user knows their query is the problem.
      if (overlay.filteredFiles.isEmpty) {
        if (event.logicalKey == LogicalKey.escape) {
          overlay.setOverlayOff();
          component.refresh();
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          // Dismiss the popover so the user can press Enter to
          // actually send their message (the @-query stays in
          // the input — it was meant as a search term, not a
          // literal).
          overlay.setOverlayOff();
          component.refresh();
          return true;
        }
        return false;
      }

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlay.moveFileSelectionUp();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlay.moveFileSelectionDown();
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowRight) {
        // Right-arrow drills into the highlighted directory: if
        // the current selection is a directory, treat it as if the
        // user had just typed `@<path>/` and re-run the file
        // browser with that as the new query. This matches the
        // "open the folder" muscle memory from GUI file pickers.
        final selected = overlay.selectedFile;
        if (selected != null && selected.isDirectory) {
          final mention = _findActiveMention();
          if (mention != null) {
            // The relative path for a directory already ends with
            // a separator (see FileSearcher._walk) — strip it so
            // the re-built query has exactly one trailing `/`.
            final path = selected.relativePath;
            final stripped = path.endsWith('/')
                ? path.substring(0, path.length - 1)
                : path;
            final newQuery = '$stripped/';
            final tc = component.textController;
            final text = tc.text;
            final newText = text.replaceRange(
              mention.atOffset,
              mention.cursor,
              '@$newQuery',
            );
            tc.text = newText;
            tc.selection = TextSelection.collapsed(
              offset: mention.atOffset + 1 + newQuery.length,
            );
            // _onTextChanged will fire from the textController
            // listener, refresh the file list, and re-show the
            // popover automatically.
            return true;
          }
        }
        return false;
      }
      if (event.logicalKey == LogicalKey.tab) {
        // Tab → also accept the current selection (matches the
        // file-picker muscle memory from GUI IDEs).
        final mention = _findActiveMention();
        overlay.insertAtMention(mention?.atOffset);
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        final mention = _findActiveMention();
        overlay.insertAtMention(mention?.atOffset);
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        // ESC dismisses the file browser but leaves the `@<query>`
        // fragment in the input untouched. The user can keep
        // typing, or backspace to remove it.
        overlay.setOverlayOff();
        component.refresh();
        return true;
      }
      return false;
    }

    return false;
  }

  /// Map a logical key to its character, only for the '/' key.
  /// Used to detect '/' key press before the TextField processes it.
  String? _getCharFromKey(LogicalKey key) {
    if (key == LogicalKey.slash) return '/';
    return null;
  }

  /// Insert an `[ image N ]` text marker at the current cursor
  /// position. The [index] is the 1-based position in the pending
  /// image list. A space is added after the marker so the user can
  /// type their message right after it. Used to give the user
  /// visible feedback in the input box that an image is attached
  /// (mirroring how opencode renders inline markers in its prompt
  /// input).
  void insertImageMarker(int index) {
    final tc = component.textController;
    final text = tc.text;
    final selection = tc.selection;
    final cursor = selection.extentOffset.clamp(0, text.length);
    final marker = '[ image $index ] ';
    final newText = text.replaceRange(cursor, cursor, marker);
    tc.text = newText;
    tc.selection = TextSelection.collapsed(offset: cursor + marker.length);
    setState(() {});
  }

  /// Attempt to read an image from the system clipboard and add it as
  /// a pending attachment. Called on Ctrl+V when the current model
  /// supports images. This is best-effort — if no image is on the
  /// clipboard, nothing happens (the text paste proceeds normally).
  Future<bool> _tryClipboardImage(
    int sessionId, {
    bool showEmptyToast = false,
  }) async {
    try {
      final result = await ClipboardImageReader.readImage();
      if (result != null) {
        final image = ImageAttachment.fromBytes(
          bytes: result.bytes,
          mediaType: result.mediaType,
          label: result.label,
        );
        component.onAttachClipboardImage?.call(image);
        final sizeKB = (result.bytes.length / 1024).toStringAsFixed(0);
        component.turnOrchestrator.showToast(
          '📎 Clipboard image attached ($sizeKB KB). '
          'Type your message and press Enter to send.',
          mode: ToastMode.status,
        );
        setState(() {});
        return true;
      } else if (showEmptyToast) {
        component.turnOrchestrator.showToast(
          'Clipboard is empty or unavailable',
          mode: ToastMode.error,
        );
      }
    } catch (e) {
      // Ctrl+V keeps this silent so ordinary text paste can proceed.
      if (showEmptyToast) {
        component.turnOrchestrator.showToast(
          'Failed to read clipboard: $e',
          mode: ToastMode.error,
        );
      }
    }
    return false;
  }

  Future<void> _pasteFromButton(int? sessionId) async {
    if (sessionId != null && _currentModelSupportsImages()) {
      final attached = await _tryClipboardImage(sessionId);
      if (attached) return;
    }

    final text =
        await ClipboardTextReader.readText() ?? ClipboardManager.paste();
    if (text != null && text.isNotEmpty) {
      _pasteText(text, sessionId);
      return;
    }

    component.turnOrchestrator.showToast(
      'Clipboard is empty or unavailable',
      mode: ToastMode.error,
    );
  }

  void _pasteText(String clipboardText, int? sessionId) {
    final normalized = clipboardText
        .replaceAll(RegExp(r'\r\n'), '\n')
        .replaceAll(RegExp(r'\r'), '\n');
    final handled = _handlePaste(normalized, sessionId);
    if (handled) return;

    final tc = component.textController;
    final text = tc.text;
    final selection = tc.selection;
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final replaceStart = start < end ? start : end;
    final replaceEnd = start < end ? end : start;
    final newText = text.replaceRange(replaceStart, replaceEnd, normalized);
    tc.text = newText;
    tc.selection = TextSelection.collapsed(
      offset: replaceStart + normalized.length,
    );
    setState(() {});
  }

  bool _currentModelSupportsImages() {
    if (component.onAttachClipboardImage == null) return false;
    if (!component.providerServiceReady) return false;
    final modelKey = component.sessionController.currentSession.model;
    return component.providerService.imageModelKeys().contains(modelKey);
  }

  void _syncPendingImagesWithMarkers() {
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId == null) return;

    final pending = component.sessionController.pendingImagesFor(sessionId);
    if (pending.isEmpty) return;

    final text = component.textController.text;
    final matches = _imageMarkerPattern.allMatches(text).toList();
    final visibleIndexes = <int>{};
    for (final match in matches) {
      final index = int.tryParse(match.group(1) ?? '');
      if (index != null && index >= 1 && index <= pending.length) {
        visibleIndexes.add(index);
      }
    }

    if (visibleIndexes.length == pending.length) return;

    final keptImages = <ImageAttachment>[];
    final renumber = <int, int>{};
    for (var i = 0; i < pending.length; i++) {
      final oldIndex = i + 1;
      if (visibleIndexes.contains(oldIndex)) {
        renumber[oldIndex] = keptImages.length + 1;
        keptImages.add(pending[i]);
      }
    }

    component.sessionController.setPendingImages(sessionId, keptImages);

    var adjustedText = text.replaceAllMapped(_imageMarkerPattern, (match) {
      final oldIndex = int.tryParse(match.group(1) ?? '');
      final newIndex = oldIndex == null ? null : renumber[oldIndex];
      return newIndex == null ? '' : '[ image $newIndex ]';
    });

    if (adjustedText != text) {
      final oldCursor = component.textController.selection.extentOffset;
      _syncingImageMarkers = true;
      component.textController.text = adjustedText;
      component.textController.selection = TextSelection.collapsed(
        offset: oldCursor.clamp(0, adjustedText.length),
      );
      _syncingImageMarkers = false;
    }

    component.refresh();
  }

  /// Handle text pasted into the input. This is the single entry
  /// point for everything that arrives via bracketed paste mode,
  /// which includes both ordinary copy-pasted text *and* files
  /// dragged onto the terminal window (the terminal emits the
  /// file's absolute path as a bracketed-paste payload).
  ///
  /// Routing:
  ///   1. Tokenize the payload; if any token resolves to a real
  ///      file on disk, route the whole batch through
  ///      [_processDroppedFiles] and return `true` (consume).
  ///   2. Otherwise fall back to the legacy single-image path
  ///      (so an old `/path/to/image.png` paste that the new
  ///      classifier rejected — e.g. on a non-image-supporting
  ///      model — still gets the right behavior).
  ///   3. Otherwise return `false` to let the TextField insert
  ///      the raw text normally.
  bool _handlePaste(String pastedText, int? sessionId) {
    if (sessionId == null) return false;
    final trimmed = pastedText.trim();
    if (trimmed.isEmpty) return false;

    // ── 1) Drag-and-drop routing ───────────────────────────────
    // Bracketed-paste payloads from a file drop usually contain
    // one or more absolute paths. Tokenize on whitespace, resolve
    // each token against the project root, and require that
    // *every* token resolves to a real file or directory before
    // taking over the paste. Real terminal-emulator drops have
    // a characteristic shape where every token is a path; this
    // guard keeps us from misreading a sentence that merely
    // *mentions* a path (e.g. "see /tmp/photo.png for context")
    // as a file drop. See [looksLikeFileDrop].
    final candidates = extractDroppedPaths(trimmed);
    if (candidates.isNotEmpty) {
      final classified = classifyDroppedPaths(
        candidates,
        projectRoot: component.projectPath,
      );
      if (looksLikeFileDrop(classified)) {
        _processDroppedFiles(classified, sessionId);
        return true;
      }
    }

    // ── 2) Legacy single-image path ────────────────────────────
    // Preserved verbatim (modulo the new docstring) for the case
    // where the classifier above saw nothing to act on, but the
    // single-token payload is still a path to an image file that
    // the current model can attach.
    if (!_currentModelSupportsImages()) return false;

    var candidate = trimmed;
    if (candidate.startsWith("'") && candidate.endsWith("'") ||
        candidate.startsWith('"') && candidate.endsWith('"')) {
      candidate = candidate.substring(1, candidate.length - 1);
    }
    if (candidate.startsWith('file://')) {
      candidate = candidate.substring('file://'.length);
    }

    if (!_looksLikeImagePath(candidate)) return false;
    final file = File(candidate);
    if (!file.existsSync()) return false;

    _tryAttachImageFile(file, sessionId);
    return true;
  }

  /// Apply the side-effects for a batch of classified dropped
  /// files. Splits the work across:
  ///
  ///   * image attachments (via [_tryAttachImageFile], which
  ///     already shows a per-file toast and inserts an
  ///     `[ image N ]` marker at the cursor);
  ///   * an aggregated text insertion (via
  ///     [formatDroppedFilesForInput]) that puts file content /
  ///     path references / directory listings into the input
  ///     box at the current cursor position;
  ///   * a summary toast, plus an error toast for any missing
  ///     paths.
  ///
  /// Callers should `return true` from [_handlePaste] immediately
  /// after calling this — we have consumed the paste and the
  /// default text insertion must NOT run.
  void _processDroppedFiles(List<DroppedFile> files, int sessionId) {
    final tc = component.textController;
    final text = tc.text;
    final selection = tc.selection;
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final replaceStart = start < end ? start : end;
    final replaceEnd = start < end ? end : start;

    final supportsImages = _currentModelSupportsImages();
    var imageCount = 0;
    var inlinedCount = 0;
    var refCount = 0;
    final missingNames = <String>[];

    for (final f in files) {
      switch (f.kind) {
        case DroppedFileKind.image:
          if (supportsImages) {
            // The image attach path is async and shows its own
            // per-file toast (filename + size), so we don't
            // double-toast for images.
            _tryAttachImageFile(File(f.absolutePath), sessionId);
            imageCount++;
          } else {
            // No image support on this model: fall through and
            // treat the path as a plain file reference so the
            // user still sees something useful in the input.
            refCount++;
          }
          break;
        case DroppedFileKind.inlineableText:
          inlinedCount++;
          break;
        case DroppedFileKind.largeOrBinary:
        case DroppedFileKind.directory:
          refCount++;
          break;
        case DroppedFileKind.missing:
          missingNames.add(p.basename(f.originalPath));
          break;
      }
    }

    // Build the text that goes into the input box. This is
    // everything that wasn't an image (or that was an image the
    // model can't handle), minus the missing ones. Images that
    // were successfully attached are *not* inserted as text —
    // the user gets an `[ image N ]` marker from
    // [_tryAttachImageFile] instead.
    final textPortion = formatDroppedFilesForInput(
      files
          .where((f) => f.kind != DroppedFileKind.missing)
          .where((f) => !(f.kind == DroppedFileKind.image && supportsImages))
          .toList(),
    );

    if (textPortion.isNotEmpty) {
      final newText = text.replaceRange(replaceStart, replaceEnd, textPortion);
      tc.text = newText;
      tc.selection = TextSelection.collapsed(
        offset: replaceStart + textPortion.length,
      );
    }

    // One error toast for any missing files. The summary toast
    // below only fires if at least one *non-image* file was
    // processed — otherwise the per-image toasts from
    // [_tryAttachImageFile] are already plenty.
    if (missingNames.isNotEmpty) {
      component.turnOrchestrator.showToast(
        '⚠️ File(s) not found: ${missingNames.join(', ')}',
        mode: ToastMode.error,
      );
    }
    if (inlinedCount > 0 || refCount > 0) {
      final parts = <String>[];
      if (imageCount > 0) parts.add('$imageCount image(s) attached');
      if (inlinedCount > 0) parts.add('$inlinedCount file(s) inlined');
      if (refCount > 0) parts.add('$refCount path(s) inserted');
      component.turnOrchestrator.showToast(
        '📎 Dropped: ${parts.join(', ')}',
        mode: ToastMode.status,
      );
    }

    setState(() {});
  }

  /// Heuristic: does this path look like an image file? Checks the
  /// extension against [ImageAttachment.extensionMediaTypes]. Cheap
  /// to run, safe to call on every paste.
  bool _looksLikeImagePath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) return false;
    final ext = path.substring(dot + 1).toLowerCase();
    return ImageAttachment.isImageExtension(ext);
  }

  /// Load [file] as an image, attach it as a pending image, and
  /// insert an `[ image N ]` marker at the cursor. Runs as a
  /// fire-and-forget Future; surfaces errors as toasts.
  Future<void> _tryAttachImageFile(File file, int sessionId) async {
    try {
      final image = await ImageAttachment.fromFile(file.path);
      component.onAttachClipboardImage?.call(image);
      final sizeKB = (file.lengthSync() / 1024).toStringAsFixed(0);
      component.turnOrchestrator.showToast(
        '📎 Attached: ${image.label} ($sizeKB KB). '
        'Type your message and press Enter to send.',
        mode: ToastMode.status,
      );
    } catch (e) {
      component.turnOrchestrator.showToast(
        'Failed to attach image: $e',
        mode: ToastMode.error,
      );
    }
  }

  void _sendMessage() {
    final text = component.textController.text.trim();
    if (text.isEmpty) return;

    final sessionId = component.sessionController.currentSessionId;
    final isResponding =
        sessionId != null &&
        component.sessionController.runtime(sessionId).isResponding;

    if (text.startsWith('/')) {
      final cmd = findCommand(text.split(' ').first);
      if (isResponding && (cmd == null || !cmd.availableDuringResponse)) {
        return;
      }
      component.textController.clear();
      // onExecuteCommand → _executeCommand → restoreCommandStash()
      // handles restoring the stashed message.
      component.onExecuteCommand(text);
      return;
    }

    // Non-command message sent — clear any stale stash (there shouldn't
    // be one since we weren't in command mode, but just in case).
    _commandStashedText = null;
    component.onSendTurn(text);
  }

  void _jumpToPreviousUserInput() {
    final messages = component.sessionController.currentMessages;
    final userIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') userIndices.add(i);
    }
    if (userIndices.isEmpty) return;

    final avgHeight =
        component.scrollController.maxScrollExtent > 0 && messages.isNotEmpty
        ? component.scrollController.maxScrollExtent / messages.length
        : 3.0;

    final currentOffset = component.scrollController.offset;
    int? targetMsgIndex;
    for (final idx in userIndices.reversed) {
      final estOffset = idx * avgHeight;
      if (estOffset < currentOffset - 1) {
        targetMsgIndex = idx;
        break;
      }
    }

    if (targetMsgIndex != null) {
      component.scrollController.jumpTo(
        (targetMsgIndex * avgHeight).clamp(
          component.scrollController.minScrollExtent,
          component.scrollController.maxScrollExtent,
        ),
      );
    }
  }

  void _jumpToNextUserInput() {
    final messages = component.sessionController.currentMessages;
    final userIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') userIndices.add(i);
    }
    if (userIndices.isEmpty) return;

    final avgHeight =
        component.scrollController.maxScrollExtent > 0 && messages.isNotEmpty
        ? component.scrollController.maxScrollExtent / messages.length
        : 3.0;

    final currentOffset = component.scrollController.offset;
    int? targetMsgIndex;
    for (final idx in userIndices) {
      final estOffset = idx * avgHeight;
      if (estOffset > currentOffset + 1) {
        targetMsgIndex = idx;
        break;
      }
    }

    if (targetMsgIndex != null) {
      component.scrollController.jumpTo(
        (targetMsgIndex * avgHeight).clamp(
          component.scrollController.minScrollExtent,
          component.scrollController.maxScrollExtent,
        ),
      );
    }
  }

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'chatInput.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    final sessionId = component.sessionController.currentSessionId;
    final rt = sessionId != null
        ? component.sessionController.runtime(sessionId)
        : null;
    final isStreaming = rt?.isResponding ?? false;
    final wasInterrupted = component.turnOrchestrator.wasInterrupted(sessionId);

    // Check for pending image attachments.
    final pendingImages = sessionId != null
        ? component.sessionController.pendingImagesFor(sessionId)
        : <ImageAttachment>[];
    final hasImages = pendingImages.isNotEmpty;

    final overlay = component.overlayController;
    final placeholder = isStreaming
        ? _ctrlCQuitHint
              ? 'Press Ctrl+C again to quit...'
              : _escInterruptHint
              ? 'Press ESC again to interrupt...'
              : 'Enter message to queue, ESC×2 to interrupt, Ctrl+C×2 to quit'
        : wasInterrupted
        ? 'Response was interrupted. Type a new message...'
        : hasImages
        ? 'Type message to send with ${pendingImages.length} image(s)...'
        : 'Type a message...';

    return Container(
      padding: EdgeInsets.all(1),
      child: Row(
        children: [
          Text(
            '> ',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
          if (hasImages)
            Text(
              '📎${pendingImages.length} ',
              style: TextStyle(color: CruxTheme.of(context).metricsActive),
            ),
          Expanded(
            child: TextField(
              controller: component.textController,
              focused: !overlay.showSessionManager,
              maxLines: null,
              style: TextStyle(color: CruxTheme.of(context).foreground),
              placeholder: placeholder,
              onKeyEvent: _handleKeyEvent,
              onPaste: (pastedText) => _handlePaste(pastedText, sessionId),
              wordBoundaryProvider: cjkWordBoundaryProvider,
            ),
          ),
          Button(
            label: 'paste',
            onPressed: () => _pasteFromButton(sessionId),
            color: CruxTheme.of(context).onSurfaceDim,
            hoverColor: CruxTheme.of(context).buttonTextHover,
            bgColor: CruxTheme.of(context).buttonBackground,
            hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          ),
        ],
      ),
    );
  }
}

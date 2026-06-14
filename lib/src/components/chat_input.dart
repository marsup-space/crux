import 'dart:io';

import 'package:nocterm/nocterm.dart';
import '../models/image_attachment.dart';
import '../models/slash_command.dart';
import '../services/provider_service.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/clipboard_image.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/file_searcher.dart';
import '../commands/registry.dart';
import 'chat_turn_orchestrator.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
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
  });

  @override
  State<ChatInput> createState() => ChatInputState();
}

/// Public state for [ChatInput], exposed via [GlobalKey] so that parent
/// widgets can call [stashAndSetCommand].
/// Bounds the cached state of an active @-mention. Found by
/// [ChatInputState._findActiveMention] on every text change and
/// passed to [_showAtMention] / [OverlayController.insertAtMention]
/// so the popover knows both *which* `@` is active and *what* the
/// user has typed so far.
class _AtMention {
  /// Offset of the `@` in the text.
  final int atOffset;

  /// Offset where the query begins (== atOffset + 1). Convenience
  /// field — the code that uses [_AtMention] only needs one or the
  /// other depending on context.
  final int queryStart;

  /// Current cursor position (== end of query).
  final int cursor;

  /// Text between the `@` and the cursor.
  final String query;

  const _AtMention({
    required this.atOffset,
    required this.queryStart,
    required this.cursor,
    required this.query,
  });
}

class ChatInputState extends State<ChatInput> {
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

  /// Text that was in the input box before the user entered command mode
  /// (by typing '/' as the first character or by pressing a toolbar button
  /// that places a '/' command in the box). This text is restored when the
  /// user deletes all characters while in command mode, giving them back
  /// their work-in-progress message.
  String? _commandStashedText;

  /// Public read-only access to the command-stashed text. Used by
  /// ChatPanel when switching sessions to preserve the user's message
  /// that was hidden behind a '/' command.
  String? get commandStashedText => _commandStashedText;

  @override
  void initState() {
    super.initState();
    component.textController.addListener(_onTextChanged);
    CommandRegistry.instance.addListener(component.refresh);
  }

  @override
  void dispose() {
    component.textController.removeListener(_onTextChanged);
    CommandRegistry.instance.removeListener(component.refresh);
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

  void _onTextChanged() {
    final text = component.textController.text;
    final overlay = component.overlayController;

    // First, check for an @-mention trigger. The `@` doesn't have
    // to be at offset 0 — it can appear anywhere in the text. We
    // look for the last `@` at or before the cursor that's preceded
    // by a non-identifier char (so emails don't trigger).
    final mention = _findActiveMention();
    if (mention != null) {
      _showAtMention(mention);
      component.refresh();
      return;
    }

    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      overlay.setOverlayOff();
      component.refresh();
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
      component.refresh();
      return;
    }

    final commandName = trimmed.substring(0, spaceIndex);
    final command = findCommand(commandName);

    if (command == null ||
        (!command.hasSuggestionsForParam(0) &&
            commandName != '/model' &&
            commandName != '/auxiliary' &&
            commandName != '/provider' &&
            commandName != '/theme')) {
      overlay.setOverlayOff();
      component.refresh();
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
        !(commandName == '/theme' && paramIndex == 0)) {
      overlay.setOverlayOff();
      component.refresh();
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
                  (e) => component.providerService.getApiKey(e.providerName) != null)
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
            .where((e) =>
                component.providerService.getApiKey(e.providerName) != null)
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

  // ─────────────────────────────────────────────────────────────────────
  // @-mention detection
  // ─────────────────────────────────────────────────────────────────────

  /// Scan the input text for an active `@<query>` fragment ending at
  /// the current cursor. Returns `null` if there is no mention the
  /// user is currently editing (e.g. they backspaced out of it, or
  /// they typed whitespace inside the query, or there is no `@`).
  ///
  /// "Active" means: there's an `@` somewhere at or before the
  /// cursor, no whitespace/closing-punctuation between it and the
  /// cursor, and the char before the `@` is either nothing or a
  /// non-identifier char (so `foo@bar` doesn't trigger).
  _AtMention? _findActiveMention() {
    final tc = component.textController;
    final text = tc.text;
    final cursor = tc.selection.extentOffset.clamp(0, text.length);

    // Walk backwards from the cursor looking for an `@` that is
    // the start of an in-progress mention. Stop at whitespace or
    // closing punctuation (which terminates the query).
    var atOffset = -1;
    for (var i = cursor - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == '@') {
        atOffset = i;
        break;
      }
      // Whitespace, comma, semicolon, paren, bracket, brace all
      // end the query — no mention here.
      final cc = ch.codeUnitAt(0);
      if (cc == 0x20 || cc == 0x09 || cc == 0x0A || // space, tab, newline
          cc == 0x28 || cc == 0x29 ||                 // ( )
          cc == 0x5B || cc == 0x5D ||                 // [ ]
          cc == 0x7B || cc == 0x7D ||                 // { }
          cc == 0x2C || cc == 0x3B) {                 // , ;
        return null;
      }
    }
    if (atOffset < 0) return null;

    // Reject email-style mentions: the char immediately before the
    // `@` must not be an identifier char (A–Z, a–z, 0–9, _, -).
    if (atOffset > 0) {
      final prev = text[atOffset - 1];
      final pc = prev.codeUnitAt(0);
      final isIdent = (pc >= 0x30 && pc <= 0x39) ||
          (pc >= 0x41 && pc <= 0x5A) ||
          (pc >= 0x61 && pc <= 0x7A) ||
          pc == 0x5F || // _
          pc == 0x2D;  // -
      if (isIdent) return null;
    }

    final query = text.substring(atOffset + 1, cursor);
    return _AtMention(
      atOffset: atOffset,
      queryStart: atOffset + 1,
      cursor: cursor,
      query: query,
    );
  }

  /// Open (or refresh) the @-mention file browser with the matches
  /// for [mention.query]. If the popover is already open for a
  /// different query (e.g. user kept typing), preserve the
  /// selection across the search so arrow-key navigation isn't
  /// reset on every keystroke.
  void _showAtMention(_AtMention mention) {
    final overlay = component.overlayController;
    // If the popover is already in atMention mode and the user is
    // just refining the same query (extending it), keep their
    // selected index. Only reset when the atOffset moved (i.e. a
    // different `@` is now active — a stale result from a prior
    // mention shouldn't follow the cursor).
    final stayingOnSameAt = overlay.overlayMode == OverlayMode.atMention &&
        overlay.atMentionQuery.length <= mention.query.length;
    if (!stayingOnSameAt) {
      overlay.selectedFileIndex = 0;
      overlay.fileScrollOffset = 0;
    }

    overlay.overlayMode = OverlayMode.atMention;
    overlay.atMentionQuery = mention.query;
    overlay.filteredFiles = _fileSearcher.search(mention.query);
  }

  bool _handleKeyEvent(KeyboardEvent event) {
    // --- Ctrl+C double-press-to-quit guard ---
    // When any session is currently streaming/responding, the first Ctrl+C
    // shows a toast warning instead of quitting. A second Ctrl+C within
    // 3 seconds (while the toast is active) really quits. When no session
    // is streaming, Ctrl+C passes through and quits immediately (the
    // default TerminalBinding.immediateExit behaviour).
    if (event.logicalKey == LogicalKey.keyC && event.isControlPressed &&
        !event.isShiftPressed && !event.isAltPressed && !event.isMetaPressed) {
      final sessionId = component.sessionController.currentSessionId;
      final isStreaming = sessionId != null &&
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
    if (event.logicalKey == LogicalKey.keyV && event.isControlPressed &&
        !event.isShiftPressed && !event.isAltPressed) {
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
      final isCharacterInput = event.character != null ||
          _getCharFromKey(event.logicalKey) != null;
      final isPaste = event.logicalKey == LogicalKey.keyV && event.isControlPressed;
      final isModifiedEnter = (event.logicalKey == LogicalKey.enter ||
              event.logicalKey == LogicalKey.numpadEnter) &&
          (event.isShiftPressed || event.isControlPressed || event.isAltPressed);
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
    if (!inCommandMode && (event.character == '/' || event.logicalKey == LogicalKey.slash)) {
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
    if (inCommandMode && event.logicalKey == LogicalKey.backspace && !event.isControlPressed && !event.isAltPressed) {
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
        ((event.logicalKey == LogicalKey.backspace && (event.isControlPressed || event.isAltPressed)) ||
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
    if (inCommandMode && event.logicalKey == LogicalKey.delete && !event.isControlPressed && !event.isAltPressed) {
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
    if (inCommandMode && event.logicalKey == LogicalKey.home && !event.isControlPressed) {
      tc.selection = const TextSelection.collapsed(offset: 1);
      return true;
    }

    // --- Cut (Ctrl+X) in command mode when selection includes position 0 ---
    if (inCommandMode && event.logicalKey == LogicalKey.keyX && event.isControlPressed) {
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
        final isStreaming = sessionId != null &&
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

      final isEnter = event.logicalKey == LogicalKey.enter ||
          event.logicalKey == LogicalKey.numpadEnter;
      final isModifiedEnter = isEnter &&
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
        component.scrollController
            .scrollUp(component.scrollController.viewportDimension / 2);
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown && event.isControlPressed) {
        component.scrollController
            .scrollDown(component.scrollController.viewportDimension / 2);
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
            final stripped = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
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
  Future<void> _tryClipboardImage(int sessionId) async {
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
      }
    } catch (_) {
      // Clipboard image reading failed — ignore silently.
      // The text paste from the default handler will proceed.
    }
  }

  /// Handle text pasted into the input. If the pasted text is a path
  /// to a supported image file, attach it as a pending image and
  /// return `true` to skip the default text insertion (so the user
  /// doesn't see the raw path — they get an `[ image N ]` marker
  /// instead). Otherwise return `false` to fall through to the
  /// default paste behavior.
  bool _handlePaste(String pastedText, int? sessionId) {
    if (sessionId == null) return false;
    final trimmed = pastedText.trim();
    if (trimmed.isEmpty) return false;

    // Only act if the model supports images.
    if (component.onAttachClipboardImage == null) return false;
    if (!component.providerServiceReady) return false;
    final modelKey = component.sessionController.currentSession.model;
    final imageKeys = component.providerService.imageModelKeys();
    if (!imageKeys.contains(modelKey)) return false;

    // Strip surrounding quotes and a leading "file://" prefix that
    // some file managers include when copying a file as a URI.
    var candidate = trimmed;
    if (candidate.startsWith("'") && candidate.endsWith("'") ||
        candidate.startsWith('"') && candidate.endsWith('"')) {
      candidate = candidate.substring(1, candidate.length - 1);
    }
    if (candidate.startsWith('file://')) {
      candidate = candidate.substring('file://'.length);
    }

    // Check the file exists and has a supported image extension.
    if (!_looksLikeImagePath(candidate)) return false;
    final file = File(candidate);
    if (!file.existsSync()) return false;

    // Try to load and attach the image asynchronously. We *consume*
    // the paste (return true) so the user doesn't see the raw path
    // appear in the input — instead they'll see the `[ image N ]`
    // marker that gets inserted.
    _tryAttachImageFile(file, sessionId);
    return true;
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
    final isResponding = sessionId != null &&
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
    final sessionId = component.sessionController.currentSessionId;
    final rt = sessionId != null
        ? component.sessionController.runtime(sessionId)
        : null;
    final isStreaming = rt?.isResponding ?? false;
    final wasInterrupted =
        component.turnOrchestrator.wasInterrupted(sessionId);

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
        ],
      ),
    );
  }
}

import 'package:nocterm/nocterm.dart';

import '../utils/at_mention_parser.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'chat_turn_orchestrator.dart';
import 'ui/toast.dart';

/// Handles all keyboard events for the chat input.
///
/// Extracted from `ChatInputState` so the 620-line `_handleKeyEvent` method
/// lives in its own class with explicit dependencies, rather than being one
/// of seven responsibilities on the god state.
///
/// Owns its own state for ESC/Ctrl+C hint flags and timestamps. Calls
/// [onStateChanged] when those flags change so the input can rebuild.
class InputKeyHandler {
  final SessionController sessionController;
  final ChatTurnOrchestrator turnOrchestrator;
  final VoidCallback? onQuitRequest;
  final VoidCallback refresh;
  final void Function() onStateChanged;
  final TextEditingController textController;
  final OverlayController overlayController;
  final AutoScrollController scrollController;

  // Shared state accessor (owned by ChatInputState)
  final String? Function() getCommandStash;
  final void Function(String?) setCommandStash;

  // Own state
  DateTime? _lastEscPressTime;
  bool _escInterruptHint = false;
  DateTime? _lastCtrlCPressTime;
  bool _ctrlCQuitHint = false;

  InputKeyHandler({
    required this.sessionController,
    required this.turnOrchestrator,
    required this.onQuitRequest,
    required this.refresh,
    required this.onStateChanged,
    required this.textController,
    required this.overlayController,
    required this.scrollController,
    required this.getCommandStash,
    required this.setCommandStash,
  });

  bool get escInterruptHint => _escInterruptHint;
  bool get ctrlCQuitHint => _ctrlCQuitHint;

  /// Map a logical key to its character, only for the '/' key.
  static String? getCharFromKey(LogicalKey key) {
    if (key == LogicalKey.slash) return '/';
    return null;
  }

  bool handleKeyEvent(KeyboardEvent event) {
    // --- Ctrl+C quit handler ---
    if (event.logicalKey == LogicalKey.keyC &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed &&
        !event.isMetaPressed) {
      final anyRunning = sessionController.hasAnyRunningSession;

      if (anyRunning) {
        final now = DateTime.now();
        if (_lastCtrlCPressTime != null &&
            now.difference(_lastCtrlCPressTime!).inMilliseconds < 3000 &&
            _ctrlCQuitHint) {
          _lastCtrlCPressTime = null;
          _ctrlCQuitHint = false;
          onQuitRequest?.call();
          return true;
        } else {
          _lastCtrlCPressTime = now;
          _ctrlCQuitHint = true;
          turnOrchestrator.showToast(
            'A session is running. Press Ctrl+C again to quit.',
            mode: ToastMode.info,
          );
          Future.delayed(const Duration(seconds: 3), () {
            if (_ctrlCQuitHint) {
              _ctrlCQuitHint = false;
              onStateChanged();
            }
          });
          onStateChanged();
          return true;
        }
      }

      onQuitRequest?.call();
      return true;
    }

    // Any other key resets the Ctrl+C quit hint.
    if (_ctrlCQuitHint) {
      _ctrlCQuitHint = false;
      _lastCtrlCPressTime = null;
      onStateChanged();
    }

    if (overlayController.showSessionManager) return true;

    // --- Ctrl+V: try clipboard image if current model supports it ---
    if (event.logicalKey == LogicalKey.keyV &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed) {
      if (!NoctermBinding.instance.hasPendingPasteText) {
        final sessionId = sessionController.currentSessionId;
        // The actual image-attach logic lives in InputPaste; this just
        // delegates. The callback is wired by ChatInputState.
        tryClipboardImage?.call(sessionId ?? -1, showEmptyToast: false);
      }
    }

    final text = textController.text;
    final selection = textController.selection;
    final cursorOffset = selection.extentOffset.clamp(0, text.length);
    final inCommandMode = text.startsWith('/');

    // --- Command mode: intercept character insertion before the '/' ---
    if (inCommandMode) {
      final isCharacterInput =
          event.character != null || getCharFromKey(event.logicalKey) != null;
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
        final selStart = selection.start.clamp(0, text.length);
        if (selStart == 0) {
          return true;
        }
      }
    }

    // --- Detect entering command mode: typing '/' at position 0 ---
    if (!inCommandMode &&
        (event.character == '/' || event.logicalKey == LogicalKey.slash)) {
      final selStart = selection.start.clamp(0, text.length);
      if (selStart == 0) {
        if (text.isNotEmpty) {
          setCommandStash(text);
        }
        textController.text = '/';
        textController.selection = const TextSelection.collapsed(offset: 1);
        return true;
      }
    }

    // --- Backspace in command mode that empties the field ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.backspace &&
        !event.isControlPressed &&
        !event.isAltPressed) {
      final selStart = selection.start.clamp(0, text.length);
      final selEnd = selection.end.clamp(0, text.length);
      final isCollapsed = selStart == selEnd;

      if (!isCollapsed && selStart == 0) {
        if (selEnd >= text.length) {
          final stash = getCommandStash();
          if (stash != null) {
            _restoreStashedText();
          } else {
            textController.text = '';
            textController.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          textController.text = '/${text.substring(selEnd)}';
          textController.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      } else if (isCollapsed && cursorOffset == 1) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        } else {
          textController.text = '';
          textController.selection = const TextSelection.collapsed(offset: 0);
        }
        return true;
      } else if (isCollapsed && cursorOffset == 0) {
        return true;
      }
    }

    // --- Ctrl+Backspace / Alt+Backspace / Ctrl+W in command mode ---
    if (inCommandMode &&
        ((event.logicalKey == LogicalKey.backspace &&
                (event.isControlPressed || event.isAltPressed)) ||
            event.matches(LogicalKey.keyW, ctrl: true))) {
      if (cursorOffset <= 1) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        } else {
          textController.text = '';
          textController.selection = const TextSelection.collapsed(offset: 0);
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
        return true;
      } else if (!isCollapsed && selStart == 0) {
        if (selEnd >= text.length) {
          final stash = getCommandStash();
          if (stash != null) {
            _restoreStashedText();
          } else {
            textController.text = '';
            textController.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          textController.text = '/${text.substring(selEnd)}';
          textController.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      }
    }

    // --- Ctrl+Delete / Alt+Delete in command mode ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.delete &&
        (event.isControlPressed || event.isAltPressed)) {
      if (cursorOffset <= 0) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        } else {
          textController.text = '';
          textController.selection = const TextSelection.collapsed(offset: 0);
        }
        return true;
      }
    }

    // --- Home key in command mode: move to after the '/' ---
    if (inCommandMode &&
        event.logicalKey == LogicalKey.home &&
        !event.isControlPressed) {
      textController.selection = const TextSelection.collapsed(offset: 1);
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
          final stash = getCommandStash();
          if (stash != null) {
            _restoreStashedText();
          } else {
            textController.text = '';
            textController.selection = const TextSelection.collapsed(offset: 0);
          }
        } else {
          textController.text = '/${text.substring(selEnd)}';
          textController.selection = const TextSelection.collapsed(offset: 1);
        }
        return true;
      }
    }

    if (overlayController.overlayMode == OverlayMode.off) {
      // Double-ESC interrupt logic.
      if (event.logicalKey == LogicalKey.escape) {
        final sessionId = sessionController.currentSessionId;
        final isStreaming =
            sessionId != null &&
            sessionController.runtime(sessionId).isResponding;
        if (isStreaming) {
          final now = DateTime.now();
          if (_lastEscPressTime != null &&
              now.difference(_lastEscPressTime!).inMilliseconds < 1000) {
            _lastEscPressTime = null;
            _escInterruptHint = false;
            turnOrchestrator.interruptResponse(
              textController: textController,
            );
          } else {
            _lastEscPressTime = now;
            _escInterruptHint = true;
            Future.delayed(const Duration(seconds: 1), () {
              if (_escInterruptHint) {
                _escInterruptHint = false;
                onStateChanged();
              }
            });
            onStateChanged();
          }
          return true;
        }
        // ESC while in command mode (no overlay): restore stashed text,
        // or clear the command text if there's no stash.
        if (inCommandMode) {
          final stash = getCommandStash();
          if (stash != null) {
            _restoreStashedText();
          } else {
            textController.clear();
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
        onSendMessage?.call();
        return true;
      }

      // Insert a literal newline on modified Enter or Ctrl+J.
      if (isModifiedEnter || isCtrlJ) {
        final newText = textController.text.replaceRange(
          selection.start,
          selection.end,
          '\n',
        );
        final newOffset = selection.start + 1;
        textController.text = newText;
        textController.selection = TextSelection.collapsed(offset: newOffset);
        return true;
      }

      if (event.logicalKey == LogicalKey.pageUp &&
          (event.isControlPressed || event.isAltPressed)) {
        onJumpToPrevious?.call();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown &&
          (event.isControlPressed || event.isAltPressed)) {
        onJumpToNext?.call();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageUp) {
        scrollController.pageUp();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown) {
        scrollController.pageDown();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowUp && event.isControlPressed) {
        scrollController.scrollUp(
          scrollController.viewportDimension / 2,
        );
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown && event.isControlPressed) {
        scrollController.scrollDown(
          scrollController.viewportDimension / 2,
        );
        return true;
      }
      if (event.logicalKey == LogicalKey.home && event.isControlPressed) {
        scrollController.scrollToStart();
        return true;
      }
      if (event.logicalKey == LogicalKey.end && event.isControlPressed) {
        scrollController.scrollToBottom();
        return true;
      }
      return false;
    }

    if (overlayController.overlayMode == OverlayMode.command) {
      if (overlayController.filteredCommands.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlayController.moveCommandSelectionUp();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlayController.moveCommandSelectionDown();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlayController.onTapCommand(overlayController.selectedCommandIndex);
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        } else {
          textController.clear();
        }
        overlayController.setOverlayOff();
        refresh();
        return true;
      }
      return false;
    }

    if (overlayController.overlayMode == OverlayMode.parameter) {
      if (overlayController.filteredSuggestions.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlayController.moveSuggestionSelectionUp();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlayController.moveSuggestionSelectionDown();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlayController.onTapSuggestion(overlayController.selectedSuggestionIndex);
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        } else {
          textController.clear();
        }
        overlayController.setOverlayOff();
        refresh();
        return true;
      }
      return false;
    }

    if (overlayController.overlayMode == OverlayMode.atMention) {
      if (overlayController.filteredFiles.isEmpty) {
        if (event.logicalKey == LogicalKey.escape) {
          overlayController.setOverlayOff();
          refresh();
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          overlayController.setOverlayOff();
          refresh();
          return true;
        }
        return false;
      }

      if (event.logicalKey == LogicalKey.arrowUp) {
        overlayController.moveFileSelectionUp();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlayController.moveFileSelectionDown();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowRight) {
        final selected = overlayController.selectedFile;
        if (selected != null && selected.isDirectory) {
          final mention = findActiveMentionInText(
            textController.text,
            textController.selection.extentOffset,
          );
          if (mention != null) {
            final path = selected.relativePath;
            final stripped = path.endsWith('/')
                ? path.substring(0, path.length - 1)
                : path;
            final newQuery = '$stripped/';
            final text = textController.text;
            final newText = text.replaceRange(
              mention.atOffset,
              mention.cursor,
              '@$newQuery',
            );
            textController.text = newText;
            textController.selection = TextSelection.collapsed(
              offset: mention.atOffset + 1 + newQuery.length,
            );
            return true;
          }
        }
        return false;
      }
      if (event.logicalKey == LogicalKey.tab) {
        final mention = findActiveMentionInText(
          textController.text,
          textController.selection.extentOffset,
        );
        overlayController.insertAtMention(mention?.atOffset);
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        final mention = findActiveMentionInText(
          textController.text,
          textController.selection.extentOffset,
        );
        overlayController.insertAtMention(mention?.atOffset);
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        overlayController.setOverlayOff();
        refresh();
        return true;
      }
      return false;
    }

    return false;
  }

  void _restoreStashedText() {
    final stash = getCommandStash();
    if (stash != null && stash.isNotEmpty) {
      textController.text = stash;
      textController.selection = TextSelection.collapsed(offset: stash.length);
    }
    setCommandStash(null);
  }

  // --- Callbacks wired by ChatInputState ---
  Future<bool> Function(int sessionId, {bool showEmptyToast})? tryClipboardImage;
  void Function()? onSendMessage;
  void Function()? onJumpToPrevious;
  void Function()? onJumpToNext;
}

import 'package:nocterm/nocterm.dart';

import '../commands/registry.dart';
import '../i18n/strings.dart';
import '../utils/at_mention_parser.dart';
import '../utils/skill_chip_parser.dart';
import '../utils/session_mention.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'chat_turn_orchestrator.dart';
import 'ui/toast.dart';

/// Find the dollar-offset of a skill chip that ends at [cursor].
///
/// Returns the offset of the `$` if [text] (0..cursor) ends with
/// a `$<name>` token where every name char is a skill-name char
/// and the char before the `$` is not a name char. Returns null
/// otherwise.
///
/// Mirrors the at-mention parser's chip-detection rules so the
/// picker and the backspace handler agree on what counts as a
/// chip. Used by the chip-aware backspace shortcut — see the
/// "Backspace that crosses a whole skill chip" branch in
/// [InputKeyHandler.handleKeyEvent].
int? _skillChipDollarOffsetAt(String text, int cursor) {
  if (cursor <= 0 || cursor > text.length) return null;
  var i = cursor - 1;
  // Walk back collecting skill-name chars.
  while (i >= 0 && isSkillNameChar(text[i])) {
    i--;
  }
  // `i` now points at the char just before the name-token
  // (or -1 if the token started at offset 0). For a chip we
  // need that char to be the `$`.
  if (i < 0 || text[i] != r'$') return null;
  // The char before the `$` must not be a name char (so we
  // don't accidentally catch a `$` in the middle of a longer
  // token like `foo$pr-review` — that one is rejected by the
  // parser at submit time too).
  if (i > 0 && isSkillNameChar(text[i - 1])) return null;
  return i;
}

/// True when [text] starts with '/' but its command token no longer
/// resolves to a registered command — e.g. a pasted path
/// (`/Users/foo/file`) or a mistyped name. `/` alone, and any token
/// that is still a prefix of a real command (`/he` → `/help`), count
/// as *in-progress* command typing and return false so command mode
/// (and its picker) stay active.
///
/// Top-level and pure so it can be unit-tested without the TUI harness.
bool isUnresolvedSlashToken(String text) {
  if (!text.startsWith('/')) return false;
  final token = text.split(' ').first;
  if (token == '/') return false;
  if (findCommand(token) != null) return false;
  // Keep command mode while the token is still a prefix of a real
  // command — that's the user mid-typing, not a dead token.
  for (final cmd in CommandRegistry.instance.all) {
    for (final name in cmd.allNames) {
      if (name.startsWith(token)) return false;
    }
  }
  return true;
}

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

  /// Open the home screen on a plain ESC press. Wired by the chat
  /// panel; when null (tests), a plain ESC press is consumed as a no-op.
  final VoidCallback? onOpenHome;

  /// Cycle to the next session (Tab) — active → done → interrupted →
  /// previous. Wired by the chat panel; when null, plain Tab falls
  /// through to the TextField (indent / focus behaviour).
  final VoidCallback? onCycleSessions;
  final VoidCallback refresh;
  final void Function() onStateChanged;
  final TextEditingController textController;
  final OverlayController overlayController;
  final AutoScrollController? scrollController;

  /// Locale-aware chrome strings. Defaulted to English so existing
  /// constructions stay green — production wiring is via [ChatInput]
  /// which passes the live `Strings`.
  final Strings strings;

  // Shared state accessor (owned by ChatInputState)
  final String? Function() getCommandStash;
  final void Function(String?) setCommandStash;

  // Own state
  DateTime? _lastCtrlCPressTime;
  bool _ctrlCQuitHint = false;

  InputKeyHandler({
    required this.sessionController,
    required this.turnOrchestrator,
    required this.onQuitRequest,
    this.onOpenHome,
    this.onCycleSessions,
    required this.refresh,
    required this.onStateChanged,
    required this.textController,
    required this.overlayController,
    this.scrollController,
    required this.getCommandStash,
    required this.setCommandStash,
    this.strings = kEnglishStrings,
  });

  bool get ctrlCQuitHint => _ctrlCQuitHint;

  /// Map a logical key to its character, only for the '/' key.
  static String? getCharFromKey(LogicalKey key) {
    if (key == LogicalKey.slash) return '/';
    return null;
  }

  bool handleKeyEvent(KeyboardEvent event) {
    // --- Ctrl+C: quit only ---
    //
    // 1. Interrupting a streaming response is the toolbar model
    //    button's job — Ctrl+C never cancels a response.
    // 2. When any session is running (including a streaming one), the
    //    first Ctrl+C arms the quit guard with a toast; a quick second
    //    Ctrl+C (within 3s) quits.
    // 3. When nothing is running, Ctrl+C quits immediately.
    if (event.logicalKey == LogicalKey.keyC &&
        event.isControlPressed &&
        !event.isShiftPressed &&
        !event.isAltPressed &&
        !event.isMetaPressed) {
      final now = DateTime.now();

      // Quick double-press (within 3s, hint armed) quits.
      if (_lastCtrlCPressTime != null &&
          now.difference(_lastCtrlCPressTime!).inMilliseconds < 3000 &&
          _ctrlCQuitHint) {
        _lastCtrlCPressTime = null;
        _ctrlCQuitHint = false;
        onQuitRequest?.call();
        return true;
      }

      // Any session running — arm the double-press quit guard. The
      // response keeps streaming; interrupting is the model button's job.
      if (sessionController.hasAnyRunningSession) {
        _lastCtrlCPressTime = now;
        _ctrlCQuitHint = true;
        turnOrchestrator.showToast(
          strings.t('toast.ctrlCQuit'),
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
    var inCommandMode = text.startsWith('/');

    // --- Escape hatch: a leading '/' that no longer names a command ---
    //
    // Pasting a path like `/Users/foo/file` or typing a '/' the user
    // didn't mean as a command drops the input into command mode
    // (see the '/'-at-position-0 branch below). Once the token stops
    // resolving to a real command, staying in that mode traps the
    // user: every guard here treats the '/' as sacred, so nothing can
    // be typed or pasted *before* it, and submitting just toasts
    // "Unknown command". Detect the dead token on the next key event
    // and drop back to plain-text mode, keeping the text intact.
    //
    // `/` alone (and any prefix of a real command, e.g. `/he`) is left
    // untouched so normal command typing and the picker still work.
    if (inCommandMode && isUnresolvedSlashToken(text)) {
      inCommandMode = false;
      overlayController.setOverlayOff();
      onStateChanged();
    }

    // --- Command mode: intercept character insertion before the '/' ---
    //
    // Runs only while the token still resolves to a command (the
    // escape hatch above downgrades `inCommandMode` for dead tokens),
    // so a plain-text leading '/' — a pasted path — can once again be
    // prepended to.
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
    //
    // Only on an empty field. If text already holds a leading '/' that
    // the escape hatch just deemed a dead token (a pasted path), a '/' —
    // or any char — typed at position 0 is plain prepending; forcing it
    // back to a bare '/' would swallow the path and re-trap the user.
    if (!inCommandMode &&
        text.isEmpty &&
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

    // --- Backspace that crosses a whole skill chip ---
    //
    // When the user presses backspace and the cursor sits at the
    // end of a `$<name>` token (or inside it), one backspace
    // removes the whole chip — `$<name>` and all — instead of
    // one character at a time. The chip-parser walk below is the
    // same rules the picker uses to detect an in-progress chip,
    // so the two stay in sync.
    //
    // Only fires when the selection is collapsed (a non-collapsed
    // selection is a range delete, not a chip erase). Skips
    // command mode entirely — `/...` has its own backspace
    // contract that would otherwise fight with this one.
    if (!inCommandMode &&
        event.logicalKey == LogicalKey.backspace &&
        !event.isControlPressed &&
        !event.isAltPressed &&
        selection.isCollapsed &&
        cursorOffset > 0 &&
        overlayController.overlayMode != OverlayMode.skillPicker) {
      final dollarOffset = _skillChipDollarOffsetAt(text, cursorOffset);
      if (dollarOffset != null) {
        // The chip runs from dollarOffset (the `$`) to
        // cursorOffset (exclusive). Removing the whole chip
        // means deleting the span [dollarOffset, cursorOffset).
        final newText =
            text.substring(0, dollarOffset) + text.substring(cursorOffset);
        textController.text = newText;
        textController.selection = TextSelection.collapsed(
          offset: dollarOffset,
        );
        // Dismiss the picker — the chip it was anchored to is
        // gone, so the picker has nothing to show.
        overlayController.setOverlayOff();
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
      // ESC no longer interrupts a streaming response — that's the
      // toolbar model button's job now (it flashes while streaming and
      // interrupts on click). A plain ESC in command mode restores the
      // stashed text; otherwise it navigates to the home screen.
      if (event.logicalKey == LogicalKey.escape) {
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
        onOpenHome?.call();
        return true;
      }

      // Plain Tab (no modifiers, overlay off): cycle to the next
      // session — active → done → interrupted → previous. Wired by the
      // chat panel; home's quick-chat leaves it null so Tab keeps its
      // grid-navigation meaning there.
      if (event.logicalKey == LogicalKey.tab &&
          !event.isShiftPressed &&
          !event.isControlPressed &&
          !event.isAltPressed &&
          !event.isMetaPressed) {
        if (onCycleSessions != null) {
          onCycleSessions!();
          return true;
        }
        return false;
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
        scrollController?.pageUp();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown) {
        scrollController?.pageDown();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowUp && event.isControlPressed) {
        scrollController?.scrollUp((scrollController?.viewportDimension ?? 0) / 2);
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown && event.isControlPressed) {
        scrollController?.scrollDown(
          (scrollController?.viewportDimension ?? 0) / 2,
        );
        return true;
      }
      if (event.logicalKey == LogicalKey.home && event.isControlPressed) {
        scrollController?.scrollToStart();
        return true;
      }
      if (event.logicalKey == LogicalKey.end && event.isControlPressed) {
        scrollController?.scrollToBottom();
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
        overlayController.onTapSuggestion(
          overlayController.selectedSuggestionIndex,
        );
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        final stash = getCommandStash();
        if (stash != null) {
          _restoreStashedText();
        }
        // ESC just dismisses the suggestion overlay — it does NOT
        // clear the input. Clearing here would destroy the user's
        // in-progress command, and many commands (`/think`,
        // `/temperature`, `/theme`, `/d-profiler`, `/web-provider`)
        // accept a bare invocation, so a typed-but-unfilled
        // `/temperature ` is still a valid submission (`parts[1]`
        // is empty → falls through to the no-arg branch in the
        // executor). Press Enter after ESC to submit as-is.
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

    if (overlayController.overlayMode == OverlayMode.skillPicker) {
      // No matches — ESC dismisses, Enter dismisses (nothing to
      // pick). Don't accept the Enter for send-on-Enter, since
      // the user is mid-`$query` and probably wants to keep
      // typing.
      if (overlayController.filteredSkills.isEmpty) {
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
        overlayController.moveSkillSelectionUp();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlayController.moveSkillSelectionDown();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.tab ||
          event.logicalKey == LogicalKey.enter) {
        // Find the active chip position; the cubit already
        // stored the most recent one but recomputing here keeps
        // the key handler decoupled from the cubit's exact
        // shape (and tolerates the text changing under us).
        final chip = findActiveSkillChip(
          textController.text,
          textController.selection.extentOffset,
        );
        overlayController.insertSkillChip(chip?.dollarOffset);
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

    if (overlayController.overlayMode == OverlayMode.sessionMention) {
      if (overlayController.filteredSessionMentions.isEmpty) {
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
        overlayController.moveSessionMentionSelectionUp();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        overlayController.moveSessionMentionSelectionDown();
        refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.tab ||
          event.logicalKey == LogicalKey.enter) {
        final mention = findActiveSessionMention(
          textController.text,
          textController.selection.extentOffset,
        );
        overlayController.insertSessionMention(mention?.hashOffset);
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
  Future<bool> Function(int sessionId, {bool showEmptyToast})?
  tryClipboardImage;
  void Function()? onSendMessage;
  void Function()? onJumpToPrevious;
  void Function()? onJumpToNext;
}

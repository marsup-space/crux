import 'package:nocterm/nocterm.dart';
import '../models/slash_command.dart';
import '../services/provider_service.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/cjk_word_boundary.dart';
import '../commands/registry.dart';
import 'chat_turn_orchestrator.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';

/// The chat input box at the bottom of the chat panel.
///
/// Handles keyboard events (Enter to send, Shift+Enter for newline,
/// ESC×2 to interrupt, arrow keys for overlay navigation), text-change
/// driven autocomplete/overlay logic, and renders the command/suggestion
/// overlays.
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
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  /// Timestamp of the last ESC key press while the agent was streaming.
  DateTime? _lastEscPressTime;

  /// True briefly after the first ESC press while streaming, so the
  /// UI can show a "Press ESC again to interrupt" hint.
  bool _escInterruptHint = false;

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

  void _onTextChanged() {
    final text = component.textController.text;
    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');
    final overlay = component.overlayController;

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

  bool _handleKeyEvent(KeyboardEvent event) {
    final overlay = component.overlayController;
    if (overlay.showSessionManager) return true;

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
        final tc = component.textController;
        final newText = tc.text.replaceRange(
          tc.selection.start,
          tc.selection.end,
          '\n',
        );
        final newOffset = tc.selection.start + 1;
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
        setState(() => overlay.moveCommandSelectionUp());
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() => overlay.moveCommandSelectionDown());
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlay.onTapCommand(overlay.selectedCommandIndex);
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        component.textController.clear();
        overlay.setOverlayOff();
        component.refresh();
        return true;
      }
      return false;
    }

    if (overlay.overlayMode == OverlayMode.parameter) {
      if (overlay.filteredSuggestions.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() => overlay.moveSuggestionSelectionUp());
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() => overlay.moveSuggestionSelectionDown());
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        overlay.onTapSuggestion(overlay.selectedSuggestionIndex);
        component.refresh();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        overlay.setOverlayOff();
        component.refresh();
        return true;
      }
      return false;
    }

    return false;
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
      component.onExecuteCommand(text);
      return;
    }

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

    final overlay = component.overlayController;
    final placeholder = isStreaming
        ? _escInterruptHint
            ? 'Press ESC again to interrupt...'
            : 'Enter message to queue, ESC×2 to interrupt'
        : wasInterrupted
            ? 'Response was interrupted. Type a new message...'
            : 'Type a message...';

    return Container(
      padding: EdgeInsets.all(1),
      child: Row(
        children: [
          Text(
            '> ',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
          Expanded(
            child: TextField(
              controller: component.textController,
              focused: !overlay.showSessionManager,
              maxLines: null,
              style: TextStyle(color: CruxTheme.of(context).foreground),
              placeholder: placeholder,
              onKeyEvent: _handleKeyEvent,
              wordBoundaryProvider: cjkWordBoundaryProvider,
            ),
          ),
        ],
      ),
    );
  }
}

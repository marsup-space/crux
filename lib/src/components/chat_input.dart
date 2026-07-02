import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../models/image_attachment.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/web_provider_registry.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/frame_profiler.dart';
import '../commands/registry.dart';
import 'chat_turn_orchestrator.dart';
import 'input_keys.dart';
import 'input_overlay.dart';
import 'input_paste.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';

/// The chat input box at the bottom of the chat panel.
///
/// Thin facade that delegates to:
///   - [InputOverlay] — overlay state, @-mentions, command mode, suggestions
///   - [InputKeyHandler] — all keyboard events
///   - [InputPaste] — clipboard, drag-and-drop, image attachment
class ChatInput extends StatefulComponent {
  final TextEditingController textController;
  final OverlayController overlayController;
  final SessionController sessionController;
  final StreamingController streamingController;
  final ChatTurnOrchestrator turnOrchestrator;
  final ProviderService providerService;
  final bool providerServiceReady;
  final WebProviderRegistry webProviderRegistry;
  final ThemeController themeController;
  final AutoScrollController scrollController;
  final void Function() refresh;
  final void Function(String text) onSendTurn;
  final void Function(String text) onExecuteCommand;
  final Future<void> Function(int sessionId) onSwitchSession;
  final Future<void> Function() onInitSessions;
  final Future<void> Function() onCreateNewSession;
  final void Function(ImageAttachment image)? onAttachClipboardImage;
  final VoidCallback? onQuitRequest;
  final String projectPath;
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
    required this.webProviderRegistry,
    required this.themeController,
    required this.scrollController,
    required this.refresh,
    required this.onSendTurn,
    required this.onExecuteCommand,
    required this.onSwitchSession,
    required this.onInitSessions,
    required this.onCreateNewSession,
    this.onAttachClipboardImage,
    this.onQuitRequest,
    this.projectPath = '.',
    this.recentProjectsStore,
  });

  @override
  State<ChatInput> createState() => ChatInputState();
}

class ChatInputState extends State<ChatInput> {
  static final RegExp _imageMarkerPattern = RegExp(r'\[ image (\d+) \]');

  late final InputOverlay _overlay;
  late final InputKeyHandler _keyHandler;
  late final InputPaste _paste;

  // Command-mode stash state (owned by facade, shared with key handler)
  String? _commandStashedText;
  bool _syncingImageMarkers = false;

  String? get commandStashedText => _commandStashedText;

  @override
  void initState() {
    super.initState();

    _overlay = InputOverlay(
      overlayController: component.overlayController,
      sessionController: component.sessionController,
      providerService: component.providerService,
      providerServiceReady: component.providerServiceReady,
      webProviderRegistry: component.webProviderRegistry,
      themeController: component.themeController,
      recentProjectsStore: component.recentProjectsStore,
      textController: component.textController,
      projectPath: component.projectPath,
      refresh: component.refresh,
      onStateChanged: _onControllerStateChanged,
    );

    _paste = InputPaste(
      sessionController: component.sessionController,
      turnOrchestrator: component.turnOrchestrator,
      providerService: component.providerService,
      providerServiceReady: component.providerServiceReady,
      textController: component.textController,
      projectPath: component.projectPath,
      onAttachClipboardImage: component.onAttachClipboardImage,
      onStateChanged: _onControllerStateChanged,
    );

    _keyHandler = InputKeyHandler(
      sessionController: component.sessionController,
      turnOrchestrator: component.turnOrchestrator,
      onQuitRequest: component.onQuitRequest,
      refresh: component.refresh,
      onStateChanged: _onControllerStateChanged,
      textController: component.textController,
      overlayController: component.overlayController,
      scrollController: component.scrollController,
      getCommandStash: () => _commandStashedText,
      setCommandStash: (v) => _commandStashedText = v,
    );

    // Wire callbacks from key handler to paste and send logic
    _keyHandler.tryClipboardImage = _paste.tryClipboardImage;
    _keyHandler.onSendMessage = _sendMessage;
    _keyHandler.onJumpToPrevious = _jumpToPreviousUserInput;
    _keyHandler.onJumpToNext = _jumpToNextUserInput;

    component.textController.addListener(_onTextChanged);
    CommandRegistry.instance.addListener(component.refresh);
    component.recentProjectsStore?.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    component.textController.removeListener(_onTextChanged);
    CommandRegistry.instance.removeListener(component.refresh);
    component.recentProjectsStore?.removeListener(_onTextChanged);
    _overlay.dispose();
    super.dispose();
  }

  void _onControllerStateChanged() {
    if (mounted) setState(() {});
  }

  // ── Public API for parent widgets ─────────────────────────────────

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
    _commandStashedText = null;
  }

  void restoreCommandStash() {
    if (_commandStashedText != null && _commandStashedText!.isNotEmpty) {
      component.textController.text = _commandStashedText!;
      component.textController.selection = TextSelection.collapsed(
        offset: _commandStashedText!.length,
      );
    }
    _commandStashedText = null;
  }

  void submit(String text) {
    if (text.trim().isEmpty) return;
    component.onSendTurn(text);
  }

  void appendText(String text) {
    if (text.isEmpty) return;
    final current = component.textController.text.trimRight();
    final newText = current.isEmpty ? text : '$current\n$text';
    component.textController.text = newText;
    component.textController.selection = TextSelection.collapsed(
      offset: newText.length,
    );
  }

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

  // ── Text change ──────────────────────────────────────────────────

  void _onTextChanged() {
    if (!_syncingImageMarkers) {
      _syncPendingImagesWithMarkers();
    }
    _overlay.onTextChanged();
  }

  // ── Send ─────────────────────────────────────────────────────────

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
      component.onExecuteCommand(text);
      return;
    }

    _commandStashedText = null;
    component.onSendTurn(text);
  }

  // ── Image marker sync ────────────────────────────────────────────

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

  // ── Input history navigation ─────────────────────────────────────

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

  // ── Build ────────────────────────────────────────────────────────

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

    final pendingImages = sessionId != null
        ? component.sessionController.pendingImagesFor(sessionId)
        : <ImageAttachment>[];
    final hasImages = pendingImages.isNotEmpty;

    final overlay = component.overlayController;
    final placeholder = isStreaming
        ? _keyHandler.ctrlCQuitHint
              ? 'Press Ctrl+C again to quit...'
              : _keyHandler.escInterruptHint
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
              onKeyEvent: _keyHandler.handleKeyEvent,
              onPaste: (pastedText) => _paste.handlePaste(pastedText, sessionId),
              wordBoundaryProvider: cjkWordBoundaryProvider,
            ),
          ),
          Button(
            label: 'paste',
            onPressed: () => _paste.pasteFromButton(sessionId),
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

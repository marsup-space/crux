import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/text/text_layout_engine.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/markdown_headings.dart';
import '../utils/url_launcher.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';
import '../commands/command_executor.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/install_slug.dart';
import '../services/llm_client.dart';
import '../services/llm_provider.dart';
import '../services/provider_service.dart';
import '../services/tool_executor.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../tools/shell_base.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/token_estimate.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/toast.dart';
import 'ui/bg_progress_bar.dart';
import 'ui/glossy_model_button.dart';
import 'command_overlay.dart';
import 'suggestion_overlay.dart';
import 'extra_info_panel.dart';
import 'session_management_panel.dart';
import 'annotated_scrollbar.dart';
import 'btw_bubble.dart';
import 'message_bubble.dart';
import 'queued_messages_bubble.dart';
import 'streaming_bubble.dart';
import 'tldr_bubble.dart';

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;
  final List<String> startupWarnings;

  const ChatPanel({
    super.key,
    required this.userProvidersDir,
    this.builtInProvidersDir,
    required this.themeController,
    this.startupWarnings = const [],
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final SessionStore _store;
  late final ChatService _chatService;
  late final ProviderService _providerService;
  late final ToolRegistry _toolRegistry;
  late final SessionController _sessionController;
  late final OverlayController _overlayController;
  late final StreamingController _streamingController;
  late final CommandExecutor _commandExecutor;

  bool _providerServiceReady = false;

  /// Timestamp of the last ESC key press while the agent was streaming.
  /// Used to detect double-ESC within 1 second as an interrupt signal.
  DateTime? _lastEscPressTime;

  /// True briefly after the first ESC press while streaming, so the
  /// UI can show a "Press ESC again to interrupt" hint. Cleared
  /// after 1 second or when the second ESC arrives.
  bool _escInterruptHint = false;

  /// Per-session cancellation flags for btw turns. When the user
  /// interrupts a btw stream, the flag is set to true so the
  /// `await for` loop in `_sendBtwTurn` breaks out immediately.
  final Map<int, bool> _btwCancelFlags = {};

  /// Set of session IDs that have been interrupted by the user. Used
  /// to prevent the `onComplete` / `onError` callbacks from running
  /// after an interrupt, since `_interruptResponse` already handled
  /// all cleanup. Entries are removed when `_sendTurn` starts a new
  /// turn for that session.
  final Set<int> _interruptedSessions = {};

  /// Per-session abort signals for currently running tool executions.
  /// When the user interrupts, `_interruptResponse` calls `abort()` on
  /// each signal, which kills any running subprocesses (bash, cmd, etc.).
  final Map<int, List<AbortSignal>> _activeAbortSignals = {};

  final _toastKey = GlobalKey<ToastHubState>();
  bool _metricsHovered = false;
  String? _highlightText;
  int? _highlightMessageId;
  int _lastContentWidth = 120;

  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  /// Minimum terminal width (columns) at which the side panel is shown.
  static const int _infoPanelShowThreshold = 100;

  /// Minimum width (columns) of the side panel itself.
  static const double _infoPanelWidthMin = 28;

  /// Maximum width (columns) of the side panel itself.
  static const double _infoPanelWidthMax = 40;

  int get _contextMaxTokens {
    if (!_providerServiceReady) return 131072;
    final model = _providerService.modelByCompositeKey(
      _sessionController.currentSession.model,
    );
    return model?.contextSize ?? 131072;
  }

  bool _modelSupportsImages(String compositeKey) {
    if (!_providerServiceReady) return false;
    return _providerService.imageModelKeys().contains(compositeKey);
  }

  bool _modelSupportsThinking(String compositeKey) {
    if (!_providerServiceReady) return false;
    final mc = _providerService.modelByCompositeKey(compositeKey);
    return mc?.thinking == true || mc?.reasoningEffort != null;
  }

  @override
  void initState() {
    super.initState();
    _providerService = ProviderService(
      userProvidersDir: component.userProvidersDir,
      builtInProvidersDir: component.builtInProvidersDir,
    );
    final db = CruxDatabase();
    _store = SessionStore(db);
    final tracker = FileReadTracker();
    final registry = ToolRegistry();
    registry.registerDefaults(tracker);
    final toolExecutor = ToolExecutor(registry, _store);
    _toolRegistry = registry;
    _chatService = ChatService(
      _store,
      _providerService,
      LlmClient(),
      toolExecutor,
    );

    _sessionController = SessionController(
      store: _store,
      providerService: _providerService,
      chatService: _chatService,
      refresh: _refresh,
    );
    _overlayController = OverlayController(
      maxVisibleItems: _maxVisibleItems,
      textController: textController,
      executeCommandCallback: _executeCommand,
    );
    _streamingController = StreamingController(
      sessionController: _sessionController,
      refresh: _refresh,
    );
    _commandExecutor = CommandExecutor();

    textController.addListener(_onTextChanged);
    CommandRegistry.instance.addListener(_refresh);
    _initSessions();
    _providerService.initialize().then((_) {
      setState(() {
        _providerServiceReady = true;
        _sessionController.resolveAuxiliaryModel();
      });
    });
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      for (final warning in component.startupWarnings) {
        _showToast(warning, mode: ToastMode.error);
      }
    });
  }

  void _refresh() {
    setState(() {});
  }

  void _showToast(String message, {ToastMode? mode}) {
    // `mode: null` triggers the toast hub's keyword-based auto-detection.
    _toastKey.currentState?.show(message, mode: mode);
  }

  /// Open the current project directory in the system file explorer.
  /// Wired to the `open` segment of the project path [MultiButton] in
  /// the side panel. Surfaces failures as toasts because the only
  /// legitimate failure modes are "directory no longer exists" and
  /// "no file manager on $PATH" — both worth telling the user about,
  /// neither worth crashing the TUI for.
  void _openProjectInExplorer() {
    final result = openDirectory(Directory.current.path);
    switch (result) {
      case OpenDirectoryResult.launched:
        return;
      case OpenDirectoryResult.notFound:
        _showToast(
          'Directory not found: ${Directory.current.path}',
          mode: ToastMode.error,
        );
      case OpenDirectoryResult.failed:
        _showToast(
          "Couldn't open file manager for ${Directory.current.path}",
          mode: ToastMode.error,
        );
    }
  }

  /// Seed the chat input with `/project ` and move the caret to the
  /// end so the user can type a new project path and submit. Wired to
  /// the `switch` segment of the project path [MultiButton] in the
  /// side panel. Routing through the slash command (rather than
  /// driving the switch logic directly here) keeps the directory
  /// validation, toast-on-missing-directory, and session reload logic
  /// in [CommandExecutor.executeProject] as a single source of truth,
  /// so typing `/project …` and clicking the button do exactly the
  /// same thing.
  void _switchProject() {
    textController.text = '/project ';
    textController.selection = TextSelection.collapsed(
      offset: textController.text.length,
    );
  }

  static int get _maxVisibleItems => 6;

  Future<void> _initSessions() async {
    await _sessionController.initSessions();
    setState(() {});
  }

  Future<void> _switchSession(int id) async {
    // Stop metrics timer for the old session (if any).
    final oldId = _sessionController.currentSessionId;
    if (oldId != null && oldId != id) {
      _streamingController.stopMetricsTimer(oldId);
    }

    final error = await _sessionController.switchSession(id);

    // If the new session is actively streaming, start its metrics timer
    // so the toolbar shows live tok/s, TTFT, etc.
    final rt = _sessionController.runtime(id);
    if (rt.isResponding) {
      _streamingController.startMetricsTimer(id);
    }

    _streamingController.stopContextAnimation();
    scrollController.scrollToBottom();
    if (error != null) {
      _showToast(error, mode: ToastMode.error);
    }
    setState(() {});
  }

  @override
  void dispose() {
    textController.removeListener(_onTextChanged);
    CommandRegistry.instance.removeListener(_refresh);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = textController.text;
    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      _overlayController.setOverlayOff();
      setState(() {});
      return;
    }

    final spaceIndex = trimmed.indexOf(' ');

    if (spaceIndex == -1) {
      _overlayController.filteredCommands = filterCommands(trimmed);
      if (_overlayController.filteredCommands.isEmpty) {
        _overlayController.setOverlayOff();
      } else {
        _overlayController.overlayMode = OverlayMode.command;
        _overlayController.selectedCommandIndex = 0;
        _overlayController.commandScrollOffset = 0;
      }
      setState(() {});
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
      _overlayController.setOverlayOff();
      setState(() {});
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
      _overlayController.setOverlayOff();
      setState(() {});
      return;
    }

    final List<CommandSuggestion> suggestions;
    if (commandName == '/session' && paramIndex == 0) {
      suggestions = _sessionController.sessions
          .map(
            (s) => CommandSuggestion(value: s.displayId, description: s.title),
          )
          .toList();
    } else if (commandName == '/auxiliary' && paramIndex == 0) {
      if (_providerServiceReady) {
        suggestions = [
          CommandSuggestion(value: 'none', description: 'No auxiliary model'),
          ..._providerService
              .allModelEntries()
              .where((e) => _providerService.getApiKey(e.providerName) != null)
              .map((e) {
                final ctx = e.model.contextSize >= 1000000
                    ? '${(e.model.contextSize / 1048576).toStringAsFixed(0)}M'
                    : '${(e.model.contextSize / 1000).toStringAsFixed(0)}K';
                final img = e.model.imageSupport ? ', img' : '';
                final think = e.model.thinking ? ', think' : '';
                return CommandSuggestion(
                  value: e.compositeKey,
                  description: '${e.model.name} (${ctx} ctx$img$think)',
                );
              }),
        ];
      } else {
        suggestions = [];
      }
    } else if (commandName == '/provider' && paramIndex == 0) {
      if (_providerServiceReady) {
        suggestions = _providerService
            .providerNames()
            .map(
              (name) => CommandSuggestion(
                value: name,
                description: _providerService.getApiKey(name) != null
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
      if (_providerServiceReady) {
        suggestions = _providerService
            .allModelEntries()
            .where((e) => _providerService.getApiKey(e.providerName) != null)
            .map((e) {
              final ctx = e.model.contextSize >= 1000000
                  ? '${(e.model.contextSize / 1048576).toStringAsFixed(0)}M'
                  : '${(e.model.contextSize / 1000).toStringAsFixed(0)}K';
              final img = e.model.imageSupport ? ', img' : '';
              final think = e.model.thinking ? ', think' : '';
              return CommandSuggestion(
                value: e.compositeKey,
                description: '${e.model.name} (${ctx} ctx$img$think)',
              );
            })
            .toList();
      } else {
        suggestions = [];
      }
    } else {
      suggestions = command.suggestionsPerParam[paramIndex];
    }
    _overlayController.filteredSuggestions = filterSuggestions(
      suggestions,
      currentInput,
    );

    if (_overlayController.filteredSuggestions.isEmpty) {
      _overlayController.setOverlayOff();
      setState(() {});
      return;
    }

    _overlayController.overlayMode = OverlayMode.parameter;
    _overlayController.activeCommand = command;
    _overlayController.currentParamIndex = paramIndex;
    _overlayController.selectedSuggestionIndex = 0;
    _overlayController.suggestionScrollOffset = 0;
    setState(() {});
  }

  bool _handleInputKeyEvent(KeyboardEvent event) {
    if (_overlayController.showSessionManager) return true;

    if (_overlayController.overlayMode == OverlayMode.off) {
      // Double-ESC interrupt: when the agent is streaming, pressing
      // ESC twice within 1 second interrupts the response. The first
      // ESC press is recorded; if a second ESC arrives within 1s, the
      // response is interrupted. A single ESC press (or one followed by
      // any other key) is ignored — it does not clear the input or
      // interfere with normal typing.
      if (event.logicalKey == LogicalKey.escape) {
        final sessionId = _sessionController.currentSessionId;
        final isStreaming =
            sessionId != null && _sessionController.runtime(sessionId).isResponding;
        if (isStreaming) {
          final now = DateTime.now();
          if (_lastEscPressTime != null &&
              now.difference(_lastEscPressTime!).inMilliseconds < 1000) {
            _lastEscPressTime = null;
            _escInterruptHint = false;
            _interruptResponse();
          } else {
            _lastEscPressTime = now;
            _escInterruptHint = true;
            // Auto-clear the hint after 1 second if no second ESC.
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
        // Not streaming: ignore ESC (don't consume it).
        return false;
      } else {
        // Any non-ESC key resets the double-ESC tracker so a stray
        // ESC followed by typing doesn't accidentally trigger an
        // interrupt on the next ESC. Also clear the interrupt hint.
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

      // Insert a literal newline on modified Enter (Shift/Ctrl/Alt+Enter)
      // or Ctrl+J. Modified-Enter only works in terminals that support
      // the kitty keyboard protocol or xterm modifyOtherKeys. Ctrl+J is
      // the universal fallback — it sends raw 0x0A which is always
      // delivered verbatim (we disable icrnl in raw mode so it doesn't
      // get confused with Enter's 0x0D).
      if (isModifiedEnter || isCtrlJ) {
        final newText = textController.text.replaceRange(
          textController.selection.start,
          textController.selection.end,
          '\n',
        );
        final newOffset = textController.selection.start + 1;
        textController.text = newText;
        textController.selection = TextSelection.collapsed(offset: newOffset);
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
        scrollController.pageUp();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown) {
        scrollController.pageDown();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowUp && event.isControlPressed) {
        scrollController.scrollUp(scrollController.viewportDimension / 2);
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown && event.isControlPressed) {
        scrollController.scrollDown(scrollController.viewportDimension / 2);
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

    if (_overlayController.overlayMode == OverlayMode.command) {
      if (_overlayController.filteredCommands.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          _overlayController.moveCommandSelectionUp();
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          _overlayController.moveCommandSelectionDown();
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.enter) {
        final selected = _overlayController
            .filteredCommands[_overlayController.selectedCommandIndex];
        if (selected.params.isEmpty) {
          _overlayController.setOverlayOff();
          textController.clear();
          _executeCommand(selected.name);
        } else {
          textController.text = selected.name + ' ';
          textController.selection = TextSelection.collapsed(
            offset: textController.text.length,
          );
        }
        return true;
      }

      if (event.logicalKey == LogicalKey.escape) {
        textController.clear();
        _overlayController.setOverlayOff();
        setState(() {});
        return true;
      }

      return false;
    }

    if (_overlayController.overlayMode == OverlayMode.parameter) {
      if (_overlayController.filteredSuggestions.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          _overlayController.moveSuggestionSelectionUp();
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          _overlayController.moveSuggestionSelectionDown();
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.enter) {
        final selected = _overlayController
            .filteredSuggestions[_overlayController.selectedSuggestionIndex];
        final trimmed = textController.text.replaceFirst(RegExp(r'^\s+'), '');
        final commandAndSpace = _overlayController.activeCommand!.name + ' ';
        final restOfText = trimmed.substring(
          _overlayController.activeCommand!.name.length + 1,
        );

        String prefix;
        if (restOfText.isEmpty || restOfText.endsWith(' ')) {
          prefix = trimmed;
        } else {
          final lastSpace = restOfText.lastIndexOf(' ');
          prefix = lastSpace >= 0
              ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
              : commandAndSpace;
        }

        final nextParamIndex = _overlayController.currentParamIndex + 1;
        final isLastParam =
            nextParamIndex >= _overlayController.activeCommand!.params.length;

        if (isLastParam) {
          final commandText = prefix + selected.value;
          _overlayController.setOverlayOff();
          textController.clear();
          _executeCommand(commandText);
        } else {
          final newText = prefix + selected.value + ' ';
          textController.text = newText;
          textController.selection = TextSelection.collapsed(
            offset: newText.length,
          );
        }
        return true;
      }

      if (event.logicalKey == LogicalKey.escape) {
        _overlayController.setOverlayOff();
        setState(() {});
        return true;
      }

      return false;
    }

    return false;
  }

  void _jumpToPreviousUserInput() {
    final messages = _sessionController.currentMessages;
    final userIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') userIndices.add(i);
    }
    if (userIndices.isEmpty) return;

    final avgHeight =
        scrollController.maxScrollExtent > 0 && messages.isNotEmpty
        ? scrollController.maxScrollExtent / messages.length
        : 3.0;

    final currentOffset = scrollController.offset;
    int? targetMsgIndex;
    for (final idx in userIndices.reversed) {
      final estOffset = idx * avgHeight;
      if (estOffset < currentOffset - 1) {
        targetMsgIndex = idx;
        break;
      }
    }

    if (targetMsgIndex != null) {
      scrollController.jumpTo(
        (targetMsgIndex * avgHeight).clamp(
          scrollController.minScrollExtent,
          scrollController.maxScrollExtent,
        ),
      );
    }
  }

  void _jumpToNextUserInput() {
    final messages = _sessionController.currentMessages;
    final userIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') userIndices.add(i);
    }
    if (userIndices.isEmpty) return;

    final avgHeight =
        scrollController.maxScrollExtent > 0 && messages.isNotEmpty
        ? scrollController.maxScrollExtent / messages.length
        : 3.0;

    final currentOffset = scrollController.offset;
    int? targetMsgIndex;
    for (final idx in userIndices) {
      final estOffset = idx * avgHeight;
      if (estOffset > currentOffset + 1) {
        targetMsgIndex = idx;
        break;
      }
    }

    if (targetMsgIndex != null) {
      scrollController.jumpTo(
        (targetMsgIndex * avgHeight).clamp(
          scrollController.minScrollExtent,
          scrollController.maxScrollExtent,
        ),
      );
    }
  }

  void _onHoverCommand(int index) {
    setState(() {
      _overlayController.onHoverCommand(index);
    });
  }

  void _onTapCommand(int index) {
    _overlayController.onTapCommand(index);
    setState(() {});
  }

  void _onScrollCommand(MouseEvent event) {
    setState(() {
      _overlayController.onScrollCommand(event);
    });
  }

  void _onHoverSuggestion(int index) {
    setState(() {
      _overlayController.onHoverSuggestion(index);
    });
  }

  void _onTapSuggestion(int index) {
    _overlayController.onTapSuggestion(index);
    setState(() {});
  }

  void _onScrollSuggestion(MouseEvent event) {
    setState(() {
      _overlayController.onScrollSuggestion(event);
    });
  }

  /// Returns true when the session's chat model and the configured auxiliary
  /// model resolve to the same provider/model. When they match, firing the
  /// auxiliary title call in parallel with the main chat response would
  /// contend for the same provider's rate limits, so we fall back to the
  /// legacy behavior of generating the title after the chat response
  /// completes. When they differ, the title can safely be requested in
  /// parallel right when the user submits their input.
  bool _shouldDeferTitleToAfterResponse() {
    final session = _sessionController.currentSession;
    if (session.id == 0) return true;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return true;
    return session.model == auxKey;
  }

  /// Fire-and-forget title generation right after the user submits their
  /// message, but only when the auxiliary model is configured AND is on a
  /// different provider/model than the main chat. In all other cases the
  /// post-response `onComplete` hook handles it.
  void _maybeKickOffTitleEarly(int sessionId, String userContent) {
    if (_sessionController.currentSession.title != 'New Session') return;
    if (_shouldDeferTitleToAfterResponse()) return;
    _sessionController.generateTitle(sessionId, userContent: userContent);
  }

  Future<void> _sendMessage() async {
    final text = textController.text.trim();
    if (text.isEmpty) return;

    final sessionId = _sessionController.currentSessionId;
    final isResponding =
        sessionId != null && _sessionController.runtime(sessionId).isResponding;

    if (text.startsWith('/')) {
      final cmd = findCommand(text.split(' ').first);
      if (isResponding && (cmd == null || !cmd.availableDuringResponse)) {
        return;
      }
      textController.clear();
      _executeCommand(text);
      return;
    }

    // When the agent is streaming, queue the user's message
    // instead of ignoring it. The message will be inserted at
    // the next safe boundary (after a tool round or after the
    // final response). The user can see and discard queued
    // messages in the QueuedMessagesBubble.
    if (isResponding && sessionId != null) {
      _sessionController.enqueueMessage(sessionId, text);
      textController.clear();
      setState(() {});
      return;
    }

    // Sending a "real" (non-`/btw`) message is the explicit
    // signal that the in-memory btw chain must be discarded:
    // once the LLM sees this user prompt in its context, the
    // prior btw rounds would have leaked through. Wipe them
    // BEFORE calling `_sendTurn` so the persisted user message
    // and the fresh in-memory cache line up with a clean chain.
    if (sessionId != null) {
      _sessionController.clearBtwTurnsFor(sessionId);
      _streamingController.clearStreamingFor(sessionId);
    }

    textController.clear();

    await _sendTurn(text: text);
  }

  /// Drive a single chat turn. When [text] is non-null, [text] is
  /// used as the new user prompt and is persisted to the DB and
  /// prepended to the in-memory cache. When [text] is `null`, the
  /// existing conversation history is re-submitted as-is — no new
  /// user message is added, the in-memory cache is left alone, and
  /// the LLM is called with whatever the persisted wire-format
  /// history currently ends on (so a trailing tool result round-
  /// trips cleanly without an artificial user turn being injected).
  /// Used by `_sendMessage` (text != null) and by `/continue` /
  /// `/retry` (text may be null for continue-on-tool-result).
  /// No-ops silently when there is no current session or the
  /// session is already responding.
  Future<void> _sendTurn({String? text}) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    // Guard: if the chat service still considers this session active
    // (e.g. after a recent interrupt that hasn't fully propagated),
    // wait briefly for it to clear. This prevents a race where a
    // new turn starts before the old one has fully exited.
    if (_chatService.isStreaming(sessionId)) {
      // Wait up to 500ms for the old stream to finish cancelling.
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!_chatService.isStreaming(sessionId)) break;
      }
      // If still streaming after 500ms, bail out — the cancel
      // should have propagated by now.
      if (_chatService.isStreaming(sessionId)) return;
    }

    _streamingController.clearStreamingFor(sessionId);

    // Clear the interrupted session flag — we're starting a fresh turn,
    // so any previous interrupt is no longer relevant for callback guards.
    // The rt.interrupted flag is handled separately below (for injecting
    // the system message into the LLM context).
    _interruptedSessions.remove(sessionId);

    final toolDefsTokens = estimateToolDefsTokens(_toolRegistry.toApiTools());
    // When continuing, the "turn base" is the existing persisted
    // history alone (no new user message to add). When submitting
    // fresh text, include the new message's estimated token cost
    // so the context bar reflects the in-flight turn.
    final userTokens = text == null ? 0 : estimateTokens(text);
    final turnBase =
        _sessionController.computeBaseContext(sessionId) +
        userTokens +
        toolDefsTokens;
    rt.turnBaseTokens = turnBase;
    rt.accumulatedToolTokens = 0;
    rt.contextTargetTokens = turnBase;
    rt.contextDisplayTokens = turnBase.toDouble();
    _streamingController.stopContextAnimation();

    rt.isResponding = true;
    rt.responseStartTime = DateTime.now();
    rt.ttftMs = 0.0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0.0;
    rt.tokCount = 0.0;
    rt.firstTokenTime = null;
    rt.cumulativeGenMs = 0.0;
    rt.cumulativeCompletionTokens = 0;
    rt.roundFirstTokenTime = null;
    rt.roundStreaming = false;

    _streamingController.startMetricsTimer(sessionId);
    if (text != null) {
      // If the previous response was interrupted, inject a system
      // message before the user's new input so the LLM knows its
      // prior response was cut off. This gives the model context
      // about why the conversation shifted direction and allows it
      // to respond appropriately (e.g. not repeating the interrupted
      // content, or acknowledging the interruption).
      if (rt.interrupted) {
        rt.interrupted = false;
        const interruptionNotice =
            'Your response was interrupted by user. The user is now '
            'sending a new message. Do not repeat or continue the '
            'interrupted response unless the user explicitly asks.';
        await _store.addMessage(
          sessionId,
          role: 'system',
          content: interruptionNotice,
        );
      }

      final userMsg = Message(
        id: -1,
        sessionId: sessionId,
        role: 'user',
        content: text,
      );
      _sessionController.messageCache[sessionId] = [
        ...?_sessionController.messageCache[sessionId],
        userMsg,
      ];
      setState(() {});

      // Only kick off the auxiliary title generator for genuinely
      // new user input; a continuation shouldn't change the session
      // title.
      _maybeKickOffTitleEarly(sessionId, text);
    }

    _chatService.sendMessage(
      sessionId: sessionId,
      userContent: text,
      session: _sessionController.currentSession,
      runtime: rt,
      onDelta: (delta) {
        if (_interruptedSessions.contains(sessionId)) return;
        if (_streamingController.streamingContentFor(sessionId).isEmpty) {
          rt.contentStartTime = DateTime.now();
        }
        _streamingController.appendStreamingContent(sessionId, delta);
      },
      onReasoning: (reasoning) {
        if (_interruptedSessions.contains(sessionId)) return;
        _streamingController.appendStreamingReasoning(sessionId, reasoning);
      },
      onChunk: () {
        if (_interruptedSessions.contains(sessionId)) return;
        final streamingTokens = estimateTokens(
          _streamingController.streamingContentFor(sessionId) +
              _streamingController.streamingReasoningFor(sessionId),
        );
        rt.contextTargetTokens =
            rt.turnBaseTokens + rt.accumulatedToolTokens + streamingTokens;
        if (!_streamingController.contextAnimTimerIsActive()) {
          _streamingController.startContextAnimation();
        }
        setState(() {});
      },
      onToolRound: (int toolResultTokens) {
        if (_interruptedSessions.contains(sessionId)) return;
        final streamingTokens = estimateTokens(
          _streamingController.streamingContentFor(sessionId) +
              _streamingController.streamingReasoningFor(sessionId),
        );
        rt.accumulatedToolTokens += streamingTokens + toolResultTokens;
        _streamingController.clearStreamingFor(sessionId);
        rt.contextTargetTokens = rt.turnBaseTokens + rt.accumulatedToolTokens;
        rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
        _sessionController.loadMessages(sessionId).then((_) => setState(() {}));
      },
      onToolUse: (ToolUseChunk chunk) {
        if (_interruptedSessions.contains(sessionId)) return;
        // Fold the raw tool_use delta into the streaming controller's
        // per-session, per-index in-progress tool call state. The
        // [StreamingController] is the source of truth for the live
        // streaming bubble — it re-emits a stable snapshot of the
        // in-flight call (id, name, accumulated JSON) so the bubble
        // can render a per-tool "ToolName (~Nt)" row that materializes
        // as the LLM streams the arguments. `onChunk` is what
        // actually triggers a `setState`; we just update the
        // controller's state here. The row is cleared by `onToolRound`
        // (round end) and `onComplete` (turn end).
        _streamingController.updateStreamingToolCall(sessionId, chunk);
      },
      // Queue drain callback: the chat service calls this at every
      // safe insertion boundary (after each tool round, and after the
      // final response). If the user queued messages while the agent
      // was streaming, this returns the merged content string which
      // the chat service injects into the API messages and the store.
      onQueueDrain: () => _sessionController.drainMessageQueue(sessionId),
      onAbortSignal: (signal) {
        _activeAbortSignals.putIfAbsent(sessionId, () => []).add(signal);
      },
      onComplete: (response) async {
        // If the user interrupted this session's response, _interruptResponse
        // already handled all cleanup (persisting partial content, resetting
        // state, clearing the queue). Skip the normal completion logic to
        // avoid persisting duplicate messages or clobbering the interrupt
        // handler's work.
        if (_interruptedSessions.contains(sessionId)) {
          _interruptedSessions.remove(sessionId);
          _activeAbortSignals.remove(sessionId);
          return;
        }
        _streamingController.clearStreamingFor(sessionId);
        _streamingController.stopMetricsTimer(sessionId);
        _activeAbortSignals.remove(sessionId);
        rt.turnBaseTokens = 0;
        rt.accumulatedToolTokens = 0;
        final msgs = await _store.getMessages(sessionId);
        _sessionController.messageCache[sessionId] = msgs;
        if (response.promptTokens + response.completionTokens > 0) {
          final finalTokens = _sessionController.computeBaseContext(sessionId);
          rt.contextTargetTokens = finalTokens;
          rt.contextDisplayTokens = finalTokens.toDouble();
          _streamingController.stopContextAnimation();
        }
        final hit = response.promptCacheHitTokens;
        final total = response.promptTokens;
        final miss = response.promptCacheMissTokens;
        final nonCached = total - hit;
        if (total > 0 && hit > 0 && nonCached > 0) {
          rt.cacheHitPct = ((hit / total) * 100).round();
        } else if (total > 0 && miss > 0 && hit == 0) {
          rt.cacheHitPct = 0;
        } else {
          rt.cacheHitPct = null;
        }
        setState(() {});
        if (_sessionController.currentSession.title == 'New Session') {
          _sessionController.generateTitle(sessionId);
        }
        final lastAiMsg = msgs.lastWhere(
          (m) => m.role == 'ai',
          orElse: () =>
              Message(id: -1, sessionId: sessionId, role: 'ai', content: ''),
        );
        if (lastAiMsg.id > 0 && lastAiMsg.content.isNotEmpty) {
          _maybeGenerateTldr(sessionId, lastAiMsg);
        }
        // If the user queued a message during the final response
        // (drained by the chat service's onQueueDrain callback at
        // the end of the turn), persist it and kick off a new turn
        // so the queued message reaches the LLM without the user
        // having to re-submit.
        if (response.queuedMessage != null &&
            response.queuedMessage!.isNotEmpty) {
          // Persist the queued message to the store and update
          // the in-memory cache so it appears in the UI before
          // the next turn starts.
          await _store.addMessage(
            sessionId,
            role: 'user',
            content: response.queuedMessage!,
          );
          final updatedMsgs = await _store.getMessages(sessionId);
          _sessionController.messageCache[sessionId] = updatedMsgs;
          setState(() {});
          // Start a new turn with null userContent — the message
          // is already in the history.
          await _sendTurn(text: null);
        }
      },
      onError: (error) {
        // If the user interrupted, the error from the cancelled stream
        // is expected — skip showing it as a toast.
        if (_interruptedSessions.contains(sessionId)) {
          _activeAbortSignals.remove(sessionId);
          return;
        }
        _streamingController.stopMetricsTimer(sessionId);
        _toastKey.currentState?.show(error, mode: ToastMode.error);
      },
    );
  }

  /// Drive a single `/btw` turn. The user prompt is shown in a
  /// boxed, dim `BtwBubble.user` and the LLM's streamed response in
  /// a `BtwBubble.ai` (the renderer in `_buildMessageList` branches
  /// on [SessionRuntimeState.btwMode] to pick the boxed variant
  /// instead of the regular `StreamingBubble`). Nothing is written
  /// to the database. On completion the `(prompt, response)` pair
  /// is appended to [SessionController.btwBuffer] so the *next*
  /// `/btw` can see it as context.
  ///
  /// Must be a no-op (with a toast surfaced by the executor) when
  /// the session is already responding. Unlike `_sendTurn`, this
  /// does NOT persist anything — the in-memory cache is untouched
  /// and the DB never sees a `role: 'user'` row for the prompt.
  Future<void> _sendBtwTurn(String prompt) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    // Resolve the provider / model for the current session. The
    // btw round always uses the session's main chat model (NOT the
    // auxiliary model — that one is reserved for titles and
    // summaries). If there's no API key wired, fail with the same
    // error message the regular chat path uses.
    final session = _sessionController.currentSession;
    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    final providerName = slashIndex > 0
        ? compositeKey.substring(0, slashIndex)
        : '';
    final modelId = slashIndex > 0
        ? compositeKey.substring(slashIndex + 1)
        : compositeKey;
    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) {
      _showToast(
        'No API key for provider "$providerName". Use /provider to connect.',
        mode: ToastMode.error,
      );
      return;
    }

    // Build the wire message list for this btw call:
    //   1. Persisted history, walked through the same wire-format
    //      translation the chat service uses (so tool_call / tool
    //      rounds are correctly represented). Any persisted
    //      `role: 'system'` messages come along for the ride.
    //   2. The in-memory btw chain, flattened as alternating
    //      user / assistant turns. Each user turn is wrapped in
    //      [btwRenderUserMessage] so the model sees the same
    //      "please provide a quick answer…" framing on every
    //      prior btw question and naturally treats the chain
    //      as a self-describing side-question thread.
    //   3. The new prompt as a trailing user turn, also wrapped
    //      in [btwRenderUserMessage] so the model receives the
    //      full framing (not just the raw question text).
    //
    // The btw framing lives in the user message rather than a
    // system prompt, so the LLM sees a single, well-formed
    // user turn per btw round — no special "btw mode" for the
    // model to detect, and the btw chain self-describes
    // through its repeated framing.
    final history = await _store.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = <Map<String, dynamic>>[
      ...ChatService.buildApiMessages(history, wireFamily),
    ];
    final priorBtw = _sessionController.btwTurnsFor(sessionId);
    for (final t in priorBtw) {
      apiMessages.add({
        'role': 'user',
        'content': btwRenderUserMessage(t.userText),
      });
      apiMessages.add({
        'role': 'assistant',
        'content': t.aiText.isEmpty ? null : t.aiText,
      });
    }
    apiMessages.add({'role': 'user', 'content': btwRenderUserMessage(prompt)});

    // Same response-state plumbing as the regular chat turn, so
    // the metrics timer / tok/s / TTFT display in the toolbar
    // work for btw too. Mark `btwMode` on the runtime so the
    // message list renderer picks the boxed bubble variant.
    _streamingController.clearStreamingFor(sessionId);
    rt.isResponding = true;
    rt.btwMode = true;
    rt.responseStartTime = DateTime.now();
    rt.ttftMs = 0.0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0.0;
    rt.tokCount = 0.0;
    rt.firstTokenTime = null;
    rt.cumulativeGenMs = 0.0;
    rt.cumulativeCompletionTokens = 0;
    rt.roundFirstTokenTime = null;
    rt.roundStreaming = false;
    rt.startStreamingTimer();
    _streamingController.startMetricsTimer(sessionId);
    // Push a "pending" pair (prompt, '') into the in-memory chain
    // BEFORE the LLM call starts so the user's prompt renders as
    // a `BtwBubble.user` immediately, even before the first
    // delta arrives. The chat panel updates the AI side of this
    // same pair in place as deltas stream in, so we never
    // duplicate the prompt or the answer in the list.
    _sessionController.appendPendingBtwTurn(sessionId, prompt);
    setState(() {});

    // Btw is a text-only side-channel: we don't expose tools, so
    // the LLM has no way to read files or run commands even if it
    // tried. The user message itself carries the "please provide
    // a quick answer…" framing (see [btwRenderUserMessage]), so
    // the model treats the round as a quick side-question
    // without project actions. The stream is consumed directly
    // by LlmClient.streamChat — we don't go through ChatService
    // because that one persists, which is exactly
    // what btw is trying to avoid.
    final llmClient = LlmClient();
    final buffer = StringBuffer();
    String? streamError;
    try {
      final modelConfig = provider.modelById(modelId);
      final stream = llmClient.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: List<Map<String, dynamic>>.from(apiMessages),
        thinkingMode: rt.thinkingMode,
        reasoningEffort: rt.reasoningEffort,
        thinkingBudget: modelConfig?.thinkingBudget,
        maxTokens: modelConfig?.maxTokens,
        // tools intentionally omitted — btw is a pure text exchange
        userId: '${InstallSlug.slug}-$sessionId',
      );
      var firstTokenEver = true;
      await for (final chunk in stream) {
        // Check if the user interrupted this btw turn.
        if (_btwCancelFlags[sessionId] == true) {
          _btwCancelFlags.remove(sessionId);
          break;
        }
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        final deltaText = chunk.textDelta;
        final deltaReasoning = chunk.reasoningContent;
        if (deltaText != null || deltaReasoning != null) {
          if (!rt.roundStreaming) {
            rt.roundFirstTokenTime = DateTime.now();
            rt.roundStreaming = true;
          }
          if (firstTokenEver && (deltaText != null || deltaReasoning != null)) {
            final now = DateTime.now();
            final elapsed =
                now.difference(rt.responseStartTime!).inMicroseconds / 1000.0;
            rt.ttftMs = elapsed;
            rt.ttftReceived = true;
            rt.firstTokenTime = now;
            firstTokenEver = false;
          }
          if (deltaText != null) {
            buffer.write(deltaText);
            _streamingController.appendStreamingContent(sessionId, deltaText);
            if (_streamingController.streamingContentFor(sessionId).isEmpty) {
              rt.contentStartTime = DateTime.now();
            }
            // Mirror the streaming text into the in-memory btw
            // chain so the `BtwBubble.ai` for the in-flight round
            // updates in place. The streaming controller's
            // per-session string is the source of truth for the
            // live bubble; we copy it on every delta rather than
            // reading-and-restringifying on every render.
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              buffer.toString(),
            );
          }
          if (deltaReasoning != null) {
            _streamingController.appendStreamingReasoning(
              sessionId,
              deltaReasoning,
            );
          }
          setState(() {});
        }
      }
    } finally {
      llmClient.dispose();
    }

    // If the user interrupted this btw turn, _interruptResponse already
    // handled all cleanup (clearing streaming state, resetting rt flags,
    // cleaning up the btw chain). Skip the normal post-stream cleanup
    // to avoid clobbering the interrupt handler's work.
    if (rt.interrupted && !rt.isResponding) {
      return;
    }

    // Btw is meant to be lightweight, so we don't fold the
    // round's wall-clock into cumulativeGenMs / run any post-
    // round tok/s smoothing — the metrics timer's `roundStreaming`
    // gate will tick down the displayed rate on its own.
    rt.roundStreaming = false;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    _streamingController.stopMetricsTimer(sessionId);
    rt.isResponding = false;
    rt.btwMode = false;

    if (streamError != null) {
      _streamingController.clearStreamingFor(sessionId);
      // Drop the pending (prompt, '') pair we pushed into the
      // chain at the start of this turn — it never received an
      // AI reply, so leaving it would leave a half-formed btw
      // chain with an empty AI bubble visible to the user.
      // `clearBtwTurnsFor` wipes the entire chain; if the user
      // had earlier (successful) btw turns, we restore them so
      // they aren't collateral damage.
      final turns = _sessionController.btwTurnsFor(sessionId);
      if (turns.isNotEmpty && turns.last.aiText.isEmpty) {
        _sessionController.clearBtwTurnsFor(sessionId);
        if (turns.length > 1) {
          for (var i = 0; i < turns.length - 1; i++) {
            _sessionController.appendPendingBtwTurn(
              sessionId,
              turns[i].userText,
            );
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              turns[i].aiText,
            );
          }
        }
      }
      _showToast(streamError, mode: ToastMode.error);
      setState(() {});
      return;
    }

    final responseText = buffer.toString();
    _streamingController.clearStreamingFor(sessionId);
    // The in-memory chain was pre-populated with a `(prompt, '')`
    // pair at the start of this turn and the AI side has been
    // mirrored on every delta, so the chain is already accurate.
    // No further mutation is needed; the next `/btw` will pick
    // this turn up as prior context. If the user sends a
    // non-`/btw` message next, `_sendMessage` /
    // `_deleteMessagesFrom` / `SessionController.switchSession`
    // will drop the chain — see those methods for the discard
    // hooks.
    // Touch responseText in a comment to keep dart:io lints
    // happy when build flags strip unused locals.
    assert(responseText.isNotEmpty || streamError == null);
    setState(() {});
  }

  /// Interrupt the currently streaming response. This:
  /// 1. Cancels the LLM stream via ChatService.cancelStream()
  /// 2. Clears all streaming content (reasoning, body, tool calls)
  /// 3. Marks the session runtime as interrupted
  /// 4. Persists whatever partial content was generated as an AI message
  ///    with an interruption indicator
  /// 5. Resets the responding state so the user can send a new message
  void _interruptResponse() {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding) return;

    // Determine if this is a btw turn or a regular chat turn.
    final isBtw = rt.btwMode;

    // 1. Cancel the stream. For regular chat, ChatService.cancelStream()
    //    sets a flag that the agentic loop checks on each iteration.
    //    For btw, we set a flag that the `await for` loop in
    //    `_sendBtwTurn` checks on each chunk.
    //    Also abort any running tool processes (bash, cmd, etc.) so
    //    they don't continue executing after the user interrupted.
    if (isBtw) {
      _btwCancelFlags[sessionId] = true;
    } else {
      _chatService.cancelStream(sessionId);
    }

    // Abort any running tool processes (bash, cmd, powershell, etc.)
    // so they stop immediately instead of running to completion.
    // This also kills background children via process group SIGTERM.
    ShellProcessRegistry.instance.killAll(sessionId);
    final signals = _activeAbortSignals.remove(sessionId);
    if (signals != null) {
      for (final signal in signals) {
        signal.abort();
      }
    }

    // 2. Capture whatever was streamed so far so we can persist it.
    final partialContent = _streamingController.streamingContentFor(sessionId);
    final partialReasoning = _streamingController.streamingReasoningFor(sessionId);

    // 3. Clear streaming state immediately so the UI updates.
    _streamingController.clearStreamingFor(sessionId);
    _streamingController.stopMetricsTimer(sessionId);
    _streamingController.stopContextAnimation();

    // 4. Reset the responding state and mark as interrupted.
    rt.isResponding = false;
    rt.btwMode = false;
    rt.interrupted = true;
    rt.roundStreaming = false;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    rt.cancelTimers();

    // Mark this session as interrupted so the onComplete / onError
    // callbacks in _sendTurn know to skip their work (we already
    // handled cleanup here).
    _interruptedSessions.add(sessionId);

    // Recompute context tracking from persisted messages rather than
    // zeroing — the context bar should reflect the actual token count
    // including the partial AI message we just persisted.
    final baseTokens = _sessionController.computeBaseContext(sessionId);
    rt.contextTargetTokens = baseTokens;
    rt.contextDisplayTokens = baseTokens.toDouble();

    if (isBtw) {
      // For btw: clean up the in-memory chain. Drop the pending
      // (prompt, '') pair that was pushed at the start of the turn
      // since the AI response was interrupted and never completed.
      final turns = _sessionController.btwTurnsFor(sessionId);
      if (turns.isNotEmpty && turns.last.aiText.isEmpty) {
        _sessionController.clearBtwTurnsFor(sessionId);
        // Restore any prior completed turns.
        if (turns.length > 1) {
          for (var i = 0; i < turns.length - 1; i++) {
            _sessionController.appendPendingBtwTurn(
              sessionId,
              turns[i].userText,
            );
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              turns[i].aiText,
            );
          }
        }
      }
    } else {
      // For regular chat: persist the partial AI message (if any
      // content was generated) with an interruption indicator.
      if (partialContent.isNotEmpty || partialReasoning.isNotEmpty) {
        final interruptedContent = partialContent.isNotEmpty
            ? '$partialContent\n\n*[Response interrupted by user]*'
            : '*[Response interrupted by user]*';

        _store.addMessage(
          sessionId,
          role: 'ai',
          content: interruptedContent,
          reasoningContent: partialReasoning,
        ).then((_) {
          _sessionController.loadMessages(sessionId).then((_) => setState(() {}));
        });
      }

      // Drain any queued messages back into the input field so the user
      // can edit and re-send them. Each queued message is joined with
      // newlines, and any existing text in the input is appended after.
      final queue = _sessionController.messageQueueFor(sessionId);
      if (queue.isNotEmpty) {
        final queuedTexts = queue.messages.map((m) => m.content).join('\n');
        final currentInput = textController.text;
        final newInput = currentInput.isEmpty
            ? queuedTexts
            : '$queuedTexts\n$currentInput';
        textController.text = newInput;
        textController.selection = TextSelection.collapsed(
          offset: newInput.length,
        );
        _sessionController.clearMessageQueue(sessionId);
      }

      // Update session status.
      final session = _sessionController.currentSession;
      _store.update(sessionId, status: SessionStatus.idle);
      session.status = SessionStatus.idle;
    }

    _showToast('Response interrupted', mode: ToastMode.status);
    setState(() {});
  }

  /// Return the most recent user-role message in the current
  /// session, or `null` if there isn't one.
  ///
  /// Reloads from the DB rather than reading the in-memory cache
  /// because the cache holds a `Message` with `id: -1` for any user
  /// message that was just submitted and whose turn hasn't reached
  /// `onComplete` yet. The executor then uses this id as the lower
  /// bound for [SessionStore.deleteMessagesFrom] (called by `/retry`)
  /// and to decide whether the last round is still "in progress" vs.
  /// already finished (called by `/continue`). Both decisions need
  /// the real DB id — using a placeholder would either delete every
  /// message in the session (`id >= -1`) or silently mis-classify an
  /// interrupted turn as a finished one.
  Future<Message?> _findLastUserMessage() async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return null;
    final messages = await _store.getMessages(sessionId);
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  /// Delete every persisted message in the current session from
  /// [fromId] onwards (the boundary message itself included) and
  /// reload the in-memory cache so the UI reflects the wipe before
  /// the next action runs. The [fromId] is typically the id of the
  /// last user message — `/retry` calls this with that id so the
  /// user message can be re-persisted as a fresh attempt.
  ///
  /// Also drops the in-memory `/btw` chain for the session: `/retry`
  /// is the user explicitly saying "throw away the last round and
  /// start over", and any btw content accumulated alongside that
  /// round is no longer meaningful. Note that
  /// [CommandExecutor.executeRetry] calls `clearBtwTurns` too as
  /// belt-and-braces, but we do it here as well so the chain is
  /// gone even if a future caller invokes this hook directly.
  Future<void> _deleteMessagesFrom(int fromId) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    await _store.deleteMessagesFrom(sessionId, fromId);
    _sessionController.clearBtwTurnsFor(sessionId);
    await _sessionController.loadMessages(sessionId);
    setState(() {});
  }

  Future<void> _executeCommand(String text) async {
    final ctx = CommandContext(
      store: _store,
      providerService: _providerService,
      providerServiceReady: _providerServiceReady,
      currentSession: _sessionController.currentSession,
      currentSessionId: _sessionController.currentSessionId,
      sessions: _sessionController.sessions,
      currentMessages: _sessionController.currentMessages,
      projectPath: Directory.current.path,
      refresh: _refresh,
      showToast: _showToast,
      switchSession: _switchSession,
      initSessions: _initSessions,
      createNewSession: _createNewSession,
      runtime: _sessionController.runtime,
      persistThinkingLevel: _sessionController.persistThinkingLevel,
      resolveAuxiliaryModel: _sessionController.resolveAuxiliaryModel,
      triggerTldr: (sessionId, aiMsg, detail) {
        _maybeGenerateTldr(sessionId, aiMsg, force: true, detail: detail);
      },
      themeController: component.themeController,
      sendTurn: _sendTurn,
      findLastUserMessage: _findLastUserMessage,
      deleteMessagesFrom: _deleteMessagesFrom,
      sendBtwTurn: _sendBtwTurn,
      clearBtwTurns: _sessionController.clearBtwTurnsFor,
    );
    await _commandExecutor.execute(text, ctx);
    setState(() {});
  }

  Future<void> _createNewSession() async {
    final model = _providerService.resolveDefaultModel() ?? '';
    final session = await _store.create(
      title: 'New Session',
      model: model,
      projectPath: Directory.current.path,
    );
    _sessionController.sessions = await _store.list(
      projectPath: Directory.current.path,
    );
    await _switchSession(session.id);
  }

  Future<void> _maybeGenerateTldr(
    int sessionId,
    Message aiMsg, {
    bool force = false,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    final rt = _sessionController.runtime(sessionId);
    final hasAuxModel =
        _providerService.auxiliaryModel != null &&
        _providerService.auxiliaryModel != 'none';

    if (!hasAuxModel) {
      if (force) {
        _showToast(
          'No auxiliary model — set one with /auxiliary',
          mode: ToastMode.error,
        );
      }
      setState(() {});
      return;
    }

    if (!force) {
      final threshold = _providerService.tldrThreshold;
      if (aiMsg.content.length < threshold) return;
      if (aiMsg.tldr.isNotEmpty) return;
    } else if (rt.isGeneratingTldr) {
      // Manual /tldr while a generation is already running: ignore.
      return;
    }

    // Manual regeneration: clear the cached tldr on the in-memory message so
    // the bubble re-enters its generating state immediately.
    if (force && aiMsg.tldr.isNotEmpty) {
      await _store.updateMessageTldr(aiMsg.id, '');
      final msgs = _sessionController.messageCache[sessionId];
      if (msgs != null) {
        for (var i = 0; i < msgs.length; i++) {
          if (msgs[i].id == aiMsg.id) {
            msgs[i] = Message(
              id: msgs[i].id,
              sessionId: msgs[i].sessionId,
              role: msgs[i].role,
              content: msgs[i].content,
              reasoningContent: msgs[i].reasoningContent,
              reasoningSignature: msgs[i].reasoningSignature,
              reasoningTokens: msgs[i].reasoningTokens,
              thinkingDurationMs: msgs[i].thinkingDurationMs,
              reasoningEffort: msgs[i].reasoningEffort,
              model: msgs[i].model,
              cost: msgs[i].cost,
              tokensIn: msgs[i].tokensIn,
              tokensOut: msgs[i].tokensOut,
              error: msgs[i].error,
              parentMsgId: msgs[i].parentMsgId,
              createdAt: msgs[i].createdAt,
              toolCalls: msgs[i].toolCalls,
              toolCallId: msgs[i].toolCallId,
              tldr: '',
            );
            break;
          }
        }
      }
    }

    rt.isGeneratingTldr = true;
    setState(() {});

    final tldrText = await _chatService.generateTldr(
      aiMsg.content,
      detail: detail,
    );
    rt.isGeneratingTldr = false;
    if (tldrText != null && tldrText.isNotEmpty) {
      await _store.updateMessageTldr(aiMsg.id, tldrText);
      final msgs = _sessionController.messageCache[sessionId];
      if (msgs != null) {
        for (var i = 0; i < msgs.length; i++) {
          if (msgs[i].id == aiMsg.id) {
            msgs[i] = Message(
              id: msgs[i].id,
              sessionId: msgs[i].sessionId,
              role: msgs[i].role,
              content: msgs[i].content,
              reasoningContent: msgs[i].reasoningContent,
              reasoningSignature: msgs[i].reasoningSignature,
              reasoningTokens: msgs[i].reasoningTokens,
              thinkingDurationMs: msgs[i].thinkingDurationMs,
              reasoningEffort: msgs[i].reasoningEffort,
              model: msgs[i].model,
              cost: msgs[i].cost,
              tokensIn: msgs[i].tokensIn,
              tokensOut: msgs[i].tokensOut,
              error: msgs[i].error,
              parentMsgId: msgs[i].parentMsgId,
              createdAt: msgs[i].createdAt,
              toolCalls: msgs[i].toolCalls,
              toolCallId: msgs[i].toolCallId,
              tldr: tldrText,
            );
            break;
          }
        }
      }
    }
    setState(() {});
  }

  Component _buildSessionManager() {
    return SessionManagementPanel(
      sessions: _sessionController.sessions,
      currentSessionId: _sessionController.currentSessionId ?? 0,
      statusResolver: _sessionController.effectiveStatus,
      onDeleteSession: (id) async {
        await _sessionController.deleteSession(id);
        setState(() {});
      },
      onRenameSession: (id, title) async {
        await _sessionController.renameSession(id, title);
        setState(() {});
      },
      onSwitchSession: (id) {
        _switchSession(id);
        setState(() {
          _overlayController.showSessionManager = false;
        });
      },
      onDismiss: () {
        setState(() {
          _overlayController.showSessionManager = false;
        });
      },
    );
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastContentWidth = constraints.maxWidth.toInt();
        final showInfoPanel = constraints.maxWidth >= _infoPanelShowThreshold;

        if (showInfoPanel) {
          // Grow the panel at 30% of the surplus terminal width beyond
          // _infoPanelShowThreshold, from _infoPanelWidthMin →
          // _infoPanelWidthMax, then clamp. At terminal width 140
          // the panel hits its max of 40.
          final panelWidth = (_infoPanelWidthMin +
                  0.3 *
                      (constraints.maxWidth -
                          _infoPanelShowThreshold))
              .clamp(_infoPanelWidthMin, _infoPanelWidthMax);
          final mainContent = Row(
            children: [
              Expanded(child: _buildMainInterface()),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: CruxTheme.of(context).divider,
              ),
              SizedBox(
                width: panelWidth,
                child: ExtraInfoPanel(
                  sessions: _sessionController.sessions,
                  currentSessionId: _sessionController.currentSessionId ?? 0,
                  onSwitchSession: _switchSession,
                  archivedCount: _sessionController.archivedCount,
                  statusResolver: _sessionController.effectiveStatus,
                  onSessionTitleTap: () {
                    setState(() {
                      _overlayController.showSessionManager = true;
                    });
                  },
                  onOpenProject: _openProjectInExplorer,
                  onSwitchProject: _switchProject,
                ),
              ),
            ],
          );

          if (_overlayController.showSessionManager) {
            return Stack(
              children: [
                Positioned.fill(child: mainContent),
                Positioned.fill(child: _buildSessionManager()),
              ],
            );
          }

          return mainContent;
        }

        if (_overlayController.showSessionManager) {
          return Stack(
            children: [
              Positioned.fill(child: _buildMainInterface()),
              Positioned.fill(child: _buildSessionManager()),
            ],
          );
        }

        return _buildMainInterface();
      },
    );
  }

  Component _buildMainInterface() {
    final children = <Component>[];

    // Build overlay components that float above the message list
    // without pushing it up. They are positioned at the bottom of the
    // message area so they sit just above the toolbar.
    final overlays = <Component>[];

    if (_overlayController.overlayMode == OverlayMode.command &&
        _overlayController.filteredCommands.isNotEmpty) {
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: _onScrollCommand,
            opaque: false,
            child: CommandOverlay(
              commands: _overlayController.filteredCommands,
              selectedIndex: _overlayController.selectedCommandIndex,
              scrollOffset: _overlayController.commandScrollOffset,
              maxVisible: _maxVisibleItems,
              onHover: _onHoverCommand,
              onTap: _onTapCommand,
            ),
          ),
        ),
      );
    } else if (_overlayController.overlayMode == OverlayMode.parameter &&
        _overlayController.filteredSuggestions.isNotEmpty) {
      final paramLabel =
          _overlayController.currentParamIndex <
              _overlayController.activeCommand!.params.length
          ? _overlayController.activeCommand!.params[_overlayController
                .currentParamIndex]
          : 'value';
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: _onScrollSuggestion,
            opaque: false,
            child: SuggestionOverlay(
              suggestions: _overlayController.filteredSuggestions,
              selectedIndex: _overlayController.selectedSuggestionIndex,
              scrollOffset: _overlayController.suggestionScrollOffset,
              maxVisible: _maxVisibleItems,
              headerLabel: paramLabel,
              onHover: _onHoverSuggestion,
              onTap: _onTapSuggestion,
            ),
          ),
        ),
      );
    }

    // Toast hub always present — manages its own queue and visibility.
    overlays.add(
      Positioned(bottom: 0, left: 0, right: 0, child: ToastHub(key: _toastKey)),
    );

    // Wrap the message list with its floating overlays in a Stack
    // so the overlays render on top without affecting layout.
    children.add(
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [_buildMessageList(), ...overlays],
        ),
      ),
    );

    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isStreaming = rt?.isResponding ?? false;

    children.add(_buildToolbar());
    children.add(Divider(color: CruxTheme.of(context).divider, height: 1));
    children.add(_buildInputRow(isStreaming: isStreaming));

    return Column(children: children);
  }

  Component _buildMessageList() {
    final messages = _sessionController.currentMessages;
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isStreaming = rt?.isResponding ?? false;

    final lastRoundStart = isStreaming
        ? -1
        : messages.lastIndexWhere((m) => m.role == 'user');

    final resultByCallId = <String, Message>{};
    for (final m in messages) {
      if (m.role == 'tool' && m.toolCallId.isNotEmpty) {
        resultByCallId[m.toolCallId] = m;
      }
    }

    if (messages.isEmpty && !isStreaming) {
      // A session can be "empty on disk" but still have a
      // `/btw` chain in memory (the chain lives only in
      // [SessionController.btwBuffer]). Show the chain rather
      // than the empty-state placeholder in that case so the
      // user doesn't lose their scratch space to a blank panel.
      final hasBtwTurns =
          sessionId != null &&
          _sessionController.btwTurnsFor(sessionId).isNotEmpty;
      if (!hasBtwTurns) {
        return Center(
          child: Text(
            'No messages yet.',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
        );
      }
    }

    final items = <Component>[];
    final userItemIndices = <int>[];
    final userItemLabels = <String>[];
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final collapsed = i < lastRoundStart;
      Message? pairedResult;
      if (msg.role == 'tool_call') {
        for (final tc in msg.toolCalls) {
          if (resultByCallId.containsKey(tc.callId)) {
            pairedResult = resultByCallId[tc.callId]!;
            break;
          }
        }
      }

      if (msg.role == 'user') {
        userItemIndices.add(items.length);
        final text = msg.content.replaceAll('\n', ' ').trim();
        userItemLabels.add(text);
      }

      items.add(
        MessageBubble(
          message: msg,
          reasoningCollapsed: collapsed,
          pairedResult: pairedResult,
          toolRegistry: _toolRegistry,
          highlightText: msg.id == _highlightMessageId ? _highlightText : null,
          reasoningPresets: _currentReasoningPresets(),
        ),
      );

      if (msg.role == 'ai' && msg.id > 0 && rt != null) {
        final hasTldr = msg.tldr.isNotEmpty;
        if (hasTldr || rt.isGeneratingTldr) {
          final headings = extractHeadings(msg.content);
          final aiMessageItemIndex = items.length - 1;
          final aiMessageId = msg.id;
          final aiMessageContent = msg.content;
          items.add(Divider(color: CruxTheme.of(context).divider, height: 1));
          items.add(
            TldrBubble(
              tldrText: msg.tldr,
              headings: headings,
              isGenerating: rt.isGeneratingTldr && !hasTldr,
              hasAuxiliaryModel:
                  _providerService.auxiliaryModel != null &&
                  _providerService.auxiliaryModel != 'none',
              onHeadingTap: (heading, url) => _handleTldrReferenceTap(
                itemIndex: aiMessageItemIndex,
                messageId: aiMessageId,
                messageContent: aiMessageContent,
                heading: heading,
                url: url,
              ),
            ),
          );
          items.add(Divider(color: CruxTheme.of(context).divider, height: 1));
        } else {
          final nextIsUser =
              i + 1 < messages.length && messages[i + 1].role == 'user';
          if (nextIsUser) {
            items.add(Divider(color: CruxTheme.of(context).divider, height: 1));
          }
        }
      }
    }

    // Render the in-memory `/btw` chain after the persisted
    // messages but before any in-flight streaming bubble. Each
    // completed turn is a pair of `BtwBubble.user` + `BtwBubble.ai`
    // (boxed, dim) so the user can see at a glance that this
    // content is off-the-record. We render even when the session
    // is also streaming a *real* turn, because the btw chain is
    // conceptually a separate side-channel sitting next to the
    // main conversation.
    //
    // Special case for the in-flight btw round: `_sendBtwTurn`
    // pre-populates the chain with a `(prompt, '')` pair at the
    // start of the turn, then mirrors the streaming text into the
    // `aiText` slot on every delta. We therefore *skip* the
    // pending pair's `BtwBubble.ai` here and let the trailing
    // streaming `BtwBubble.ai` (added below) take its place — it
    // shows the same text but is wired up to the streaming
    // controller for live updates and a clean "Crux ✦" vs "btw
    // ✦" prefix.
    if (sessionId != null) {
      final btwTurns = _sessionController.btwTurnsFor(sessionId);
      final lastIndex = btwTurns.length - 1;
      for (var i = 0; i < btwTurns.length; i++) {
        final turn = btwTurns[i];
        items.add(BtwBubble.user(content: turn.userText));
        final isPendingLast =
            i == lastIndex && (rt?.btwMode ?? false) && isStreaming;
        if (!isPendingLast) {
          items.add(BtwBubble.ai(content: turn.aiText));
        }
        items.add(SizedBox(height: 1));
      }
    }

    if (isStreaming) {
      // The in-flight stream can be either a normal chat turn or
      // a `/btw` round — the latter is a one-shot ephemeral
      // question, so we render its reply in a boxed `BtwBubble`
      // instead of the regular `StreamingBubble`. The runtime
      // state's `btwMode` flag (set by `_sendBtwTurn`, cleared on
      // completion) is the source of truth for which kind of
      // bubble to show.
      if (rt?.btwMode ?? false) {
        items.add(
          BtwBubble.ai(
            content: _streamingController.streamingContentFor(
              _sessionController.currentSessionId ?? 0,
            ),
            streaming: true,
          ),
        );
      } else {
        items.add(
          StreamingBubble(
            streamingContent: _streamingController.streamingContentFor(
              _sessionController.currentSessionId ?? 0,
            ),
            streamingReasoning: _streamingController.streamingReasoningFor(
              _sessionController.currentSessionId ?? 0,
            ),
            // Live tool-call state. The controller folds each
            // `ToolUseChunk` from `onToolUse` into a per-index
            // accumulator; the bubble renders one row per call
            // (in declared order) so the user sees parallel calls
            // materialize as the LLM streams them. Cleared on
            // round end (`onToolRound`) and turn end (`onComplete`).
            streamingToolCalls: _streamingController.streamingToolCallsFor(
              _sessionController.currentSessionId ?? 0,
            ),
            toolRegistry: _toolRegistry,
            runtimeState: rt,
          ),
        );
      }
    }

    // Render queued messages when the agent is streaming. The
    // bubble shows each queued message with a discard button.
    // Messages are inserted into the conversation at the next
    // safe boundary (after a tool round or final response).
    if (sessionId != null && isStreaming) {
      final queue = _sessionController.messageQueueFor(sessionId);
      if (queue.isNotEmpty) {
        items.add(SizedBox(height: 1));
        items.add(
          QueuedMessagesBubble(
            messages: queue.messages,
            onDiscard: (queueId) {
              _sessionController.discardQueuedMessage(sessionId, queueId);
              setState(() {});
            },
          ),
        );
      }
    }

    final markers = List.generate(userItemIndices.length, (i) {
      return ScrollbarMarker(
        itemIndex: userItemIndices[i],
        color: CruxTheme.of(context).userPrefix,
        label: userItemLabels[i],
      );
    });

    return SelectionArea(
      onSelectionCompleted: (text) {
        if (text.isNotEmpty) {
          ClipboardManager.copy(text);
        }
      },
      child: AnnotatedScrollbar(
        controller: scrollController,
        thumbVisibility: true,
        markers: markers,
        tooltipBackgroundColor: CruxTheme.of(context).overlayBackground,
        child: ListView.builder(
          controller: scrollController,
          padding: EdgeInsets.all(1),
          itemCount: items.length,
          itemBuilder: (context, index) => items[index],
        ),
      ),
    );
  }

  Component _buildToolbar() {
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final modelLabel = _sessionController.currentSession.model.isEmpty
        ? 'select model'
        : _sessionController.currentSession.model;
    final modelButton = (rt?.isResponding ?? false)
        ? GlossyModelButton(
            label: modelLabel,
            isAnimating: true,
            onPressed: _onModelButtonPressed,
          )
        : Button(
            label: modelLabel,
            onPressed: _onModelButtonPressed,
            color: CruxTheme.of(context).onSurfaceVariant,
            hoverColor: CruxTheme.of(context).buttonTextHover,
            bgColor: CruxTheme.of(context).buttonBackground,
            hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        const btnPad = 2;
        const spacer = 2;
        const smallSpacer = 1;

        final modelW = UnicodeWidth.stringWidth(modelLabel) + btnPad;
        final imageW =
            _modelSupportsImages(_sessionController.currentSession.model)
            ? UnicodeWidth.stringWidth('\u{F06E}')
            : 0;
        final thinkingLabel =
            (rt != null &&
                _modelSupportsThinking(_sessionController.currentSession.model))
            ? _thinkingLabel(rt)
            : null;
        final thinkingW = thinkingLabel != null
            ? UnicodeWidth.stringWidth(thinkingLabel) + btnPad
            : 0;
        final contextW = 20 + spacer;
        final isResponding = rt?.isResponding ?? false;
        final tokText = isResponding && rt != null
            ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
            : rt != null && rt.tokPerSec > 0
            ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
            : '— tok/s';
        final tokW = UnicodeWidth.stringWidth(tokText) + spacer;
        final ttftText = isResponding && rt != null
            ? _streamingController.formatTtft(rt.ttftMs)
            : rt != null && rt.ttftMs > 0
            ? _streamingController.formatTtft(rt.ttftMs)
            : '—';
        final ttftW = UnicodeWidth.stringWidth(ttftText) + smallSpacer;
        final auxLabel =
            '\u{F013} ${_sessionController.auxiliaryModelShortName}';
        final auxW = UnicodeWidth.stringWidth(auxLabel) + btnPad;

        var remaining = constraints.maxWidth.toInt() - 2 - modelW - imageW;

        final showThinking =
            thinkingLabel != null && (remaining - thinkingW) >= 0;
        if (showThinking) remaining -= thinkingW;

        final showContext = (remaining - contextW) >= 0;
        if (showContext) remaining -= contextW;

        final showTokPerSec = (remaining - tokW) >= 0;
        if (showTokPerSec) remaining -= tokW;

        final showTtft = (remaining - ttftW) >= 0;
        if (showTtft) remaining -= ttftW;

        final showAux = (remaining - auxW) >= 0;

        return Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            children: [
              modelButton,
              if (_modelSupportsImages(_sessionController.currentSession.model))
                Text(
                  '\u{F06E}',
                  style: TextStyle(
                    color: CruxTheme.of(context).onSurfaceVariant,
                  ),
                ),
              if (showThinking)
                Button(
                  label: thinkingLabel!,
                  onPressed: () => _cycleThinkingLevel(rt!),
                  color: rt!.thinkingMode == 'disabled'
                      ? CruxTheme.of(context).thinkingLabelDisabled
                      : CruxTheme.of(context).onSurfaceVariant,
                  hoverColor: CruxTheme.of(context).buttonTextHover,
                  bgColor: CruxTheme.of(context).buttonBackground,
                  hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
                  padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                ),
              if (showContext) ...[
                Text(
                  '  ',
                  style: TextStyle(color: CruxTheme.of(context).divider),
                ),
                _buildContextBar(),
              ],
              if (showTokPerSec || showTtft)
                MouseRegion(
                  onEnter: (_) => setState(() => _metricsHovered = true),
                  onExit: (_) => setState(() => _metricsHovered = false),
                  opaque: false,
                  child: Row(
                    children: [
                      if (showTokPerSec) ...[
                        Text(
                          '  ',
                          style: TextStyle(
                            color: CruxTheme.of(context).divider,
                          ),
                        ),
                        Text(
                          _metricsHovered
                              ? _cacheHitLabel(
                                  rt,
                                  _sessionController.currentSession,
                                )
                              : tokText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? CruxTheme.of(context).metricsActive
                                : CruxTheme.of(context).metricsIdle,
                          ),
                        ),
                      ],
                      if (showTtft) ...[
                        Text(
                          ' ',
                          style: TextStyle(
                            color: CruxTheme.of(context).divider,
                          ),
                        ),
                        Text(
                          ttftText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? CruxTheme.of(context).metricsActive
                                : CruxTheme.of(context).metricsIdle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(child: SizedBox()),
              if (showAux) _buildAuxiliaryModelButton(),
            ],
          ),
        );
      },
    );
  }

  Component _buildAuxiliaryModelButton() {
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    // Flash the auxiliary label/button while the auxiliary model is
    // working on a background task — either a session title or a TLDR
    // summary — so the user gets the same visual feedback as for the
    // main model during a chat response.
    final isAuxBusy =
        _sessionController.isGeneratingTitle || (rt?.isGeneratingTldr ?? false);
    return GlossyModelButton(
      label: '\u{F013} ${_sessionController.auxiliaryModelShortName}',
      isAnimating: isAuxBusy,
      onPressed: _onAuxiliaryModelButtonPressed,
    );
  }

  void _onAuxiliaryModelButtonPressed() {
    final newText = '/auxiliary ';
    textController.text = newText;
    textController.selection = TextSelection.collapsed(offset: newText.length);
  }

  Component _buildContextBar() {
    if (_sessionController.currentSessionId == null) return const SizedBox();
    final currentSid = _sessionController.currentSessionId!;
    final rt = _sessionController.runtime(currentSid);
    final displayTokens = rt.contextDisplayTokens.round();
    final fillRatio = (displayTokens / _contextMaxTokens).clamp(0.0, 1.0);
    final fmtCtx = (int n) {
      final k = n ~/ 1024;
      final kStr = k.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (m) => ',',
      );
      return '${kStr}k';
    };
    final fmtNum = (int n) => n.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => ',',
    );
    final labelText = _streamingController.contextBarHovered
        ? 'Compact'
        : '${fmtNum(displayTokens)} / ${fmtCtx(_contextMaxTokens)}';

    final bar = BgProgressBar(
      value: fillRatio,
      width: 20,
      label: labelText,
      fillColor: _streamingController.contextBarHovered
          ? CruxTheme.of(context).metricsActive
          : CruxTheme.of(context).progressFill,
      emptyColor: CruxTheme.of(context).progressEmpty,
      labelFillFg: _streamingController.contextBarHovered
          ? CruxTheme.of(context).outlineDim
          : CruxTheme.of(context).buttonBackground,
      labelEmptyFg: _streamingController.contextBarHovered
          ? CruxTheme.of(context).metricsActive
          : CruxTheme.of(context).progressLabelEmpty,
    );

    return MouseRegion(
      onEnter: (_) =>
          setState(() => _streamingController.contextBarHovered = true),
      onExit: (_) =>
          setState(() => _streamingController.contextBarHovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: _onCompactButtonPressed,
        behavior: HitTestBehavior.opaque,
        child: bar,
      ),
    );
  }

  void _onCompactButtonPressed() {
    final newText = '/compact ';
    textController.text = newText;
    textController.selection = TextSelection.collapsed(offset: newText.length);
  }

  void _onModelButtonPressed() {
    final newText = '/model ';
    textController.text = newText;
    textController.selection = TextSelection.collapsed(offset: newText.length);
  }

  /// Resolve the display label for an internal reasoning effort value,
  /// using the current session's provider's [reasoningPresets].
  List<ReasoningPreset> _currentReasoningPresets() {
    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm = _providerService.llmProviderByName(providerName);
    if (llm == null) return const [];
    // Pass just the model ID (after the '/') so providers like MiniMax
    // can match on the model name — e.g. _isM3("MiniMax-M3") works but
    // _isM3("minimax/MiniMax-M3") would not.
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    // Resolve provider-level and model-level label overrides from TOML.
    final provider = _providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    return llm.reasoningPresetsFor(
      modelId,
      providerLabels: provider?.reasoningLabels ?? const {},
      modelLabels: modelConfig?.reasoningLabels ?? const {},
    );
  }

  String _displayEffort(String effort) {
    final presets = _currentReasoningPresets();
    for (final p in presets) {
      if (p.internalValue == effort) return p.displayLabel;
    }
    return effort; // unknown effort: show raw value
  }

  String _thinkingLabel(SessionRuntimeState rt) {
    final effort = rt.thinkingMode == 'disabled'
        ? 'off'
        : _displayEffort(rt.reasoningEffort ?? 'normal');
    return '\u{F0EB} ${effort.padRight(4)}';
  }

  String _cacheHitLabel(SessionRuntimeState? rt, Session session) {
    if (rt?.cacheHitPct != null) {
      return 'cache ${rt!.cacheHitPct}%';
    }
    final hit = session.promptCacheHitTokens;
    final total = session.tokensIn;
    if (total > 0 && hit > 0) {
      return 'cache ${((hit / total) * 100).round()}%';
    }
    return '—';
  }

  void _cycleThinkingLevel(SessionRuntimeState rt) {
    final presets = _currentReasoningPresets();
    if (presets.isEmpty) return;

    final current = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';

    // Find the current level in the presets and advance to the next.
    // If the current level isn't in the presets (e.g. it was disabled
    // after being set), start from the beginning.
    int idx = -1;
    for (var i = 0; i < presets.length; i++) {
      if (presets[i].internalValue == current) {
        idx = i;
        break;
      }
    }

    final next = presets[(idx + 1) % presets.length];
    if (next.internalValue == 'off') {
      rt.thinkingMode = 'disabled';
      rt.reasoningEffort = null;
    } else {
      rt.thinkingMode = 'enabled';
      rt.reasoningEffort = next.internalValue;
    }
    _sessionController.persistThinkingLevel(rt);
    setState(() {});
  }

  void _handleTldrReferenceTap({
    required int itemIndex,
    required int messageId,
    required String messageContent,
    required String heading,
    required String? url,
  }) {
    if (url != null && url.isNotEmpty) {
      final result = openUrl(url);
      switch (result) {
        case UrlLaunchResult.launched:
          return;
        case UrlLaunchResult.rejected:
          _showToast('Refused to open url: $url', mode: ToastMode.error);
          return;
        case UrlLaunchResult.failed:
          _showToast("Couldn't open url: $url", mode: ToastMode.error);
          return;
      }
    }

    setState(() {
      _highlightText = heading;
      _highlightMessageId = messageId;
    });
    _clearHighlightAfterDelay();

    final itemInfo = scrollController.getItemIndexOffsetAndExtent(itemIndex);
    if (itemInfo != null) {
      final lineOffset = _findExcerptLineOffset(messageContent, heading);
      scrollController.jumpTo(itemInfo.$1 + lineOffset);
    }
  }

  double _findExcerptLineOffset(String content, String excerpt) {
    int idx = content.indexOf(excerpt);
    if (idx < 0) {
      final normContent = content.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normExcerpt = excerpt.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normIdx = normContent.indexOf(normExcerpt);
      if (normIdx < 0) return 0;
      int charPos = 0;
      int normPos = 0;
      while (charPos < content.length && normPos < normIdx) {
        final ch = content[charPos];
        charPos++;
        if (ch == ' ' || ch == '\n' || ch == '\t') {
          while (charPos < content.length &&
              (content[charPos] == ' ' ||
                  content[charPos] == '\n' ||
                  content[charPos] == '\t')) {
            charPos++;
          }
        }
        normPos++;
      }
      idx = charPos;
    }
    final textBeforeExcerpt = content.substring(0, idx);
    final maxWidth = _lastContentWidth - 4;
    final config = TextLayoutConfig(
      softWrap: true,
      overflow: TextOverflow.clip,
      maxWidth: maxWidth - 4,
    );
    final result = TextLayoutEngine.layout(textBeforeExcerpt, config);
    return result.actualHeight.toDouble();
  }

  void _clearHighlightAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _highlightText = null;
          _highlightMessageId = null;
        });
      }
    });
  }

  Component _buildInputRow({required bool isStreaming}) {
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final wasInterrupted = rt?.interrupted ?? false;

    // When the agent is streaming, the user's message will be queued
    // and inserted at the next safe boundary. Show both the queue hint
    // and the ESC interrupt shortcut. After the first ESC press, show
    // a more urgent interrupt hint. When the response was interrupted,
    // hint that the user can send a new message.
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
              controller: textController,
              focused: !_overlayController.showSessionManager,
              maxLines: null,
              style: TextStyle(color: CruxTheme.of(context).foreground),
              placeholder: placeholder,
              onKeyEvent: _handleInputKeyEvent,
              wordBoundaryProvider: cjkWordBoundaryProvider,
            ),
          ),
        ],
      ),
    );
  }
}

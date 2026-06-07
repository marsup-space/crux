import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/text/text_layout_engine.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../theme/crux_theme.dart';
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
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/tool_executor.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../tools/file_read_tracker.dart';
import '../utils/token_estimate.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/toast.dart';
import 'ui/bg_progress_bar.dart';
import 'ui/glossy_model_button.dart';
import 'provider_wizard_builtin.dart';
import 'command_overlay.dart';
import 'suggestion_overlay.dart';
import 'extra_info_panel.dart';
import 'session_management_panel.dart';
import 'annotated_scrollbar.dart';
import 'message_bubble.dart';
import 'streaming_bubble.dart';
import 'tldr_bubble.dart';

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  const ChatPanel({
    super.key,
    required this.userProvidersDir,
    this.builtInProvidersDir,
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

  final _toastKey = GlobalKey<ToastHubState>();
  bool _metricsHovered = false;
  String? _highlightText;
  int? _highlightMessageId;
  int _lastContentWidth = 120;

  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  static const int _infoPanelMinWidth = 100;
  static const double _infoPanelWidth = 28;

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
    final toolExecutor = ToolExecutor(registry);
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
    if (_overlayController.overlayMode == OverlayMode.wizard) return;

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
            commandName != '/provider')) {
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
        !(commandName == '/provider' && paramIndex == 0)) {
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

    if (_overlayController.overlayMode == OverlayMode.wizard) {
      return true;
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
  void _maybeKickOffTitleEarly(int sessionId) {
    if (_sessionController.currentSession.title != 'New Session') return;
    if (_shouldDeferTitleToAfterResponse()) return;
    _sessionController.generateTitle(sessionId);
  }

  Future<void> _sendMessage() async {
    if (_overlayController.overlayMode == OverlayMode.wizard) return;

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

    if (isResponding) return;

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

    _streamingController.clearStreamingFor(sessionId);

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
      _maybeKickOffTitleEarly(sessionId);
    }

    _chatService.sendMessage(
      sessionId: sessionId,
      userContent: text,
      session: _sessionController.currentSession,
      runtime: rt,
      onDelta: (delta) {
        if (_streamingController.streamingContentFor(sessionId).isEmpty) {
          rt.contentStartTime = DateTime.now();
        }
        _streamingController.appendStreamingContent(sessionId, delta);
      },
      onReasoning: (reasoning) {
        _streamingController.appendStreamingReasoning(sessionId, reasoning);
      },
      onChunk: () {
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
      onComplete: (response) async {
        _streamingController.clearStreamingFor(sessionId);
        _streamingController.stopMetricsTimer(sessionId);
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
      },
      onError: (error) {
        _streamingController.stopMetricsTimer(sessionId);
        _toastKey.currentState?.show(error, mode: ToastMode.error);
      },
    );
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
  Future<void> _deleteMessagesFrom(int fromId) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    await _store.deleteMessagesFrom(sessionId, fromId);
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
      enterBuiltinWizard: (name) {
        setState(() {
          _overlayController.enterBuiltinWizard(name);
        });
      },
      sendTurn: _sendTurn,
      findLastUserMessage: _findLastUserMessage,
      deleteMessagesFrom: _deleteMessagesFrom,
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
        _showToast('No auxiliary model — set one with /auxiliary', mode: ToastMode.error);
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

  void _dismissWizard({String? message}) {
    setState(() {
      _overlayController.dismissWizard();
      if (message != null) {
        _toastKey.currentState?.show(message, mode: ToastMode.status);
      }
    });
  }

  Component _buildSessionManager() {
    return SessionManagementPanel(
      sessions: _sessionController.sessions,
      currentSessionId: _sessionController.currentSessionId ?? 0,
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

  Component _buildWizardOverlay() {
    final sub = _overlayController.activeWizardSubcommand;
    if (sub == null) return const SizedBox();

    final VoidCallback onComplete = () {
      _dismissWizard(
        message:
            '✓ ${_overlayController.builtinProviderName ?? "Provider"} connected successfully',
      );
    };

    final VoidCallback onDismiss = () => _dismissWizard();

    return ProviderWizardBuiltin(
      service: _providerService,
      providerName: _overlayController.builtinProviderName!,
      onComplete: onComplete,
      onDismiss: onDismiss,
    );
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastContentWidth = constraints.maxWidth.toInt();
        final showInfoPanel = constraints.maxWidth >= _infoPanelMinWidth;

        if (showInfoPanel) {
          final mainContent = Row(
            children: [
              Expanded(child: _buildMainInterface()),
              VerticalDivider(width: 1, thickness: 1, color: CruxTheme.divider),
              SizedBox(
                width: _infoPanelWidth,
                child: ExtraInfoPanel(
                  sessions: _sessionController.sessions,
                  currentSessionId: _sessionController.currentSessionId ?? 0,
                  onSwitchSession: _switchSession,
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

    if (_overlayController.overlayMode == OverlayMode.wizard) {
      children.add(Expanded(child: _buildWizardOverlay()));
      return Column(children: children);
    }

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
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: ToastHub(key: _toastKey),
      ),
    );

    // Wrap the message list with its floating overlays in a Stack
    // so the overlays render on top without affecting layout.
    children.add(
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildMessageList(),
            ...overlays,
          ],
        ),
      ),
    );

    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isStreaming = rt?.isResponding ?? false;

    children.add(_buildToolbar());
    children.add(Divider(color: CruxTheme.divider, height: 1));
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
      return Center(
        child: Text(
          'No messages yet.',
          style: TextStyle(color: CruxTheme.onSurfaceDim),
        ),
      );
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
        ),
      );

      if (msg.role == 'user') {
        items.add(Divider(color: CruxTheme.divider, height: 1));
      }

      if (msg.role == 'ai' && msg.id > 0 && rt != null) {
        final hasTldr = msg.tldr.isNotEmpty;
        if (hasTldr || rt.isGeneratingTldr) {
          final headings = extractHeadings(msg.content);
          final aiMessageItemIndex = items.length - 1;
          final aiMessageId = msg.id;
          final aiMessageContent = msg.content;
          items.add(Divider(color: CruxTheme.divider, height: 1));
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
          items.add(Divider(color: CruxTheme.divider, height: 1));
        } else {
          final nextIsUser = i + 1 < messages.length &&
              messages[i + 1].role == 'user';
          if (nextIsUser) {
            items.add(Divider(color: CruxTheme.divider, height: 1));
          }
        }
      }
    }

    if (isStreaming) {
      items.add(
        StreamingBubble(
          streamingContent: _streamingController.streamingContentFor(
            _sessionController.currentSessionId ?? 0,
          ),
          streamingReasoning: _streamingController.streamingReasoningFor(
            _sessionController.currentSessionId ?? 0,
          ),
          runtimeState: rt,
        ),
      );
    }

    final markers = List.generate(userItemIndices.length, (i) {
      return ScrollbarMarker(
        itemIndex: userItemIndices[i],
        color: CruxTheme.userPrefix,
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
        tooltipBackgroundColor: CruxTheme.overlayBackground,
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
            color: CruxTheme.onSurfaceVariant,
            hoverColor: CruxTheme.buttonTextHover,
            bgColor: CruxTheme.buttonBackground,
            hoverBgColor: CruxTheme.buttonBackgroundHover,
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
                  style: TextStyle(color: CruxTheme.onSurfaceVariant),
                ),
              if (showThinking)
                Button(
                  label: thinkingLabel!,
                  onPressed: () => _cycleThinkingLevel(rt!),
                  color: rt!.thinkingMode == 'disabled'
                      ? CruxTheme.thinkingLabelDisabled
                      : CruxTheme.onSurfaceVariant,
                  hoverColor: CruxTheme.buttonTextHover,
                  bgColor: CruxTheme.buttonBackground,
                  hoverBgColor: CruxTheme.buttonBackgroundHover,
                  padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                ),
              if (showContext) ...[
                Text('  ', style: TextStyle(color: CruxTheme.divider)),
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
                        Text('  ', style: TextStyle(color: CruxTheme.divider)),
                        Text(
                          _metricsHovered
                              ? _cacheHitLabel(
                                  rt,
                                  _sessionController.currentSession,
                                )
                              : tokText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? CruxTheme.metricsActive
                                : CruxTheme.metricsIdle,
                          ),
                        ),
                      ],
                      if (showTtft) ...[
                        Text(' ', style: TextStyle(color: CruxTheme.divider)),
                        Text(
                          ttftText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? CruxTheme.metricsActive
                                : CruxTheme.metricsIdle,
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
        _sessionController.isGeneratingTitle ||
        (rt?.isGeneratingTldr ?? false);
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
          ? CruxTheme.metricsActive
          : CruxTheme.progressFill,
      emptyColor: CruxTheme.progressEmpty,
      labelFillFg: _streamingController.contextBarHovered
          ? CruxTheme.outlineDim
          : CruxTheme.buttonBackground,
      labelEmptyFg: _streamingController.contextBarHovered
          ? CruxTheme.metricsActive
          : CruxTheme.progressLabelEmpty,
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

  String _thinkingLabel(SessionRuntimeState rt) {
    final effort = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';
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
    final levels = ['off', 'normal', 'high', 'max'];
    final current = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';
    final idx = levels.indexOf(current);
    final next = levels[(idx + 1) % levels.length];
    switch (next) {
      case 'off':
        rt.thinkingMode = 'disabled';
        rt.reasoningEffort = null;
      case 'normal':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'normal';
      case 'high':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'high';
      case 'max':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'max';
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
    return Container(
      padding: EdgeInsets.all(1),
      child: Row(
        children: [
          Text('> ', style: TextStyle(color: CruxTheme.onSurfaceDim)),
          Expanded(
            child: TextField(
              controller: textController,
              focused: !_overlayController.showSessionManager,
              maxLines: null,
              style: TextStyle(color: CruxTheme.foreground),
              placeholder: 'Type a message...',
              onSubmitted: (_) => _sendMessage(),
              onKeyEvent: _handleInputKeyEvent,
              wordBoundaryProvider: cjkWordBoundaryProvider,
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/markdown_headings.dart';
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

  bool _toastVisible = false;
  String _toastMessage = '';
  bool _metricsHovered = false;

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

  void _showToast(String message) {
    setState(() {
      _toastVisible = true;
      _toastMessage = message;
    });
  }

  static int get _maxVisibleItems => 6;

  Future<void> _initSessions() async {
    await _sessionController.initSessions();
    setState(() {});
  }

  Future<void> _switchSession(int id) async {
    final error = await _sessionController.switchSession(id);
    _streamingController.stopContextAnimation();
    scrollController.scrollToBottom();
    if (error != null) {
      _showToast(error);
    }
    setState(() {});
  }

  @override
  void dispose() {
    textController.removeListener(_onTextChanged);
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
                description:
                    _providerService.getApiKey(name) != null ? 'key set' : null,
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
      if (event.logicalKey == LogicalKey.pageUp && (event.isControlPressed || event.isAltPressed)) {
        _jumpToPreviousUserInput();
        return true;
      }
      if (event.logicalKey == LogicalKey.pageDown && (event.isControlPressed || event.isAltPressed)) {
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

    final avgHeight = scrollController.maxScrollExtent > 0 && messages.isNotEmpty
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
      scrollController.jumpTo((targetMsgIndex * avgHeight).clamp(
        scrollController.minScrollExtent,
        scrollController.maxScrollExtent,
      ));
    }
  }

  void _jumpToNextUserInput() {
    final messages = _sessionController.currentMessages;
    final userIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') userIndices.add(i);
    }
    if (userIndices.isEmpty) return;

    final avgHeight = scrollController.maxScrollExtent > 0 && messages.isNotEmpty
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
      scrollController.jumpTo((targetMsgIndex * avgHeight).clamp(
        scrollController.minScrollExtent,
        scrollController.maxScrollExtent,
      ));
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

    textController.clear();

    if (text.startsWith('/')) {
      _executeCommand(text);
      return;
    }

    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;

    final rt = _sessionController.runtime(sessionId);
    _streamingController.streamingContent = '';
    _streamingController.streamingReasoning = '';

    final turnBase = _sessionController.computeBaseContext(sessionId);
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

    _streamingController.startMetricsTimer(sessionId);
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

    _maybeKickOffTitleEarly(sessionId);

    _chatService.sendMessage(
      sessionId: sessionId,
      userContent: text,
      session: _sessionController.currentSession,
      runtime: rt,
      onDelta: (delta) {
        if (_streamingController.streamingContent.isEmpty) {
          rt.contentStartTime = DateTime.now();
        }
        _streamingController.streamingContent += delta;
      },
      onReasoning: (reasoning) {
        _streamingController.streamingReasoning += reasoning;
      },
      onChunk: () {
        final charCount = _streamingController.streamingContent.length;
        final estimatedTokens = (charCount / 3.5).ceil();
        final base = _sessionController.computeBaseContext(sessionId);
        rt.contextTargetTokens = base + estimatedTokens;
        if (!_streamingController.contextAnimTimerIsActive()) {
          _streamingController.startContextAnimation();
        }
        setState(() {});
      },
      onToolRound: () {
        _streamingController.streamingContent = '';
        _streamingController.streamingReasoning = '';
        _sessionController.loadMessages(sessionId).then((_) => setState(() {}));
      },
      onComplete: (response) async {
        _streamingController.streamingContent = '';
        _streamingController.streamingReasoning = '';
        _streamingController.stopMetricsTimer(sessionId);
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
        if (total > 0 && hit > 0) {
          rt.cacheHitPct = ((hit / total) * 100).round();
        } else {
          rt.cacheHitPct = null;
        }
        setState(() {});
        if (_sessionController.currentSession.title == 'New Session') {
          _sessionController.generateTitle(sessionId);
        }
        final lastAiMsg = msgs.lastWhere(
          (m) => m.role == 'ai',
          orElse: () => Message(id: -1, sessionId: sessionId, role: 'ai', content: ''),
        );
        if (lastAiMsg.id > 0 && lastAiMsg.content.isNotEmpty) {
          _maybeGenerateTldr(sessionId, lastAiMsg);
        }
      },
      onError: (error) {
        _streamingController.stopMetricsTimer(sessionId);
        setState(() {
          _toastVisible = true;
          _toastMessage = error;
        });
      },
    );
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
    final hasAuxModel = _providerService.auxiliaryModel != null &&
        _providerService.auxiliaryModel != 'none';

    if (!hasAuxModel) {
      if (force) {
        _showToast('No auxiliary model — set one with /auxiliary');
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
        _toastVisible = true;
        _toastMessage = message;
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

  void _dismissToast() {
    setState(() {
      _toastVisible = false;
      _toastMessage = '';
    });
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
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

    children.add(Expanded(child: _buildMessageList()));

    if (_overlayController.overlayMode == OverlayMode.command &&
        _overlayController.filteredCommands.isNotEmpty) {
      children.add(
        MouseRegion(
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
      );
    } else if (_overlayController.overlayMode == OverlayMode.parameter &&
        _overlayController.filteredSuggestions.isNotEmpty) {
      final paramLabel =
          _overlayController.currentParamIndex <
              _overlayController.activeCommand!.params.length
          ? _overlayController.activeCommand!.params[_overlayController
                .currentParamIndex]
          : 'value';
      children.add(
        MouseRegion(
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
      );
    }

    if (_toastVisible) {
      children.add(Toast(message: _toastMessage, onDismissed: _dismissToast));
    }

    children.add(_buildToolbar());
    children.add(Divider(color: CruxTheme.divider, height: 1));
    children.add(_buildInputRow());

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
        ),
      );

      if (msg.role == 'ai' && msg.id > 0 && rt != null) {
        final hasTldr = msg.tldr.isNotEmpty;
        if (hasTldr || rt.isGeneratingTldr) {
          final headings = extractHeadings(msg.content);
          items.add(
            TldrBubble(
              tldrText: msg.tldr,
              headings: headings,
              isGenerating: rt.isGeneratingTldr && !hasTldr,
              hasAuxiliaryModel:
                  _providerService.auxiliaryModel != null &&
                  _providerService.auxiliaryModel != 'none',
            ),
          );
        }
      }
    }

    if (isStreaming) {
      items.add(
        StreamingBubble(
          streamingContent: _streamingController.streamingContent,
          streamingReasoning: _streamingController.streamingReasoning,
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

        final modelW = modelLabel.length + btnPad;
        final imageW =
            _modelSupportsImages(_sessionController.currentSession.model)
            ? 1
            : 0;
        final thinkingLabel =
            (rt != null &&
                _modelSupportsThinking(_sessionController.currentSession.model))
            ? _thinkingLabel(rt)
            : null;
        final thinkingW = thinkingLabel != null
            ? thinkingLabel.length + btnPad
            : 0;
        final contextW = 20 + spacer;
        final isResponding = rt?.isResponding ?? false;
        final tokText = isResponding && rt != null
            ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
            : rt != null && rt.tokPerSec > 0
            ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
            : '— tok/s';
        final tokW = tokText.length + spacer;
        final ttftText = isResponding && rt != null
            ? _streamingController.formatTtft(rt.ttftMs)
            : rt != null && rt.ttftMs > 0
            ? _streamingController.formatTtft(rt.ttftMs)
            : '—';
        final ttftW = ttftText.length + smallSpacer;
        final auxLabel =
            '\u{F013} ${_sessionController.auxiliaryModelShortName}';
        final auxW = auxLabel.length + btnPad;

        var remaining = constraints.maxWidth.toInt() - modelW - imageW;

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
                              ? _cacheHitLabel(rt, _sessionController.currentSession)
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
    return Button(
      label: '\u{F013} ${_sessionController.auxiliaryModelShortName}',
      onPressed: _onAuxiliaryModelButtonPressed,
      color: CruxTheme.onSurfaceVariant,
      hoverColor: CruxTheme.buttonTextHover,
      bgColor: CruxTheme.buttonBackground,
      hoverBgColor: CruxTheme.buttonBackgroundHover,
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
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

  Component _buildInputRow() {
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

import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/session_runtime_state.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';
import '../commands/command_executor.dart';
import '../services/chat_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/toast.dart';
import 'ui/bg_progress_bar.dart';
import 'ui/glossy_model_button.dart';
import 'provider_wizard_builtin.dart';
import 'provider_wizard_custom.dart';
import 'command_overlay.dart';
import 'suggestion_overlay.dart';
import 'extra_info_panel.dart';
import 'session_management_panel.dart';
import 'message_bubble.dart';
import 'streaming_bubble.dart';

class ChatPanel extends StatefulComponent {
  final String providersDir;
  const ChatPanel({super.key, required this.providersDir});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final SessionStore _store;
  late final ChatService _chatService;
  late final ProviderService _providerService;
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
    _providerService = ProviderService(providersDir: component.providersDir);
    final db = CruxDatabase();
    _store = SessionStore(db);
    _chatService = ChatService(_store, _providerService, LlmClient());

    _sessionController = SessionController(
      store: _store,
      providerService: _providerService,
      chatService: _chatService,
      refresh: _refresh,
      showToast: _showToast,
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
            commandName != '/auxiliary')) {
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
        !(commandName == '/auxiliary' && paramIndex == 0)) {
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
    if (_overlayController.overlayMode == OverlayMode.off) return false;

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
    _streamingController.thinkingCollapsed = false;

    rt.isResponding = true;
    rt.responseStartTime = DateTime.now();
    rt.ttftMs = 0.0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0.0;
    rt.tokCount = 0.0;

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

    _chatService.sendMessage(
      sessionId: sessionId,
      userContent: text,
      session: _sessionController.currentSession,
      runtime: rt,
      onDelta: (delta) {
        if (_streamingController.streamingReasoning.isNotEmpty &&
            !_streamingController.thinkingCollapsed) {
          _streamingController.thinkingCollapsed = true;
        }
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
        rt.contextTargetTokens =
            _sessionController.computeBaseContext(sessionId) + estimatedTokens;
        if (!_streamingController.contextAnimTimerIsActive()) {
          _streamingController.startContextAnimation();
        }
        setState(() {});
      },
      onComplete: (response) async {
        _streamingController.streamingContent = '';
        _streamingController.streamingReasoning = '';
        _streamingController.thinkingCollapsed = false;
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
        final miss = response.promptCacheMissTokens;
        if (hit + miss > 0) {
          rt.cacheHitPct = ((hit / (hit + miss)) * 100).round();
        } else {
          rt.cacheHitPct = null;
        }
        setState(() {});
        if (_sessionController.currentSession.title == 'New Session') {
          _sessionController.generateTitle(sessionId);
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
      enterBuiltinWizard: (name) {
        setState(() {
          _overlayController.enterBuiltinWizard(name);
        });
      },
      enterCustomWizard: () {
        setState(() {
          _overlayController.enterCustomWizard();
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
      switch (sub) {
        case ProviderWizardSubcommand.builtin:
          _dismissWizard(
            message:
                '✓ ${_overlayController.builtinProviderName ?? "Provider"} connected successfully',
          );
        case ProviderWizardSubcommand.custom:
          _dismissWizard(message: '✓ Custom provider updated successfully');
      }
    };

    final VoidCallback onDismiss = () => _dismissWizard();

    switch (sub) {
      case ProviderWizardSubcommand.builtin:
        return ProviderWizardBuiltin(
          service: _providerService,
          providerName: _overlayController.builtinProviderName!,
          onComplete: onComplete,
          onDismiss: onDismiss,
        );
      case ProviderWizardSubcommand.custom:
        return ProviderWizardCustom(
          service: _providerService,
          onComplete: onComplete,
          onDismiss: onDismiss,
        );
    }
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
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Color.fromRGB(50, 50, 70),
              ),
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
    children.add(Divider(color: Color.fromRGB(50, 50, 70), height: 1));
    children.add(_buildInputRow());

    return Column(children: children);
  }

  Component _buildMessageList() {
    final messages = _sessionController.currentMessages;
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isStreaming = rt?.isResponding ?? false;

    if (messages.isEmpty && !isStreaming) {
      return Center(
        child: Text('No messages yet.', style: TextStyle(color: Colors.gray)),
      );
    }

    final itemCount = messages.length + (isStreaming ? 1 : 0);

    return SelectionArea(
      onSelectionCompleted: (text) {
        if (text.isNotEmpty) {
          ClipboardManager.copy(text);
        }
      },
      child: Scrollbar(
        controller: scrollController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: scrollController,
          padding: EdgeInsets.all(1),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index < messages.length) {
              return MessageBubble(message: messages[index]);
            }
            final rt = sessionId != null
                ? _sessionController.runtime(sessionId)
                : null;
            return StreamingBubble(
              streamingContent: _streamingController.streamingContent,
              streamingReasoning: _streamingController.streamingReasoning,
              thinkingCollapsed: _streamingController.thinkingCollapsed,
              runtimeState: rt,
            );
          },
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
            color: Color.fromRGB(120, 100, 160),
            hoverColor: Colors.brightCyan,
            bgColor: Color.fromRGB(25, 20, 45),
            hoverBgColor: Color.fromRGB(40, 30, 80),
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
                  style: TextStyle(color: Color.fromRGB(120, 100, 160)),
                ),
              if (showThinking)
                Button(
                  label: thinkingLabel!,
                  onPressed: () => _cycleThinkingLevel(rt!),
                  color: rt!.thinkingMode == 'disabled'
                      ? Color.fromRGB(60, 50, 80)
                      : Color.fromRGB(120, 100, 160),
                  hoverColor: Colors.brightCyan,
                  bgColor: Color.fromRGB(25, 20, 45),
                  hoverBgColor: Color.fromRGB(40, 30, 80),
                  padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                ),
              if (showContext) ...[
                Text('  ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
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
                          style: TextStyle(color: Color.fromRGB(50, 50, 70)),
                        ),
                        Text(
                          _metricsHovered && rt?.cacheHitPct != null
                              ? 'cache ${rt!.cacheHitPct}%'
                              : tokText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? Color.fromRGB(180, 220, 255)
                                : Color.fromRGB(80, 80, 100),
                          ),
                        ),
                      ],
                      if (showTtft) ...[
                        Text(
                          ' ',
                          style: TextStyle(color: Color.fromRGB(50, 50, 70)),
                        ),
                        Text(
                          ttftText,
                          style: TextStyle(
                            color: rt?.isResponding ?? false
                                ? Color.fromRGB(180, 220, 255)
                                : Color.fromRGB(80, 80, 100),
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
      color: Color.fromRGB(120, 100, 160),
      hoverColor: Colors.brightCyan,
      bgColor: Color.fromRGB(25, 20, 45),
      hoverBgColor: Color.fromRGB(40, 30, 80),
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
    final rt = _sessionController.runtime(_sessionController.currentSessionId!);
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
          ? Color.fromRGB(100, 180, 255)
          : Color.fromRGB(120, 80, 200),
      emptyColor: Color.fromRGB(30, 25, 50),
      labelFillFg: _streamingController.contextBarHovered
          ? Color.fromRGB(20, 15, 40)
          : Color.fromRGB(25, 20, 45),
      labelEmptyFg: _streamingController.contextBarHovered
          ? Color.fromRGB(220, 240, 255)
          : Color.fromRGB(200, 180, 255),
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
          Text('> ', style: TextStyle(color: Colors.gray)),
          Expanded(
            child: TextField(
              controller: textController,
              focused: !_overlayController.showSessionManager,
              maxLines: null,
              style: TextStyle(color: Colors.white),
              placeholder: 'Type a message...',
              onSubmitted: (_) => _sendMessage(),
              onKeyEvent: _handleInputKeyEvent,
            ),
          ),
        ],
      ),
    );
  }
}

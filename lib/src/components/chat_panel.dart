import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../commands/command_executor.dart';
import '../commands/registry.dart';
import '../models/message.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/tool_executor.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/url_launcher.dart';
import 'chat_history.dart';
import 'chat_input.dart';
import 'chat_toolbar.dart';
import 'chat_turn_orchestrator.dart';
import 'command_overlay.dart';
import 'extra_info_panel.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'session_management_panel.dart';
import 'streaming_controller.dart';
import 'suggestion_overlay.dart';
import 'tool_detail_pane.dart';
import 'ui/toast.dart';
import 'ui/fullpane.dart';

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
  late final ChatTurnOrchestrator _turnOrchestrator;
  late final FileReadTracker _tracker;

  /// When non-null, a tool detail fullpane is shown for this tool call.
  ToolDetailData? _toolDetailData;

  bool _providerServiceReady = false;

  final _toastKey = GlobalKey<ToastHubState>();
  final _chatInputKey = GlobalKey<ChatInputState>();
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

  static int get _maxVisibleItems => 6;

  @override
  void initState() {
    super.initState();
    _providerService = ProviderService(
      userProvidersDir: component.userProvidersDir,
      builtInProvidersDir: component.builtInProvidersDir,
    );
    final db = CruxDatabase();
    _store = SessionStore(db);
    final tracker = FileReadTracker(
      onRecordRead: (sessionId, normalizedPath, mtimeMs) {
        return _store.saveFileReadState(sessionId, normalizedPath, mtimeMs);
      },
    );
    _tracker = tracker;
    final registry = ToolRegistry();
    registry.registerDefaults(tracker);
    final toolExecutor = ToolExecutor(registry, _store.messageStore);
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
    _turnOrchestrator = ChatTurnOrchestrator(
      store: _store,
      chatService: _chatService,
      providerService: _providerService,
      sessionController: _sessionController,
      streamingController: _streamingController,
      toolRegistry: _toolRegistry,
      showToast: _showToast,
      refresh: _refresh,
    );

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
    _toastKey.currentState?.show(message, mode: mode);
  }

  /// Open the current project directory in the system file explorer.
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

  /// Seed the chat input with `/project ` so the user can switch projects.
  void _switchProject() {
    _chatInputKey.currentState?.stashAndSetCommand('/project ');
  }

  Future<void> _initSessions() async {
    await _sessionController.initSessions();
    final sessionId = _sessionController.currentSessionId;
    if (sessionId != null) {
      final savedState = await _store.loadFileReadState(sessionId);
      _tracker.loadSession(sessionId, savedState);
    }
    setState(() {});
  }

  Future<void> _switchSession(int id) async {
    // Stop metrics timer for the old session (if any).
    final oldId = _sessionController.currentSessionId;
    if (oldId != null && oldId != id) {
      _streamingController.stopMetricsTimer(oldId);
      // Stash the current input text for the old session so it can be
      // restored when the user switches back. If the user was in command
      // mode (text starts with '/'), the actual message text is in the
      // ChatInput's command stash — save that instead.
      final currentText = textController.text;
      if (currentText.startsWith('/')) {
        // In command mode — check if there's stashed text behind the
        // command and save that to the session stash.
        final stashed = _chatInputKey.currentState?.commandStashedText;
        if (stashed != null && stashed.isNotEmpty) {
          _sessionController.inputTextStash[oldId] = stashed;
        } else {
          _sessionController.inputTextStash.remove(oldId);
        }
      } else if (currentText.isNotEmpty) {
        _sessionController.inputTextStash[oldId] = currentText;
      } else {
        _sessionController.inputTextStash.remove(oldId);
      }
    }

    final error = await _sessionController.switchSession(id);

    final savedState = await _store.loadFileReadState(id);
    _tracker.loadSession(id, savedState);

    // Restore the input text from the new session's stash (if any).
    // This must happen after switchSession updates currentSessionId.
    _chatInputKey.currentState?.loadSessionStash(id);

    // If the new session is actively streaming, start its metrics timer.
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
    CommandRegistry.instance.removeListener(_refresh);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
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

  Future<void> _executeCommand(String text) async {
    // Command executed — restore any stashed input text so the user can
    // continue composing their message.
    _chatInputKey.currentState?.restoreCommandStash();
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
        _turnOrchestrator.maybeGenerateTldr(
          sessionId,
          aiMsg,
          force: true,
          detail: detail,
        );
      },
      themeController: component.themeController,
      sendTurn: _turnOrchestrator.sendTurn,
      findLastUserMessage: _turnOrchestrator.findLastUserMessage,
      deleteMessagesFrom: _turnOrchestrator.deleteMessagesFrom,
      sendBtwTurn: _turnOrchestrator.sendBtwTurn,
      clearBtwTurns: _sessionController.clearBtwTurnsFor,
      showFullpane: _openFullpane,
    );
    await _commandExecutor.execute(text, ctx);
    setState(() {});
  }

  void _onModelButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/model ');
  }

  void _onCompactButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/compact ');
  }

  void _onAuxiliaryModelButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/auxiliary ');
  }

  void _cycleThinkingLevel(SessionRuntimeState rt) {
    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm = _providerService.llmProviderByName(providerName);
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider = _providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    final presets = llm?.reasoningPresetsFor(
      modelId,
      providerLabels: provider?.reasoningLabels ?? const {},
      modelLabels: modelConfig?.reasoningLabels ?? const {},
    ) ?? const [];
    if (presets.isEmpty) return;

    final current = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';

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

  Component _buildFullpane() {
    final data = _toolDetailData;
    if (data != null) {
      final tc = data.toolCall;
      final tool = data.toolRegistry?.lookup(tc.name);
      String? intent;
      if (tool is IntentionalTool) {
        intent = tool.intentFromArgs(tc.input);
      }
      final title = intent != null && intent.isNotEmpty
          ? '${_capitalize(tc.name)} — $intent'
          : _capitalize(tc.name);
      return Fullpane(
        title: title,
        onClose: _closeFullpane,
        contentBuilder: (context) => ToolDetailPane(
          data: data,
          key: ValueKey(data.toolCall.callId),
        ),
      );
    }
    return Fullpane(
      title: 'Fullpane',
      onClose: _closeFullpane,
      contentBuilder: (context) => Center(
        child: Text(
          'Fullpane placeholder content',
          style: TextStyle(
            color: CruxTheme.of(context).onSurfaceDim,
          ),
        ),
      ),
    );
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  void _openFullpane() {
    setState(() {
      _overlayController.showFullpane = true;
    });
  }

  void _openToolDetail(ToolCallData toolCall, Message? pairedResult) {
    setState(() {
      _toolDetailData = ToolDetailData(
        toolCall: toolCall,
        pairedResult: pairedResult,
        toolRegistry: _toolRegistry,
        sessionId: _sessionController.currentSessionId,
        getOffloadedContent: _getOffloadedContent,
      );
      _overlayController.showFullpane = true;
    });
  }

  /// Retrieve all offloaded content for a tool call.
  /// Returns a map of argKey → original content string.
  Future<Map<String, String>> _getOffloadedContent(
    int sessionId,
    String callId,
  ) async {
    final rows = await _store.messageStore.getAllOffloadedContentForCall(
      sessionId,
      callId,
    );
    final result = <String, String>{};
    final prefix = '${callId}_';
    for (final row in rows) {
      // The composite key is `callId_argKey`, extract the argKey.
      if (row.callId.startsWith(prefix)) {
        final argKey = row.callId.substring(prefix.length);
        result[argKey] = row.content;
      }
    }
    return result;
  }

  void _closeFullpane() {
    setState(() {
      _overlayController.showFullpane = false;
      _toolDetailData = null;
    });
  }

  Component _buildSessionManager() {
    return SessionManagementPanel(
      sessions: _sessionController.sessions,
      currentSessionId: _sessionController.currentSessionId ?? 0,
      isSessionResponding: (id) =>
          _sessionController.runtime(id).isResponding,
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

  List<Component> _buildOverlays() {
    final overlay = _overlayController;
    final overlays = <Component>[];

    if (overlay.overlayMode == OverlayMode.command &&
        overlay.filteredCommands.isNotEmpty) {
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: (e) {
              setState(() => overlay.onScrollCommand(e));
            },
            opaque: false,
            child: CommandOverlay(
              commands: overlay.filteredCommands,
              selectedIndex: overlay.selectedCommandIndex,
              scrollOffset: overlay.commandScrollOffset,
              maxVisible: _maxVisibleItems,
              onHover: (i) => setState(() => overlay.onHoverCommand(i)),
              onTap: (i) {
                overlay.onTapCommand(i);
                setState(() {});
              },
            ),
          ),
        ),
      );
    } else if (overlay.overlayMode == OverlayMode.parameter &&
        overlay.filteredSuggestions.isNotEmpty) {
      final paramLabel = overlay.currentParamIndex <
              overlay.activeCommand!.params.length
          ? overlay.activeCommand!.params[overlay.currentParamIndex]
          : 'value';
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: (e) {
              setState(() => overlay.onScrollSuggestion(e));
            },
            opaque: false,
            child: SuggestionOverlay(
              suggestions: overlay.filteredSuggestions,
              selectedIndex: overlay.selectedSuggestionIndex,
              scrollOffset: overlay.suggestionScrollOffset,
              maxVisible: _maxVisibleItems,
              headerLabel: paramLabel,
              onHover: (i) => setState(() => overlay.onHoverSuggestion(i)),
              onTap: (i) {
                overlay.onTapSuggestion(i);
                setState(() {});
              },
            ),
          ),
        ),
      );
    }

    overlays.add(
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: ToastHub(key: _toastKey),
      ),
    );

    return overlays;
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showInfoPanel = constraints.maxWidth >= _infoPanelShowThreshold;

        final sessionId = _sessionController.currentSessionId;
        final rt = sessionId != null
            ? _sessionController.runtime(sessionId)
            : null;

        final overlays = _buildOverlays();

        final mainContent = Column(children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ChatHistory(
                  scrollController: scrollController,
                  sessionController: _sessionController,
                  streamingController: _streamingController,
                  turnOrchestrator: _turnOrchestrator,
                  providerService: _providerService,
                  toolRegistry: _toolRegistry,
                  showToast: _showToast,
                  refresh: _refresh,
                  onToolCallTap: _openToolDetail,
                ),
                ...overlays,
              ],
            ),
          ),
          ChatToolbar(
            sessionController: _sessionController,
            streamingController: _streamingController,
            providerService: _providerService,
            providerServiceReady: _providerServiceReady,
            runtime: rt,
            contextMaxTokens: _contextMaxTokens,
            onModelPressed: _onModelButtonPressed,
            onCompactPressed: _onCompactButtonPressed,
            onAuxiliaryPressed: _onAuxiliaryModelButtonPressed,
            onCycleThinking: _cycleThinkingLevel,
          ),
          Divider(color: CruxTheme.of(context).divider, height: 1),
          ChatInput(
            key: _chatInputKey,
            textController: textController,
            overlayController: _overlayController,
            sessionController: _sessionController,
            streamingController: _streamingController,
            turnOrchestrator: _turnOrchestrator,
            providerService: _providerService,
            providerServiceReady: _providerServiceReady,
            themeController: component.themeController,
            scrollController: scrollController,
            refresh: _refresh,
            onSendTurn: (text) => _turnOrchestrator.sendMessage(
              text: text,
              textController: textController,
            ),
            onExecuteCommand: _executeCommand,
            onSwitchSession: _switchSession,
            onInitSessions: _initSessions,
            onCreateNewSession: _createNewSession,
          ),
        ]);

        if (showInfoPanel) {
          final panelWidth = (_infoPanelWidthMin +
                  0.3 *
                      (constraints.maxWidth -
                          _infoPanelShowThreshold))
              .clamp(_infoPanelWidthMin, _infoPanelWidthMax);

          final body = Row(
            children: [
              Expanded(child: mainContent),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: CruxTheme.of(context).divider,
              ),
              SizedBox(
                width: panelWidth,
                child: ExtraInfoPanel(
                  sessions: _sessionController.sessions,
                  currentSessionId:
                      _sessionController.currentSessionId ?? 0,
                  onSwitchSession: _switchSession,
                  archivedCount: _sessionController.archivedCount,
                  isSessionResponding: (id) =>
                      _sessionController.runtime(id).isResponding,
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

          if (_overlayController.showFullpane) {
            return Stack(
              children: [
                Positioned.fill(child: body),
                Positioned.fill(child: _buildFullpane()),
              ],
            );
          }

          if (_overlayController.showSessionManager) {
            return Stack(
              children: [
                Positioned.fill(child: body),
                Positioned.fill(child: _buildSessionManager()),
              ],
            );
          }

          return body;
        }

        if (_overlayController.showFullpane) {
          return Stack(
            children: [
              Positioned.fill(child: mainContent),
              Positioned.fill(child: _buildFullpane()),
            ],
          );
        }

        if (_overlayController.showSessionManager) {
          return Stack(
            children: [
              Positioned.fill(child: mainContent),
              Positioned.fill(child: _buildSessionManager()),
            ],
          );
        }

        return mainContent;
      },
    );
  }
}

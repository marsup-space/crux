import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import '../commands/cmd_help.dart';
import '../commands/command_executor.dart';
import '../commands/registry.dart';
import '../lsp/actors/registry.dart';
import '../lsp/manager.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/git_status_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/tool_executor.dart';
import '../services/web_provider_registry.dart';
import '../services/providers/tinyfish_web_provider.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/quick_reply_parser.dart';
import '../utils/markdown_links.dart';
import '../tools/registry.dart';
import '../tools/ask_tool.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/frame_profiler.dart';
import '../utils/url_launcher.dart';
import 'ask_form.dart';
import 'btw_cubit.dart';
import 'chat_history.dart';
import 'chat_turn_cubit.dart';
import 'compaction_fullpane.dart';
import 'chat_input.dart';
import 'chat_toolbar.dart';
import 'metrics_cubit.dart';
import 'session_cubit.dart';
import 'streaming_cubit.dart';
import 'context_bar.dart';
import 'chat_turn_orchestrator.dart';
import 'command_overlay.dart';
import 'extra_info_panel.dart';
import 'file_browser_overlay.dart';
import 'skill_picker_overlay.dart';
import 'overlay_controller.dart';
import 'polling_coordinator.dart';
import 'quit_handler.dart';
import 'session_controller.dart';
import 'session_management_panel.dart';
import 'streaming_controller.dart';
import 'suggestion_overlay.dart';
import 'tool_detail_pane.dart';
import 'ui/toast.dart';
import 'ui/button.dart';
import 'ui/fullpane.dart';
import 'ui/layout_metrics.dart';

/// Number of messages to load synchronously at boot.
const int _kBootFirstChunkSize = 50;

class ChatPanelBootState {
  final ProviderService providerService;
  final SessionStore store;
  final List<Session> sessions;
  final int currentSessionId;
  final int archivedCount;
  final Map<int, List<Message>> messageCache;
  final Map<String, int> currentFileReadState;
  final int? messagesTotal;

  const ChatPanelBootState({
    required this.providerService,
    required this.store,
    required this.sessions,
    required this.currentSessionId,
    required this.archivedCount,
    required this.messageCache,
    required this.currentFileReadState,
    this.messagesTotal,
  });
}

class _CachedCompactEstimate {
  final int messageCount;
  final int contextTargetTokens;
  final ChatLogCompactionEstimate estimate;

  const _CachedCompactEstimate({
    required this.messageCount,
    required this.contextTargetTokens,
    required this.estimate,
  });
}

Future<ChatPanelBootState> loadChatPanelBootState({
  required String userProvidersDir,
  String? builtInProvidersDir,
  ProviderService? providerService,
  SessionStore? store,
  String? projectPath,
}) async {
  final resolvedProviderService =
      providerService ??
      ProviderService(
        userProvidersDir: userProvidersDir,
        builtInProvidersDir: builtInProvidersDir,
      );
  await resolvedProviderService.initialize();

  final resolvedStore = store ?? SessionStore(CruxDatabase());
  final resolvedProjectPath = projectPath ?? Directory.current.path;

  await resolvedStore.markOrphanedRunningSessionsAsInterrupted(
    projectPath: resolvedProjectPath,
  );
  await resolvedStore.autoArchive(
    projectPath: resolvedProjectPath,
    olderThan: const Duration(days: 3),
  );

  var sessions = await resolvedStore.list(projectPath: resolvedProjectPath);
  var archivedCount = await resolvedStore.archivedCount(
    projectPath: resolvedProjectPath,
  );

  Future<Session> createStartupSession() {
    final model = resolvedProviderService.resolveDefaultModel() ?? '';
    return resolvedStore.create(
      title: 'New Session',
      model: model,
      projectPath: resolvedProjectPath,
    );
  }

  if (sessions.isEmpty) {
    final session = await createStartupSession();
    sessions = [session];
  }

  Session? initialSession;
  for (final session in sessions) {
    if (session.status == SessionStatus.idle ||
        session.status == SessionStatus.done) {
      initialSession = session;
      break;
    }
  }

  if (initialSession == null) {
    final session = await createStartupSession();
    sessions = [session, ...sessions];
    initialSession = session;
    archivedCount = await resolvedStore.archivedCount(
      projectPath: resolvedProjectPath,
    );
  }

  final currentSessionId = initialSession.id;

  final countFuture = resolvedStore.messageStore.countBySession(
    currentSessionId,
  );
  final firstChunkFuture = resolvedStore.messageStore.getMessages(
    currentSessionId,
    limit: _kBootFirstChunkSize,
  );
  final messagesTotal = await countFuture;
  final firstChunk = await firstChunkFuture;

  final fileReadState = await resolvedStore.loadFileReadState(currentSessionId);

  return ChatPanelBootState(
    providerService: resolvedProviderService,
    store: resolvedStore,
    sessions: sessions,
    currentSessionId: currentSessionId,
    archivedCount: archivedCount,
    messageCache: {currentSessionId: firstChunk},
    currentFileReadState: fileReadState,
    messagesTotal: messagesTotal,
  );
}

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;
  final ChatPanelBootState? bootState;
  final GitStatusService? gitStatusService;
  final RecentProjectsStore recentProjectsStore;
  final List<String> startupWarnings;

  const ChatPanel({
    super.key,
    required this.userProvidersDir,
    this.builtInProvidersDir,
    required this.themeController,
    this.bootState,
    this.gitStatusService,
    required this.recentProjectsStore,
    this.startupWarnings = const [],
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final SessionStore _store;
  late final ChatService _chatService;
  late final ProviderService _providerService;
  late final WebProviderRegistry _webProviderRegistry;
  late final ToolRegistry _toolRegistry;
  StreamSubscription<void>? _webProviderChangesSub;
  late final SessionController _sessionController;
  late final OverlayController _overlayController;
  late final StreamingController _streamingController;
  late final CommandExecutor _commandExecutor;
  late final ChatTurnOrchestrator _turnOrchestrator;
  late final FileReadTracker _tracker;
  late final LspManager _lspManager;
  late final PollingCoordinator _polling;
  late final QuitHandler _quitHandler;

  /// Holds the in-flight `ask` tool call. When non-null, the chat
  /// input box region is replaced by [AskForm]. See [AskTool] and
  /// `lib/src/tools/ask_tool.dart`.
  late final PendingAskCubit _pendingAskCubit = PendingAskCubit();

  final Map<int, _CachedCompactEstimate> _compactEstimates = {};
  int? _estimateJobSessionId;

  late final RecentProjectsStore _recentProjectsStore;
  late final GitStatusService _gitStatusService;

  ToolDetailData? _toolDetailData;
  Message? _compactionFullpaneMessage;
  bool _providerServiceReady = false;

  final _toastKey = GlobalKey<ToastHubState>();
  final _chatInputKey = GlobalKey<ChatInputState>();
  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  // Sidebar show threshold and width growth — see
  // [kSidebarShowThreshold] / [kSidebarWidthMin] / [kSidebarWidthMax]
  // in ui/layout_metrics.dart.

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
    final bootState = component.bootState;
    _providerService =
        bootState?.providerService ??
        ProviderService(
          userProvidersDir: component.userProvidersDir,
          builtInProvidersDir: component.builtInProvidersDir,
        );
    _store = bootState?.store ?? SessionStore(CruxDatabase());
    unawaited(_store.repairStaleContextTokens());
    final tracker = FileReadTracker(
      onRecordRead: (sessionId, normalizedPath, mtimeMs) {
        return _store.saveFileReadState(sessionId, normalizedPath, mtimeMs);
      },
      onRecordWrite: (sessionId, normalizedPath, mtimeMs, intent) {
        return _store.saveLastWriter(
          sessionId,
          normalizedPath,
          mtimeMs,
          intent,
        );
      },
      onLookupAttribution: (normalizedPath, currentMtimeMs) async {
        // Live attribution lookup for the read-before-write guard.
        // Returns null when no row exists, when the recorded writer
        // is the current session (no attribution to show — the
        // drift message is enough), or when the recorded mtime
        // no longer matches the on-disk mtime (external edit since
        // the write — the intent would be misleading). The title
        // is looked up live so `/rename` is reflected immediately.
        final last = await _store.loadLastWriter(normalizedPath);
        if (last == null) return null;
        if (last.mtimeMs != currentMtimeMs) return null;
        if (last.sessionId == _sessionController.currentSessionId) {
          return null;
        }
        final title = await _store.lookupSessionTitle(last.sessionId);
        return (sessionId: last.sessionId, intent: last.intent, title: title);
      },
    );
    _tracker = tracker;
    _lspManager = LspManager(
      workingDirectory: Directory.current.path,
      actorFactories: defaultLspActorFactories(),
    );
    _webProviderRegistry = WebProviderRegistry()
      ..register(TinyFishWebProvider());
    unawaited(_webProviderRegistry.initialize());

    final registry = ToolRegistry();
    registry.registerDefaults(
      tracker,
      sessionStore: _store,
      webProviderRegistry: _webProviderRegistry,
      lsp: _lspManager,
      pendingAskCubit: _pendingAskCubit,
    );
    final toolExecutor = ToolExecutor(registry);
    _toolRegistry = registry;
    _chatService = ChatService(
      _store,
      _providerService,
      LlmClient(),
      toolExecutor,
    );
    _webProviderChangesSub = _webProviderRegistry.changes.listen((_) {
      registry.registerWebTools(_webProviderRegistry);
      setState(() {});
    });
    _gitStatusService = component.gitStatusService ?? GitStatusService();
    if (component.gitStatusService == null) {
      _gitStatusService.start();
    }

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
      gitStatusService: _gitStatusService,
      tracker: _tracker,
      pendingAskCubit: _pendingAskCubit,
    );
    _polling = PollingCoordinator(
      providerService: _providerService,
      sessionController: _sessionController,
      // Read the flag live on every sync, not at construction
      // time — the panel flips `_providerServiceReady` to true
      // asynchronously after `ProviderService.initialize()`
      // completes (or synchronously from `bootState`), and the
      // coordinator must observe the post-init value to start
      // the coding-plan / credit-balance polling timers.
      isProviderServiceReady: () => _providerServiceReady,
    );
    _quitHandler = QuitHandler(themeController: component.themeController);

    if (bootState != null) {
      _providerServiceReady = true;
      _sessionController.sessions = List<Session>.from(bootState.sessions);
      _sessionController.currentSessionId = bootState.currentSessionId;
      _sessionController.archivedCount = bootState.archivedCount;
      _sessionController.messageCache.addAll(
        bootState.messageCache.map(
          (id, messages) => MapEntry(id, List<Message>.from(messages)),
        ),
      );
      _sessionController.resolveAuxiliaryModel();
      // The boot path above writes to the controller fields directly
      // (it bypasses initSessions and the chunked loader). Those writes
      // do not flow through the per-mutation cubit mirror helpers that
      // slice 4 introduced, so without this snapshot the cubit stays
      // empty and chat_history renders a blank panel until the next
      // session switch. Push the legacy state into the cubit once
      // before the panel builds its first frame.
      _sessionController.syncCubitFromLegacyState();
      _tracker.loadSession(
        bootState.currentSessionId,
        bootState.currentFileReadState,
      );

      final bootMessagesLoaded =
          bootState.messageCache[bootState.currentSessionId]?.length ?? 0;
      final bootTotal = bootState.messagesTotal;
      if (bootTotal != null && bootTotal > bootMessagesLoaded) {
        unawaited(
          _sessionController.completeSwitchSession(
            bootState.currentSessionId,
            onProgress: () {
              if (!mounted) return;
              setState(() {});
            },
          ),
        );
      }
    }

    CommandRegistry.instance.addListener(_refresh);
    FrameProfiler.instance.registerSnapshotProvider(_profilerSnapshot);
    _recentProjectsStore = component.recentProjectsStore;
    _recentProjectsStore.addListener(_refresh);
    _recentProjectsStore.addListener(_refreshGitStatus);
    if (bootState == null) {
      _initSessions();
      _providerService.initialize().then((_) {
        setState(() {
          _providerServiceReady = true;
          _sessionController.resolveAuxiliaryModel();
        });
      });
    }
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      for (final warning in component.startupWarnings) {
        _showToast(warning, mode: ToastMode.error);
      }
    });
  }

  void _refresh() {
    FrameProfiler.instance.markSetState();
    setState(() {});
  }

  void _showToast(String message, {ToastMode? mode}) {
    _toastKey.currentState?.show(message, mode: mode);
  }

  void _maybeRecomputeCompactEstimate() {
    final session = _sessionController.currentSession;
    final sessionId = session.id;
    // Read contextTargetTokens from MetricsCubit (already mirrored
    // by session_controller.mirrorTurnFlags + the runtime() seed
    // path) and the message list from SessionCubit — both are the
    // read-side SSoTs at this layer. The local `runtime` (and
    // `currentMessages` getter) are no longer needed in this method.
    final contextTarget = _sessionController.metricsCubit.state
        .sessionState(sessionId)
        .contextTargetTokens;
    final messages = _sessionController.cubit.state.messagesFor(sessionId);
    final cached = _compactEstimates[sessionId];
    if (cached != null &&
        cached.messageCount == messages.length &&
        cached.contextTargetTokens == contextTarget) {
      return;
    }
    _compactEstimates.remove(sessionId);
    if (_estimateJobSessionId == sessionId) return;
    _estimateJobSessionId = sessionId;
    Future.microtask(() async {
      try {
        final estimate = await _chatService.estimateChatLogCompaction(
          sessionId: sessionId,
          session: session,
          toolRegistry: _toolRegistry,
        );
        if (!mounted) return;
        if (estimate != null) {
          _compactEstimates[sessionId] = _CachedCompactEstimate(
            messageCount: messages.length,
            contextTargetTokens: contextTarget,
            estimate: estimate,
          );
        }
      } finally {
        if (mounted) _estimateJobSessionId = null;
        if (mounted) setState(() {});
      }
    });
  }

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
    final oldId = _sessionController.currentSessionId;
    if (oldId != null && oldId != id) {
      _streamingController.stopMetricsTimer(oldId);
      final currentText = textController.text;
      if (currentText.startsWith('/')) {
        final stashed = _chatInputKey.currentState?.commandStashedText;
        _sessionController.stashInputText(oldId, stashed ?? '');
      } else {
        _sessionController.stashInputText(oldId, currentText);
      }
    }

    final error = _sessionController.beginSwitchSession(id);
    if (error != null) {
      _showToast(error, mode: ToastMode.error);
      if (oldId != null && oldId != id) {
        // Same cubit-read as the success path: ChatTurnCubit carries
        // the current isResponding state mirrored from every turn
        // boundary.
        if (_sessionController.chatTurnCubit.state
            .sessionState(oldId)
            .isResponding) {
          _streamingController.startMetricsTimer(oldId);
        }
      }
      setState(() {});
      return;
    }

    setState(() {});

    final fileReadStateFuture = _store.loadFileReadState(id);
    await _sessionController.completeSwitchSession(
      id,
      onProgress: () {
        if (!mounted) return;
        setState(() {});
      },
    );
    if (!mounted) return;
    final savedState = await fileReadStateFuture;
    if (!mounted) return;
    _tracker.loadSession(id, savedState);
    _chatInputKey.currentState?.loadSessionStash(id);

    // Read isResponding from ChatTurnCubit (already mirrored from
    // every turn lifecycle boundary by session_controller
    // .mirrorTurnFlags). The runtime's `isResponding` flag and the
    // cubit's `state.sessionState(id).isResponding` carry the same
    // value here — using the cubit is the read-side SSoT.
    if (_sessionController.chatTurnCubit.state.sessionState(id).isResponding) {
      _streamingController.startMetricsTimer(id);
    }

    _streamingController.stopContextAnimation();
    scrollController.scrollToBottom();
    setState(() {});
  }

  Future<void> _handleSessionLinkTap(int sessionId) async {
    final current = _sessionController.currentSessionId;
    if (current == sessionId) return;
    final error = await _sessionController.switchSession(sessionId);
    if (!mounted) return;
    if (error != null) {
      _showToast(error, mode: ToastMode.error);
      return;
    }
    scrollController.scrollToBottom();
    setState(() {});
  }

  void _handleQuickReplyTap(QuickReply reply) {
    final input = _chatInputKey.currentState;
    if (input == null) return;
    final draft = input.component.textController.text.trim();
    if (draft.isEmpty) {
      input.submit(reply.answer);
    } else {
      input.appendText(reply.answer);
    }
  }

  void _handleMarkdownLinkTap(MarkdownLink link) {
    final result = openUrl(link.url);
    switch (result) {
      case UrlLaunchResult.launched:
        return;
      case UrlLaunchResult.rejected:
        _showToast('Refused to open url: ${link.url}', mode: ToastMode.error);
        return;
      case UrlLaunchResult.failed:
        _showToast("Couldn't open url: ${link.url}", mode: ToastMode.error);
        return;
    }
  }

  void _retryContinue() {
    unawaited(_executeCommand('/continue'));
  }

  void _refreshGitStatus() {
    unawaited(_gitStatusService.refresh());
  }

  @override
  void dispose() {
    CommandRegistry.instance.removeListener(_refresh);
    _webProviderChangesSub?.cancel();
    _webProviderChangesSub = null;
    FrameProfiler.instance.clearSnapshotProvider();
    _recentProjectsStore.removeListener(_refresh);
    _recentProjectsStore.removeListener(_refreshGitStatus);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
    unawaited(_lspManager.shutdown());
    _polling.dispose();
    _gitStatusService.dispose();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _profilerSnapshot() {
    final sessionId = _sessionController.currentSessionId;
    // Read the lifecycle flags from ChatTurnCubit and the message
    // count from SessionCubit instead of going through the
    // controller's runtime singletons. The cubit state is the
    // read-side SSoT and is already mirrored from the controller
    // at every meaningful transition (mirrorTurnFlags for the
    // lifecycle flags, putCachedMessages for the message list).
    // The `anySessionResponding` aggregation now walks the cubit's
    // per-session state map directly — one iteration over the
    // cubit's sessions map, no `runtime(sessionId)` singleton
    // lookup per session.
    final turnStates = _sessionController.chatTurnCubit.state.sessions;
    final ts = sessionId != null ? turnStates[sessionId] : null;
    final messages = _sessionController.cubit.state.messagesFor(
      sessionId ?? -1,
    );
    return {
      'sessionId': sessionId,
      'isResponding': ts?.isResponding ?? false,
      'isGeneratingTldr': ts?.isGeneratingTldr ?? false,
      'btwMode': ts?.btwMode ?? false,
      'interrupted': ts?.interrupted ?? false,
      'isGeneratingTitle': _sessionController.isGeneratingTitle,
      'messageCount': messages.length,
      'reasoningMsgs': messages
          .where((m) => m.reasoningContent.isNotEmpty)
          .length,
      'contextAnimActive': _streamingController.contextAnimTimerIsActive(),
      'anySessionResponding': turnStates.values.any((s) => s.isResponding),
    };
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
    // Direct field write above bypasses the per-mutation cubit mirror
    // helpers that slice 4 wired into SessionController. Force the cubit
    // to see the new session list so chat_history / sidebar / anything
    // else watching SessionCubit state picks up the freshly-created
    // session — without this, the /new command's new session does not
    // appear in widget subscriptions until the next mutation that does
    // round-trip through the controller (initSessions, switchSession, …).
    _sessionController.cubit.replaceSessions(
      sessions: _sessionController.sessions,
      archivedCount: _sessionController.archivedCount,
      currentSessionId: _sessionController.currentSessionId,
    );
    await _switchSession(session.id);
  }

  Future<void> _executeCommand(String text) async {
    if (text == '/compact') {
      final sessionId = _sessionController.currentSessionId;
      if (sessionId != null) {
        final cached = _compactEstimates[sessionId];
        if (ContextBarState.isCompactCounterproductive(cached?.estimate)) {
          _showCompactCounterproductiveToast(cached?.estimate);
          return;
        }
      }
    }
    _chatInputKey.currentState?.restoreCommandStash();
    final ctx = CommandContext(
      store: _store,
      providerService: _providerService,
      providerServiceReady: _providerServiceReady,
      webProviderRegistry: _webProviderRegistry,
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
      persistChatDisplayMode: _sessionController.persistChatDisplayMode,
      persistTemperature: _sessionController.persistTemperature,
      resolveAuxiliaryModel: _sessionController.resolveAuxiliaryModel,
      triggerTldr: (sessionId, aiMsg, detail, userQuestion) {
        _turnOrchestrator.maybeGenerateTldr(
          sessionId,
          aiMsg,
          force: true,
          detail: detail,
          userQuestion: userQuestion,
        );
      },
      themeController: component.themeController,
      sendTurn: _turnOrchestrator.sendTurn,
      compactSession: _turnOrchestrator.compactCurrentSession,
      findLastUserMessage: _turnOrchestrator.findLastUserMessage,
      deleteMessagesFrom: _turnOrchestrator.deleteMessagesFrom,
      sendBtwTurn: _turnOrchestrator.sendBtwTurn,
      clearBtwTurns: _sessionController.clearBtwTurnsFor,
      setInputText: (text) {
        textController.text = text;
        textController.selection = TextSelection.collapsed(offset: text.length);
      },
      quitApp: _quitHandler.quitAndPrintSummary,
      showFullpane: _openFullpane,
      recentProjectsStore: _recentProjectsStore,
      shellMonitorLogStore: _chatService.shellMonitorLogStore,
      appendLocalMessage: (markdown) async {
        final sessionId = _sessionController.currentSessionId;
        if (sessionId == null) return;
        await _store.messageStore.addMessage(
          sessionId,
          role: localInfoRole,
          content: markdown,
        );
        await _sessionController.loadMessages(sessionId);
        _refresh();
      },
    );
    await _commandExecutor.execute(text, ctx);
    setState(() {});
  }

  void _onModelButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/model ');
  }

  void _onCompactButtonPressed() {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId != null) {
      final cached = _compactEstimates[sessionId];
      if (ContextBarState.isCompactCounterproductive(cached?.estimate)) {
        _showCompactCounterproductiveToast(cached?.estimate);
        return;
      }
    }
    unawaited(_executeCommand('/compact'));
  }

  /// Surfaces a status toast explaining why /compact was rejected
  /// by the 95%-threshold gate. The estimate carries pre / post
  /// token counts so the toast can show the projected savings
  /// the user would have seen.
  void _showCompactCounterproductiveToast(ChatLogCompactionEstimate? est) {
    if (est == null || est.preTokens <= 0) {
      _showToast(
        'Compaction is not worth it — no history to compact.',
        mode: ToastMode.info,
      );
      return;
    }
    final pre = est.preTokens;
    final post = est.postEstimateTokens;
    final saved = pre - post;
    final pct = (saved * 100 / pre).round();
    _showToast(
      'Compaction would save only $pct% (≈${_fmtNum(saved)} tokens) — below the 5% threshold. Skipping.',
      mode: ToastMode.info,
    );
  }

  /// Local copy of the comma-grouped number formatter used by
  /// [ContextBarState]. We can't reach into the widget's private
  /// helper from here; duplicating the trivial regex keeps the
  /// toast human-friendly without a public export.
  String _fmtNum(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );

  void _onAuxiliaryModelButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/auxiliary ');
  }

  /// Invoked by the toolbar's `T:0.5` chip when the user clicks
  /// it. Stashes any user-typed prefix (same as the other button
  /// shortcuts in this file) and replaces the input with
  /// `/temperature ` so the cursor lands ready to retype a new
  /// value. The executor's no-arg branch is what `/temperature`
  /// without a value triggers, so on the next send the user gets
  /// the "current temperature" toast — a useful "show me where I
  /// am" step before deciding whether to change it.
  void _onTemperatureChipPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/temperature ');
  }

  void _cycleThinkingLevel(SessionRuntimeState rt) {
    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm = _providerService.llmProviderByName(providerName);
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider = _providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    final presets =
        llm?.reasoningPresetsFor(
          modelId,
          providerLabels: provider?.reasoningLabels ?? const {},
          modelLabels: modelConfig?.reasoningLabels ?? const {},
        ) ??
        const [];
    if (presets.isEmpty) return;

    final current = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';

    // Find the current effort in the preset list. If it's
    // not there (e.g. a session created before the runtime
    // resolved a stale `normal` value, or a model switch
    // mid-session whose new preset list doesn't include the
    // old value), fall back to idx = -1 so the cycle picks
    // the first preset — the same behavior as a freshly
    // loaded session whose runtime value happens to be the
    // legacy default.
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
    final compactionMsg = _compactionFullpaneMessage;
    if (compactionMsg != null) {
      return Fullpane(
        title: 'Compaction',
        onClose: _closeFullpane,
        contentBuilder: (context) => CompactionFullpane(
          message: compactionMsg,
          key: const ValueKey('compaction-current'),
        ),
      );
    }
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
        contentBuilder: (context) =>
            ToolDetailPane(data: data, key: ValueKey(data.toolCall.callId)),
      );
    }
    return Fullpane(
      title: 'Fullpane',
      onClose: _closeFullpane,
      contentBuilder: (context) => Center(
        child: Text(
          'Fullpane placeholder content',
          style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
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
      );
      _overlayController.showFullpane = true;
    });
  }

  void _closeFullpane() {
    setState(() {
      _overlayController.showFullpane = false;
      _toolDetailData = null;
      _compactionFullpaneMessage = null;
    });
  }

  void _openCompactionFullpane(Message message) {
    setState(() {
      _compactionFullpaneMessage = message;
      _overlayController.showFullpane = true;
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
      final paramLabel =
          overlay.currentParamIndex < overlay.activeCommand!.params.length
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
    } else if (overlay.overlayMode == OverlayMode.atMention) {
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: (e) {
              setState(() => overlay.onScrollFile(e));
            },
            opaque: false,
            child: FileBrowserOverlay(
              files: overlay.filteredFiles,
              selectedIndex: overlay.selectedFileIndex,
              scrollOffset: overlay.fileScrollOffset,
              maxVisible: _maxVisibleItems,
              query: overlay.atMentionQuery,
              isSearching: overlay.isSearching,
              onHover: (i) => setState(() => overlay.onHoverFile(i)),
              onTap: (i) {
                setState(() {
                  overlay.selectedFileIndex = i;
                  overlay.insertAtMention(null);
                });
              },
            ),
          ),
        ),
      );
    } else if (overlay.overlayMode == OverlayMode.skillPicker) {
      overlays.add(
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onHover: (e) {
              setState(() => overlay.onScrollSkill(e));
            },
            opaque: false,
            child: SkillPickerOverlay(
              skills: overlay.filteredSkills,
              selectedIndex: overlay.selectedSkillIndex,
              scrollOffset: overlay.skillScrollOffset,
              maxVisible: _maxVisibleItems,
              query: overlay.skillChipQuery,
              onHover: (i) => setState(() => overlay.onHoverSkill(i)),
              onTap: (i) {
                setState(() {
                  overlay.selectedSkillIndex = i;
                  overlay.insertSkillChip(null);
                });
              },
            ),
          ),
        ),
      );
    }

    overlays.add(
      Positioned(bottom: 0, left: 0, right: 0, child: ToastHub(key: _toastKey)),
    );

    return overlays;
  }

  @override
  Component build(BuildContext context) {
    _polling.syncCodingPlanPolling();
    _polling.syncCreditBalancePolling();
    _maybeRecomputeCompactEstimate();

    return FrameProfiler.instance.timed('chatPanel.build', () {
      return MultiBlocProvider(
        providers: [
          BlocProvider<SessionCubit>.value(value: _sessionController.cubit),
          BlocProvider<BtwCubit>.value(value: _sessionController.btwCubit),
          BlocProvider<MetricsCubit>.value(
            value: _sessionController.metricsCubit,
          ),
          BlocProvider<ChatTurnCubit>.value(
            value: _sessionController.chatTurnCubit,
          ),
          BlocProvider<StreamingCubit>.value(
            value: _sessionController.streamingCubit,
          ),
        ],
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showInfoPanel = constraints.maxWidth >= kSidebarShowThreshold;

            final sessionId = _sessionController.currentSessionId;
            final rt = sessionId != null
                ? _sessionController.runtime(sessionId)
                : null;

            final overlays = _buildOverlays();

            final mainContent = Column(
              children: [
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
                        onSessionLinkTap: _handleSessionLinkTap,
                        onQuickReplyTap: _handleQuickReplyTap,
                        onLinkTap: _handleMarkdownLinkTap,
                        onRetryContinue: _retryContinue,
                        onCompactionTap: CommandRegistry.instance.debugEnabled
                            ? _openCompactionFullpane
                            : null,
                      ),
                      // Vibe/verbose toggle — absolutely positioned
                      // top-right, outside the chat scroll view.
                      // Reuses the project's Button component for
                      // hover/focus theming via CruxTheme. Label shows
                      // the current mode; click flips it.
                      //
                      // The [kScrollbarClearance] offset (instead of
                      // `right: 0`) leaves the scrollbar's thumb +
                      // marker column free at the panel's right edge —
                      // without it, the button visually overlaps the
                      // scrollbar and blocks its hit testing in the top
                      // corner.
                      if (rt != null)
                        Positioned(
                          top: 0,
                          right: kScrollbarClearance,
                          child: Button(
                            label: rt.chatDisplayMode == ChatDisplayMode.vibe
                                ? 'vibe'
                                : 'verbose',
                            onPressed: () {
                              final newMode =
                                  rt.chatDisplayMode == ChatDisplayMode.vibe
                                  ? ChatDisplayMode.verbose
                                  : ChatDisplayMode.vibe;
                              rt.chatDisplayMode = newMode;
                              _sessionController.persistChatDisplayMode(rt);
                              setState(() {});
                            },
                          ),
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
                  codingPlanProvider: _polling.activeCodingPlanProvider,
                  creditBalanceProvider: _polling.activeCreditBalanceProvider,
                  onCodingPlanTap:
                      _polling.activeCodingPlanProvider?.refreshNow,
                  onCreditBalanceTap:
                      _polling.activeCreditBalanceProvider?.refreshNow,
                  runtime: rt,
                  contextMaxTokens: _contextMaxTokens,
                  onModelPressed: _onModelButtonPressed,
                  onCompactPressed: _onCompactButtonPressed,
                  onAuxiliaryPressed: _onAuxiliaryModelButtonPressed,
                  onCycleThinking: _cycleThinkingLevel,
                  onTemperaturePressed: _onTemperatureChipPressed,
                  compactEstimate: sessionId == null
                      ? null
                      : _compactEstimates[sessionId]?.estimate,
                  debugMode: CommandRegistry.instance.debugEnabled,
                  // When the side panel is visible the auxiliary
                  // button lives there (above the git status /
                  // project widgets); only render it in the toolbar
                  // on narrow terminals.
                  auxButtonInSidePanel: showInfoPanel,
                ),
                Divider(color: CruxTheme.of(context).divider, height: 1),
                // The input region is swappable: when the agent has an
                // in-flight `ask` tool call for the current session, the
                // form replaces the chat input box until the user
                // submits or dismisses. See [AskTool], [AskForm].
                BlocBuilder<PendingAskCubit, PendingAskState>(
                  bloc: _pendingAskCubit,
                  builder: (context, pendingState) {
                    final sid = _sessionController.currentSessionId;
                    final pending = pendingState.pending;
                    final showAskForm = pending != null &&
                        sid != null &&
                        pending.sessionId == sid;
                    if (!showAskForm) {
                      return ChatInput(
                        key: _chatInputKey,
                        textController: textController,
                        overlayController: _overlayController,
                        sessionController: _sessionController,
                        streamingController: _streamingController,
                        turnOrchestrator: _turnOrchestrator,
                        providerService: _providerService,
                        providerServiceReady: _providerServiceReady,
                        webProviderRegistry: _webProviderRegistry,
                        themeController: component.themeController,
                        scrollController: scrollController,
                        refresh: _refresh,
                        projectPath: Directory.current.path,
                        recentProjectsStore: _recentProjectsStore,
                        onSendTurn: (text) {
                          final sid = _sessionController.currentSessionId;
                          final images = sid != null
                              ? _sessionController.drainPendingImages(sid)
                              : <ImageAttachment>[];
                          _turnOrchestrator.sendMessage(
                            text: text,
                            textController: textController,
                            images: images,
                          );
                          scrollController.scrollToBottom();
                        },
                        onExecuteCommand: _executeCommand,
                        onSwitchSession: _switchSession,
                        onInitSessions: _initSessions,
                        onCreateNewSession: _createNewSession,
                        onQuitRequest: _quitHandler.quitAndPrintSummary,
                        onAttachClipboardImage: (image) {
                          final sid = _sessionController.currentSessionId;
                          if (sid != null) {
                            _sessionController.addPendingImage(sid, image);
                            final index = _sessionController
                                .pendingImagesFor(sid)
                                .length;
                            _chatInputKey.currentState?.insertImageMarker(index);
                            _refresh();
                          }
                        },
                      );
                    }
                    return AskForm(
                      key: ValueKey('ask-form-${pending.callId}'),
                      pending: pending,
                      onSubmit: (prose, view) {
                        // Surface the user's selection as a visible
                        // user-role message bubble in the chat log.
                        // The `ask` tool result is a `role: tool`
                        // message (transparent to the user), so
                        // without this the submitted answer would
                        // vanish from view.
                        final sid = _sessionController.currentSessionId;
                        if (sid != null) {
                          // Persist FIRST, mirroring how a typed user
                          // message is stored (chat_service.sendMessage
                          // writes the row before the LLM call). The
                          // old in-memory-only append was wiped by the
                          // orchestrator's store reload at the next
                          // round boundary (onToolRound → loadMessages),
                          // which is why the bubble disappeared the
                          // moment the turn continued. A bare `user`
                          // row mid-round is valid on both wire
                          // families: the Anthropic pairing sanitizer
                          // only prunes orphan tool plumbing, never
                          // plain text.
                          final answerMsg = Message(
                            id: -1,
                            sessionId: sid,
                            role: 'user',
                            content: prose,
                          );
                          _sessionController.putCachedMessages(sid, [
                            ...?_sessionController.messageCache[sid],
                            answerMsg,
                          ]);
                          unawaited(
                            _store.messageStore.addMessage(
                              sid,
                              role: 'user',
                              content: prose,
                            ),
                          );
                          // Register the display summary keyed by the
                          // message's identity so chat_history can
                          // swap the raw prose bubble for an
                          // [AskAnswerBubble] in both vibe and verbose
                          // mode. Keyed on the Message object (not its
                          // id): id is -1 until the store write lands
                          // and the orchestrator reloads the cache, at
                          // which point the whole key set is migrated
                          // to the fresh rows by identity (see
                          // [SessionController.putCachedMessages]).
                          _sessionController.registerAskAnswerView(
                            answerMsg,
                            view,
                          );
                        }
                        _pendingAskCubit.complete(prose);
                      },
                      onDismiss: () {
                        // Dismiss = "I'd rather type free-form". Cancel
                        // the whole turn silently: the agent must NOT
                        // receive a tool result and immediately reply
                        // again — the UI should just return to the
                        // normal input box and wait for the user's next
                        // message. The form unmounts as a side effect
                        // of the cancel (clearFor emits the empty
                        // state), and no chat bubble is appended —
                        // from the user's perspective they simply chose
                        // not to answer.
                        final sid = _sessionController.currentSessionId;
                        if (sid != null) {
                          _turnOrchestrator.cancelAskTurn(sid);
                        } else {
                          _pendingAskCubit.dismiss();
                        }
                      },
                    );
                  },
                ),
              ],
            );

            if (showInfoPanel) {
              final panelWidth =
                  (kSidebarWidthMin +
                          0.3 * (constraints.maxWidth - kSidebarShowThreshold))
                      .clamp(kSidebarWidthMin, kSidebarWidthMax);

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
                      gitStatusService: _gitStatusService,
                      onSessionTitleTap: () {
                        setState(() {
                          _overlayController.showSessionManager = true;
                        });
                      },
                      onOpenProject: _openProjectInExplorer,
                      onSwitchProject: _switchProject,
                      sessionController: _sessionController,
                      onAuxiliaryPressed: _onAuxiliaryModelButtonPressed,
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
        ),
      );
    });
  }
}

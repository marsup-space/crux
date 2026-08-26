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
import '../services/plan_mode_controller.dart';
import 'plan_doc_pane.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/git_status_service.dart';
import '../services/notes_service.dart';
import '../services/plugin.dart';
import '../services/plugin_registry.dart';
import '../components/plugin_content.dart';
import '../services/llm_client.dart';
import '../services/openrouter_stealth_sync.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/skills/skill.dart';
import '../services/tool_executor.dart';
import '../services/web_provider_registry.dart';
import '../services/providers/tinyfish_web_provider.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../i18n/app_locale.dart';
import '../i18n/locale_controller.dart';
import '../i18n/reply_language.dart';
import '../i18n/strings.dart';
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
import 'extra_info_panel.dart';
import 'home/home_layout_store.dart';
import 'home/home_screen.dart';
import 'home/home_widgets.dart';
import 'input_keys.dart';
import 'input_overlay.dart';
import 'input_overlay_popover.dart';
import 'notes_fullpane.dart';
import 'overlay_controller.dart';
import 'polling_coordinator.dart';
import 'quit_handler.dart';
import 'session_controller.dart';
import 'session_management_panel.dart';
import 'streaming_controller.dart';
import 'tool_detail_pane.dart';
import 'vibe_box_data.dart';
import 'vibe_diff_fullpane.dart';
import 'ui/toast.dart';
import 'ui/highlighted_markdown_text.dart';
import 'ui/button.dart';
import 'ui/fullpane.dart';
import 'ui/layout_metrics.dart';

/// Number of messages to load synchronously at boot.
const int _kBootFirstChunkSize = 50;

class ChatPanelBootState {
  final ProviderService providerService;
  final SessionStore store;
  final List<Session> sessions;
  final List<Session> chats;
  final int currentSessionId;
  final int archivedCount;
  final int archivedChatCount;
  final Map<int, List<Message>> messageCache;
  final Map<String, int> currentFileReadState;
  final int? messagesTotal;

  const ChatPanelBootState({
    required this.providerService,
    required this.store,
    required this.sessions,
    this.chats = const [],
    required this.currentSessionId,
    required this.archivedCount,
    this.archivedChatCount = 0,
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
  final chats = await resolvedStore.listChats();
  final archivedChatCount = await resolvedStore.archivedChatCount();
  var archivedCount = await resolvedStore.archivedCount(
    projectPath: resolvedProjectPath,
  );

  Future<Session> createStartupSession() {
    final model = resolvedProviderService.resolveDefaultModel() ?? '';
    return resolvedStore.create(
      // Empty title = untitled; the display layer renders a
      // locale-aware placeholder. Never persist a literal like
      // "New Session" — it would freeze one language into the DB
      // and collide with users who rename a session to that text.
      title: '',
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
    chats: chats,
    currentSessionId: currentSessionId,
    archivedCount: archivedCount,
    archivedChatCount: archivedChatCount,
    messageCache: {currentSessionId: firstChunk},
    currentFileReadState: fileReadState,
    messagesTotal: messagesTotal,
  );
}

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;

  /// The UI-language controller. Null in tests (like `homeLayoutStore`) —
  /// then the settings box shows `en` and `/language` reports unavailable.
  final LocaleController? localeController;
  final ChatPanelBootState? bootState;
  final GitStatusService? gitStatusService;

  /// Plugin registry for the current project, forwarded to the side
  /// panel and the home grid. Null in tests — no plugin rows/boxes
  /// then. Listened to so spec files appearing/disappearing (written
  /// by any session, project or global) refresh the surfaces live.
  final PluginRegistry? pluginRegistry;

  final RecentProjectsStore recentProjectsStore;
  final List<String> startupWarnings;

  /// When true, the home screen opens automatically at the end of
  /// [initState]. The real app passes true (unless the user opted out
  /// via `--no-home` or `[home].show_on_launch`); tests leave it false
  /// so the chat panel renders its normal first paint. This replaces
  /// the earlier "constructed from a `bootState`" heuristic — tests
  /// *do* pass a bootState, so provenance-sniffing was wrong.
  final bool showHomeOnLaunch;

  /// The `[home]` config.toml store. When non-null, edit-mode layout
  /// changes persist; when null (tests), edit mode works but isn't saved.
  final HomeLayoutStore? homeLayoutStore;

  /// The persisted `[home].layout` (box order + spans) applied on open.
  /// Null → the default layout.
  final List<HomeLayoutEntry>? initialHomeLayout;

  const ChatPanel({
    super.key,
    required this.userProvidersDir,
    this.builtInProvidersDir,
    required this.themeController,
    this.localeController,
    this.bootState,
    this.gitStatusService,
    this.pluginRegistry,
    required this.recentProjectsStore,
    this.startupWarnings = const [],
    this.showHomeOnLaunch = false,
    this.homeLayoutStore,
    this.initialHomeLayout,
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
  StreamSubscription<void>? _sessionSwitchSub;
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
  /// The skill whose SKILL.md the fullpane is showing (home `skills`
  /// box). Null when the fullpane is showing something else.
  SkillInfo? _skillFullpane;
  Message? _compactionFullpaneMessage;
  VibeDiffRequest? _vibeDiffRequest;

  /// Whether the notes fullpane (the "my notes" editor) is showing.
  /// Unlike the other fullpane payloads this carries no data — the
  /// note is loaded from the DB by the pane itself via [_notesService].
  bool _notesFullpaneOpen = false;

  /// Backs the "my notes" feature: the per-project note plus the
  /// status-file projection the sidebar widget reads. Bound to this
  /// session's project, sharing the session store's DB connection.
  late final NotesService _notesService;

  /// Per-session owner of all plan-mode state (design doc §4). The pane
  /// ([PlanDocPane]) is a dumb renderer of it; `/plan` and the
  /// `ask_plan_mode` tool drive it.
  late final PlanModeController _planModeController;

  bool _providerServiceReady = false;

  final _toastKey = GlobalKey<ToastHubState>();
  final _chatInputKey = GlobalKey<ChatInputState>();
  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  // Home quick-chat input machinery — built lazily when home opens and
  // disposed when it closes, so the home input gets the same command /
  // @-mention / #-mention / $skill handling as the chat input.
  InputOverlay? _homeInputOverlay;
  InputKeyHandler? _homeInputKeyHandler;
  String? _homeCommandStash;

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

  /// Localized string lookup for the chat chrome (command overlay, etc.).
  Strings get _strings =>
      Strings(AppLocale.fromCode(component.localeController?.activeCode));

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
    // Bound to the session's project (Directory.current), matching how
    // spec widgets key on the project. The service writes the widget's
    // status projection on init/save so the sidebar shows live todos.
    _notesService = NotesService(
      _store.notesStore,
      projectPath: Directory.current.path,
    );
    // Write the widget's status projection up-front so the sidebar
    // shows the live todo state from session start, not only after the
    // notes fullpane is first opened. Fire-and-forget; the projection
    // is a convenience and the DB is the source of truth.
    unawaited(_notesService.init());
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

    _planModeController = PlanModeController(
      runtimeFor: () {
        final sid = _sessionController.currentSessionId;
        return sid == null ? null : _sessionController.runtime(sid);
      },
      runtimeById: (sessionId) {
        // Lazily materializes the runtime for any session — the same
        // call the session controller itself uses, so plan state
        // survives even for sessions never viewed in this panel run.
        return _sessionController.runtime(sessionId);
      },
    );
    final registry = ToolRegistry();
    registry.registerDefaults(
      tracker,
      sessionStore: _store,
      webProviderRegistry: _webProviderRegistry,
      lsp: _lspManager,
      pendingAskCubit: _pendingAskCubit,
      planModeController: _planModeController,
    );
    final toolExecutor = ToolExecutor(registry);
    _toolRegistry = registry;
    _chatService = ChatService(
      _store,
      _providerService,
      LlmClient(),
      toolExecutor,
      replyLanguage: () => component.localeController?.replyLanguageSettings ??
          ReplyLanguageSettings.fallback,
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
    _planModeController.addListener(_refresh);
    _chatService.onPlanDocMutated = (oldContent, newContent, sessionId) {
      _planModeController.onAgentEdit(
        oldContent,
        newContent,
        sessionId: sessionId,
      );
    };

    // Plan view is session-bound: watch the cubit's session switches
    // (every switch path — sidebar, home, /new, /chat, ses:// links —
    // funnels through `cubit.setCurrentSession`) so the pane follows
    // the session the user is actually looking at. `_switchSession`
    // keeps its explicit attachSession too (it runs before the stream
    // event in practice); boot and reassemble attach as before.
    _sessionSwitchSub = _sessionController.cubit.stream.listen((state) {
      final sid = state.currentSessionId;
      if (sid != null) _planModeController.attachSession(sid);
    });
    final bootSid = _sessionController.currentSessionId;
    if (bootSid != null) _planModeController.attachSession(bootSid);
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
      mentionChipsProvider: () => _overlayController.mentionChips,
      planModeController: _planModeController,
      strings: _strings,
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
    _quitHandler = QuitHandler(
      themeController: component.themeController,
      stringsProvider: () => _strings,
    );

    if (bootState != null) {
      _providerServiceReady = true;
      _sessionController.sessions = List<Session>.from(bootState.sessions);
      _sessionController.chats = List<Session>.from(bootState.chats);
      _sessionController.currentSessionId = bootState.currentSessionId;
      _sessionController.archivedCount = bootState.archivedCount;
      _sessionController.archivedChatCount = bootState.archivedChatCount;
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
    component.pluginRegistry?.addListener(_refresh);
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
    if (component.showHomeOnLaunch) {
      _openHome();
    }
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
          _strings.t('toast.dirNotFoundCwd', {
            'path': Directory.current.path,
          }),
          mode: ToastMode.error,
        );
      case OpenDirectoryResult.failed:
        _showToast(
          _strings.t('toast.fileManagerFailed', {
            'path': Directory.current.path,
          }),
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
    _planModeController.attachSession(id);
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
    // Link-aware switch: if the target was archived (easy to hit —
    // sessions auto-archive after 3 idle days), it is unarchived and
    // pulled back into the sidebar before switching, so old links
    // keep working instead of erroring.
    final error = await _sessionController.openSessionFromLink(sessionId);
    if (!mounted) return;
    if (error != null) {
      _showToast(error, mode: ToastMode.error);
      return;
    }
    scrollController.scrollToBottom();
    setState(() {});
  }

  /// A `prompt`-kind plugin action (quick action) submits its
  /// rendered template as a user message to the current session —
  /// the same path as a typed message or a quick-reply tap, so all
  /// the mid-stream guards apply identically.
  void _handlePluginPromptAction(PluginAction action, String renderedPrompt) {
    final text = renderedPrompt.trim();
    if (text.isEmpty) return;
    _chatInputKey.currentState?.submit(text);
  }

  /// A `shell`-kind plugin action runs its command in the project
  /// root, toasts the outcome, and records it into the session
  /// context so the agent sees what the user ran and how it went —
  /// without starting a turn.
  Future<void> _handlePluginShellAction(
    PluginAction action,
    String renderedCommand,
  ) async {
    final sessionId = _sessionController.currentSessionId;
    final result = await runPluginShellAction(
      action,
      // The command is already rendered by the plugin; pass an empty
      // map so renderActionCommand returns it unchanged.
      const {},
      Directory.current.path,
    );
    if (!mounted) return;

    final ok = result.ok;
    _showToast(
      ok
          ? '✓ ${action.label} finished'
          : '✗ ${action.label} failed (exit ${result.exitCode})',
      mode: ok ? null : ToastMode.error,
    );

    if (sessionId != null) {
      final buf = StringBuffer()
        ..writeln(
          '[Plugin action] The user clicked `${action.label}` and ran '
          '`$renderedCommand` in the project root.',
        )
        ..writeln('Exit code: ${result.exitCode}');
      if (result.tail.isNotEmpty) {
        buf.writeln('Output (tail):');
        buf.writeln('```');
        buf.writeln(result.tail);
        buf.writeln('```');
      }
      await _store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: buf.toString().trimRight(),
      );
      await _sessionController.loadMessages(sessionId);
      _refresh();
    }
  }

  /// Record any plugin interaction (http / launch / shell / prompt
  /// click) into the session context as a lightweight note. The note
  /// carries the action's OUTCOME for http / launch (the renderers
  /// await those before calling), so the agent sees not just that
  /// the user clicked but whether it worked. Failures are swallowed
  /// — recording must never break the UI action it annotates.
  Future<void> _recordPluginAction(String note) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    try {
      await _store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: '[Plugin action] The user $note.',
      );
      await _sessionController.loadMessages(sessionId);
      if (mounted) _refresh();
    } catch (_) {
      // Recording is best-effort; never surface.
    }
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
        _showToast(
          _strings.t('toast.urlRefused', {'url': '${link.url}'}),
          mode: ToastMode.error,
        );
        return;
      case UrlLaunchResult.failed:
        _showToast(
          _strings.t('toast.urlFailed', {'url': '${link.url}'}),
          mode: ToastMode.error,
        );
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
    _sessionSwitchSub?.cancel();
    _sessionSwitchSub = null;
    FrameProfiler.instance.clearSnapshotProvider();
    _recentProjectsStore.removeListener(_refresh);
    _recentProjectsStore.removeListener(_refreshGitStatus);
    component.pluginRegistry?.removeListener(_refresh);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
    _planModeController.dispose();
    unawaited(_lspManager.shutdown());
    _polling.dispose();
    _gitStatusService.dispose();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot-reload rule (project note): fields computed in initState from
    // constructor inputs or default lists are stale after reload unless
    // mirrored here. The plan controller's derived state (parse results,
    // version log) is re-keyed on the current session so a reload that
    // changed the pane's structure doesn't render stale plan content.
    final sid = _sessionController.currentSessionId;
    if (sid != null) _planModeController.attachSession(sid);
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
      // Empty title = untitled (see createStartupSession).
      title: '',
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
      chats: _sessionController.chats,
      archivedCount: _sessionController.archivedCount,
      archivedChatCount: _sessionController.archivedChatCount,
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
      createChatSession: _sessionController.createChatSession,
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
      localeController: component.localeController,
      rebuildSystemPrompt: _chatService.rebuildSystemPrompt,
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
      showHome: _openHome,
      recentProjectsStore: _recentProjectsStore,
      shellMonitorLogStore: _chatService.shellMonitorLogStore,
      planModeController: _planModeController,
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

  /// The toolbar's model button has two modes. When the current
  /// session is mid-response, the button is the interrupt affordance
  /// (it flashes while streaming, so clicking it to stop the response
  /// reads naturally). Otherwise it seeds `/model ` to switch models.
  void _onModelButtonPressed() {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId != null &&
        _sessionController.runtime(sessionId).isResponding) {
      _turnOrchestrator.interruptResponse(textController: textController);
      return;
    }
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
        _strings.t('chat.compact.counterproductive'),
        mode: ToastMode.info,
      );
      return;
    }
    final pre = est.preTokens;
    final post = est.postEstimateTokens;
    final saved = pre - post;
    final pct = (saved * 100 / pre).round();
    _showToast(
      _strings.t('chat.compact.saveOnly', {
        'pct': '$pct',
        'tokens': _fmtNum(saved),
      }),
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

  /// Whether the active session's provider is OpenRouter — the only
  /// provider with a model-list sync. Drives the toolbar's `⟳ sync`
  /// button visibility (null callback = hidden).
  bool get _activeProviderIsOpenRouter {
    if (!_providerServiceReady) return false;
    final model = _sessionController.currentSession.model;
    final slashIdx = model.indexOf('/');
    if (slashIdx <= 0) return false;
    return model.substring(0, slashIdx) ==
        OpenRouterStealthSync.providerName;
  }

  /// Invoked by the toolbar's `⟳ sync` button: run the one-shot
  /// `/provider openrouter-free sync now` command (fetch, diff,
  /// apply, reload). Goes through `_executeCommand` so it reuses
  /// the same CommandContext as a typed slash command.
  void _onSyncModelsPressed() {
    unawaited(
      _executeCommand(
        '/provider ${OpenRouterStealthSync.providerName} sync now',
      ),
    );
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
    if (_notesFullpaneOpen) {
      return NotesFullpane(
        service: _notesService,
        onClose: _closeFullpane,
        strings: _strings,
      );
    }
    final vibeDiff = _vibeDiffRequest;
    if (vibeDiff != null) {
      return VibeDiffFullpane(request: vibeDiff, onClose: _closeFullpane, strings: _strings);
    }
    final skill = _skillFullpane;
    if (skill != null) {
      return Fullpane(
        title: _strings.t('chat.fullpane.skill', {'name': skill.name}),
        onClose: _closeFullpane,
        strings: _strings,
        contentBuilder: (context) => _SkillFullpaneContent(skill: skill),
      );
    }
    final compactionMsg = _compactionFullpaneMessage;
    if (compactionMsg != null) {
      return Fullpane(
        title: _strings.t('chat.fullpane.compaction'),
        onClose: _closeFullpane,
        strings: _strings,
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
        strings: _strings,
        contentBuilder: (context) =>
            ToolDetailPane(data: data, key: ValueKey(data.toolCall.callId)),
      );
    }
    return Fullpane(
      title: _strings.t('chat.fullpane.default'),
      onClose: _closeFullpane,
      strings: _strings,
      contentBuilder: (context) => Center(
        child: Text(
          _strings.t('chat.fullpane.placeholder'),
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

  /// Open the home screen. Home replaces the whole chat interface
  /// (see the early return in [build]); clearing the sibling flags
  /// keeps the swap one-way — no chat chrome survives underneath.
  void _openHome() {
    setState(() {
      _overlayController.showHome = true;
      _overlayController.showSessionManager = false;
      _overlayController.showFullpane = false;
    });
  }

  void _closeHome() {
    textController.removeListener(_onHomeInputChanged);
    _homeInputOverlay?.dispose();
    _homeInputOverlay = null;
    _homeInputKeyHandler = null;
    _homeCommandStash = null;
    setState(() {
      _overlayController.showHome = false;
    });
  }

  /// Start a new Chat-mode conversation with [text] as the first prompt
  /// and leave home for the chat screen. Returns false when refused
  /// mid-stream.
  bool _startChat(String text) {
    if (_homeResponding) return false;
    unawaited(_startChatAsync(text));
    return true;
  }

  Future<void> _startChatAsync(String text) async {
    // Create a fresh workspace-free chat (kind='chat', minimal prompt)
    // and switch to it, then send the prompt as its first message.
    await _sessionController.createChatSession();
    _turnOrchestrator.sendMessage(text: text, textController: textController);
    _closeHome();
  }

  /// Lazily build the home quick-chat input's overlay + key-handler
  /// machinery, reusing the shared [OverlayController] and [textController]
  /// so the home input has the same `/` command, `@` file, `#` session,
  /// and `$` skill handling as the chat input.
  ///
  static void _noopHomeQuickChatRebuild() {}

  /// The quick-chat area's LOCAL rebuild callback, not the panel-wide
  /// `_refresh`: typing must only repaint the input row + its popover.
  /// The old wiring rebuilt the whole home grid (~10 boxes, ~26ms of
  /// layout) on every keystroke. Swapped in by the quick-chat area when
  /// it mounts; a no-op while home is closed.
  VoidCallback _homeQuickChatRebuild = _noopHomeQuickChatRebuild;

  void _ensureHomeInput() {
    if (_homeInputOverlay != null && _homeInputKeyHandler != null) return;
    // Panel-level refresh for the home input: the quick-chat area
    // registers its setState here when it mounts (see
    // [HomeScreen.onQuickChatAreaMounted]), so this forwarding method
    // always targets whatever subtree is currently the input row. While
    // home is closed it's a no-op dummy.
    void localRefresh() => _homeQuickChatRebuild();
    _homeInputOverlay = InputOverlay(
      overlayController: _overlayController,
      sessionController: _sessionController,
      providerService: _providerService,
      providerServiceReady: _providerServiceReady,
      webProviderRegistry: _webProviderRegistry,
      themeController: component.themeController,
      recentProjectsStore: _recentProjectsStore,
      textController: textController,
      projectPath: Directory.current.path,
      refresh: localRefresh,
      onStateChanged: localRefresh,
      strings: _strings,
    );
    _homeInputKeyHandler = InputKeyHandler(
      sessionController: _sessionController,
      turnOrchestrator: _turnOrchestrator,
      onQuitRequest: _quitHandler.quitAndPrintSummary,
      // A plain ESC on home returns to the chat screen (the chat input's
      // `onOpenHome` semantic is "leave the current screen").
      onOpenHome: _closeHome,
      refresh: localRefresh,
      onStateChanged: localRefresh,
      textController: textController,
      overlayController: _overlayController,
      scrollController: null,
      getCommandStash: () => _homeCommandStash,
      setCommandStash: (v) => _homeCommandStash = v,
    );
    _homeInputKeyHandler!.onSendMessage = _submitHomeInput;
    textController.addListener(_onHomeInputChanged);
  }

  void _onHomeInputChanged() {
    _homeInputOverlay?.onTextChanged();
  }

  /// Home quick-chat submit: a leading `/` that resolves to a command
  /// executes it; anything else starts a fresh Chat conversation.
  void _submitHomeInput() {
    final text = textController.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('/')) {
      final cmd = findCommand(text.split(' ').first);
      if (cmd != null) {
        textController.clear();
        unawaited(_executeCommand(text));
        return;
      }
    }
    if (_startChat(text)) {
      textController.clear();
    }
  }

  Component _buildHome() {
    _ensureHomeInput();
    // Home is an independent full screen, not a modal Fullpane — no
    // close button, no barrier, no margins. See HomeScreen.
    return HomeScreen(
      onExit: _closeHome,
      context_: _buildHomeContext(),
      initialLayout: component.initialHomeLayout,
      onLayoutChanged: _persistHomeLayout,
      // Same exit path as `/quit` and the chat input's Ctrl+C, so the
      // run summary + clean teardown fire regardless of where the user
      // hits Ctrl+C.
      quitApp: _quitHandler.quitAndPrintSummary,
      onStartChat: _startChat,
      overlayController: _overlayController,
      inputController: textController,
      inputOverlay: _homeInputOverlay,
      inputKeyHandler: _homeInputKeyHandler,
      maxVisibleItems: _maxVisibleItems,
      // The quick-chat area hands us its local setState so typing (and
      // popover navigation) rebuilds only the input row, not the grid.
      onQuickChatAreaMounted: (rebuild) =>
          _homeQuickChatRebuild = rebuild,
    );
  }

  /// Persist an edit-mode layout change to `[home].layout`. No-op when
  /// there's no store (tests). Fire-and-forget: the write is atomic and
  /// the in-memory layout is already applied, so a slow disk doesn't
  /// block the grid.
  void _persistHomeLayout(List<HomeLayoutEntry> layout) {
    final store = component.homeLayoutStore;
    if (store == null) return;
    unawaited(
      store.write(HomeLayoutConfig(layout: layout)).catchError((_) {
        // A failed persist (read-only config dir, disk full) mustn't
        // crash home — the in-memory layout is correct for this run.
        return;
      }),
    );
  }

  /// True while the current session has a response in flight. The
  /// mid-stream guard for every session-mutating home action reads this
  /// (the cubit is the read-side SSoT for isResponding).
  bool get _homeResponding {
    final sessionId = _sessionController.currentSessionId;
    return sessionId != null &&
        _sessionController.chatTurnCubit.state
            .sessionState(sessionId)
            .isResponding;
  }

  /// The context handed to home's widgets. `runCommand` and
  /// `switchSession` are guarded mid-stream; the service closures read
  /// the panel's live in-memory state on each home build.
  HomeContext _buildHomeContext() {
    return HomeContext(
      close: _closeHome,
      seedInput: (text) {
        _chatInputKey.currentState?.stashAndSetCommand(text);
      },
      gitStatusService: _gitStatusService,
      sessions: () {
        final merged = <Session>[
          ..._sessionController.sessions,
          ..._sessionController.chats,
        ];
        merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return merged;
      },
      currentSessionId: () => _sessionController.currentSessionId,
      switchSession: (id) {
        if (_homeResponding) return false; // refused mid-stream
        unawaited(_switchSession(id));
        return true;
      },
      runCommand: (command) {
        if (_homeResponding) return false; // refused mid-stream
        unawaited(_executeCommand(command));
        return true;
      },
      projectPath: Directory.current.path,
      activeModel: () {
        // The current session's model composite key; empty means "no
        // provider configured yet", which the workspace box turns into
        // a setup hint. Guarded because a fresh panel with no sessions
        // has no current session to read.
        final sessionId = _sessionController.currentSessionId;
        if (sessionId == null) return null;
        final model = _sessionController.currentSession.model;
        return model.isEmpty ? null : model;
      },
      // Settings box: the active theme id, the configured auxiliary
      // model's short name, and the current session's chat display mode.
      themeId: () => component.themeController.activeId,
      localeId: () => component.localeController?.activeCode ?? 'en',
      replyLanguageId: () =>
          component.localeController?.replyLanguageCode ?? 'follow',
      auxModelName: () {
        final aux = _providerService.auxiliaryModel;
        if (aux == null || aux == 'none') return null;
        return _sessionController.auxiliaryModelShortName;
      },
      viewMode: () {
        final sessionId = _sessionController.currentSessionId;
        if (sessionId == null) return null;
        return _sessionController.runtime(sessionId).chatDisplayMode.name;
      },
      // Yesterday box: single-round auxiliary summary of yesterday's
      // work, cached by the service. The merged session list is the
      // same one the `sessions` closure above builds.
      summarizeYesterday: (sessions) => _chatService.summarizeYesterday(
        sessions,
        language: component.localeController?.activeLocale.label,
      ),
      // Skills box: tapping a skill opens its SKILL.md in a fullpane.
      showSkill: _openSkillFullpane,
      // Activity box: token-per-day heatmap over this workspace's
      // sessions. The store query is one SQL aggregate; the widget
      // re-invokes it per open (no caching) because the data is cheap
      // and always fresh.
      dailyTokenTotals: ({required sinceDays}) => _store.messageStore
          .dailyTokenTotals(
            sinceDaysAgo: sinceDays,
            projectPath: Directory.current.path,
          ),
      // Today box: per-day tokens + turns + active-session count over
      // this workspace, same aggregate shape as the activity heatmap.
      dailyUsageStats: ({required sinceDays}) => _store.messageStore
          .dailyUsageStats(
            sinceDaysAgo: sinceDays,
            projectPath: Directory.current.path,
          ),
      // My-notes box: same NotesService + editor fullpane as the sidebar
      // spec widget — the box polls the same projection file.
      notesService: _notesService,
      openNotes: _openNotesFullpane,
      // Coding-plan box: hand it every connected usage provider (not just
      // the active session's provider). The closure reads `_polling` on
      // each home build so the box tracks whatever is configured now.
      connectedUsageProviders: () => _polling.connectedUsage,
      // Spec-driven plugin boxes (`placement = home/both`): the live
      // registry scan, read on each home build so rescans hot-swap
      // boxes; the host wires the panel's shared action handlers.
      plugins: component.pluginRegistry == null
          ? null
          : () => component.pluginRegistry!.homePlugins,
      pluginHost: _pluginHost,
    );
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
      _vibeDiffRequest = null;
      _skillFullpane = null;
      _notesFullpaneOpen = false;
    });
  }

  /// Open the "my notes" editor fullpane (the `notes` screen target of
  /// the notes widget's `open` screen action).
  void _openNotesFullpane() {
    setState(() {
      _notesFullpaneOpen = true;
      _overlayController.showFullpane = true;
    });
  }

  /// A `screen`-kind plugin action opens an in-process fullpane. The
  /// action's `screen` names which one; unknown names toast rather
  /// than failing silently. Pure UI — no session turn is started.
  void _handlePluginScreenAction(PluginAction action) {
    switch (action.screen) {
      case 'notes':
        _openNotesFullpane();
      default:
        _showToast(
          _strings.t('toast.unknownScreen', {'screen': '${action.screen}'}),
          mode: ToastMode.error,
        );
    }
  }

  /// A todo row clicked on a plugin: mark that todo done ([done]
  /// true) or restore it ([done] false — the undo click inside the
  /// 10-second window) in its backing document (the notes feature).
  /// The projection rewrite that follows updates the row; the item
  /// stays in the note, now checked (or back open). Fire-and-forget
  /// — a failed write must never block the sidebar.
  void _handlePluginTodoToggle(String text, int line, bool done) {
    unawaited(
      done
          ? _notesService.markTodoDone(line)
          : _notesService.markTodoOpen(line),
    );
  }

  /// The plugin wiring handed to BOTH renderers (sidebar rows and
  /// home boxes) — one [PluginHost] so a plugin behaves identically
  /// wherever it's placed. Deferred rebuild on each call reads the
  /// panel's live session state.
  PluginHost _pluginHost() => PluginHost(
        onPromptAction: _handlePluginPromptAction,
        onShellAction: _handlePluginShellAction,
        onScreenAction: _handlePluginScreenAction,
        onTodoToggle: _handlePluginTodoToggle,
        onAction: _recordPluginAction,
        projectPath: Directory.current.path,
      );

  /// Reveal a vibe file row's file in the system file manager (Finder on
  /// macOS, Explorer on Windows, the default manager on Linux). Wired to
  /// the row's `open` action. Toasts on failure so a missing file or
  /// absent helper never crashes the TUI.
  void _openVibeFile(String path) {
    final result = revealInFileManager(
      path,
      workingDirectory: Directory.current.path,
    );
    switch (result) {
      case RevealResult.launched:
        return;
      case RevealResult.notFound:
        _showToast(
          _strings.t('toast.fileNotFound', {'path': path}),
          mode: ToastMode.error,
        );
      case RevealResult.failed:
        _showToast(
          _strings.t('toast.fileManagerGeneric'),
          mode: ToastMode.error,
        );
    }
  }

  /// Open the segment-scoped diff fullpane focused on the file whose
  /// `diff` action was activated. The request carries the per-file
  /// entries, the segment's mutating calls, and the tapped file's index;
  /// the fullpane rebuilds each file's before/after from those args (no
  /// git, no live re-read).
  void _openVibeDiff(int fileIndex, ModBoxData mods, List<ToolCallData> calls) {
    setState(() {
      _vibeDiffRequest = VibeDiffRequest(
        files: mods.files,
        calls: calls,
        initialIndex: fileIndex,
      );
      _overlayController.showFullpane = true;
    });
  }

  void _openCompactionFullpane(Message message) {
    setState(() {
      _compactionFullpaneMessage = message;
      _overlayController.showFullpane = true;
    });
  }

  /// Open a read-only fullpane on a skill's SKILL.md (the home `skills`
  /// box). Home stays open underneath — `esc` out of the pane lands
  /// back on the dashboard.
  void _openSkillFullpane(SkillInfo skill) {
    setState(() {
      _skillFullpane = skill;
      _overlayController.showFullpane = true;
    });
  }

  Component _buildSessionManager() {
    return SessionManagementPanel(
      sessions: _sessionController.sessions,
      chats: _sessionController.chats,
      currentSessionId: _sessionController.currentSessionId ?? 0,
      strings: _strings,
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
    final overlays = <Component>[];
    final popover = buildOverlayPopover(
      overlay: _overlayController,
      maxVisible: _maxVisibleItems,
      strings: _strings,
      refresh: _refresh,
    );
    if (popover != null) {
      overlays.add(
        Positioned(bottom: 0, left: 0, right: 0, child: popover),
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
    _polling.syncAllProvidersUsage();
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
            // Home is an independent full screen, not an overlay: when
            // it's open, the chat interface (history, toolbar, input,
            // sidebar) is not built at all. Nothing else to lay out, no
            // z-order, and the home pane's own Focusable is the only
            // key consumer. `esc` (handled by Fullpane) or a home
            // action flips the flag back and the chat rebuilds.
            //
            // The root is ALWAYS a Stack (with home as its only child
            // when no fullpane is open): a fullpane opened from home
            // (the `my notes` box's `open`, the `skills` box) stacks on
            // top, and — critically — the tree root type never changes
            // between fullpane open/closed. ChatPanel.build runs inside
            // a LayoutBuilder's layout pass; swapping the root from
            // HomeScreen to Stack there would tear down and re-mount the
            // whole home subtree mid-layout, and the new fullpane's
            // focused Focusable stealing focus from the deactivating
            // home Focusable trips nocterm's markNeedsBuild lifecycle
            // assert. A stable Stack root keeps home's element alive.
            if (_overlayController.showHome) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: _buildHome()),
                  if (_overlayController.showFullpane)
                    Positioned.fill(child: _buildFullpane()),
                ],
              );
            }

            final showInfoPanel = constraints.maxWidth >= kSidebarShowThreshold;

            // Plan-mode horizontal split (§9.6 collapse order): with the
            // plan pane up, the info sidebar drops first when the three
            // panes would starve chat (< kPlanChatPaneMinWidth), and the
            // plan pane never grows wider than the chat pane.
            final bareSidebarWidth = showInfoPanel
                ? (kSidebarWidthMin +
                        0.3 * (constraints.maxWidth - kSidebarShowThreshold))
                    .clamp(kSidebarWidthMin, kSidebarWidthMax)
                : null;
            final layout = resolvePlanSplit(
              constraints.maxWidth,
              planActive: _planModeController.active,
              sidebarWidth: bareSidebarWidth,
            );

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
                        strings: _strings,
                        onToolCallTap: _openToolDetail,
                        onSessionLinkTap: _handleSessionLinkTap,
                        onQuickReplyTap: _handleQuickReplyTap,
                        onLinkTap: _handleMarkdownLinkTap,
                        onRetryContinue: _retryContinue,
                        onVibeOpenFile: _openVibeFile,
                        onVibeDiffFiles: _openVibeDiff,
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
                                ? _strings.t('chat.vibe.vibe')
                                : _strings.t('chat.vibe.verbose'),
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
                  onSyncModelsPressed: _activeProviderIsOpenRouter
                      ? _onSyncModelsPressed
                      : null,
                  strings: _strings,
                  compactEstimate: sessionId == null
                      ? null
                      : _compactEstimates[sessionId]?.estimate,
                  debugMode: CommandRegistry.instance.debugEnabled,
                  // When the side panel is visible the auxiliary
                  // button lives there (above the git status /
                  // project widgets); only render it in the toolbar
                  // on narrow terminals — or when plan mode's
                  // collapse order dropped the sidebar.
                  auxButtonInSidePanel: layout.showSidebar,
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
                    final showAskForm =
                        pending != null &&
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
                        strings: _strings,
                        recentProjectsStore: _recentProjectsStore,
                        activePlanName: () {
                          final path = _planModeController.planDocPath;
                          if (!_planModeController.active || path == null) {
                            return null;
                          }
                          return path.split(RegExp(r'[/\\]')).last;
                        },
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
                        // Plain ESC in the input navigates to the home
                        // screen. (Interrupting a stream is the model
                        // button's job now, not ESC's.)
                        onOpenHome: _openHome,
                        onAttachClipboardImage: (image) {
                          final sid = _sessionController.currentSessionId;
                          if (sid != null) {
                            _sessionController.addPendingImage(sid, image);
                            final index = _sessionController
                                .pendingImagesFor(sid)
                                .length;
                            _chatInputKey.currentState?.insertImageMarker(
                              index,
                            );
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
                      strings: _strings,
                    );
                  },
                ),
              ],
            );

            if (layout.showSidebar) {
              final panelWidth = layout.sidebarWidth;

              final planActive = _planModeController.active;
              final planPaneWidth = planActive
                  ? layout.planPaneWidth
                  : 0.0;

              final body = Row(
                children: [
                  if (planActive) ...[
                    SizedBox(
                      width: planPaneWidth,
                      child: PlanDocPane(
                        controller: _planModeController,
                        strings: _strings,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: CruxTheme.of(context).divider,
                    ),
                  ],
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
                      chats: _sessionController.chats,
                      currentSessionId:
                          _sessionController.currentSessionId ?? 0,
                      onSwitchSession: _switchSession,
                      onTogglePin: _sessionController.togglePin,
                      archivedCount: _sessionController.archivedCount,
                      archivedChatCount: _sessionController.archivedChatCount,
                      onCreateChat: _sessionController.createChatSession,
                      onCreateSession: _createNewSession,
                      gitStatusService: _gitStatusService,
                      plugins: component.pluginRegistry?.sidebarPlugins,
                      strings: _strings,
                      onSessionTitleTap: () {
                        setState(() {
                          _overlayController.showSessionManager = true;
                        });
                      },
                      onOpenProject: _openProjectInExplorer,
                      onSwitchProject: _switchProject,
                      sessionController: _sessionController,
                      onAuxiliaryPressed: _onAuxiliaryModelButtonPressed,
                      pluginHost: _pluginHost(),
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

            // Narrow terminal: no info sidebar, but plan mode can still
            // split the pane (the collapse order drops ExtraInfoPanel
            // first — §9.6).
            if (layout.planPaneWidth > 0) {
              return Row(
                children: [
                  SizedBox(
                    width: layout.planPaneWidth,
                    child: PlanDocPane(
                      controller: _planModeController,
                      strings: _strings,
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: CruxTheme.of(context).divider,
                  ),
                  Expanded(child: mainContent),
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

/// Read-only viewer for a skill's SKILL.md body, shown in a `Fullpane`
/// from the home `skills` box. The skill body is markdown, rendered
/// verbatim with the shared highlighted-markdown component inside a
/// scrollable viewport (mouse wheel + scrollbar). The description and
/// location sit above the divider so a long body doesn't push the
/// identity off screen.
class _SkillFullpaneContent extends StatefulComponent {
  final SkillInfo skill;

  const _SkillFullpaneContent({required this.skill});

  @override
  State<_SkillFullpaneContent> createState() => _SkillFullpaneContentState();
}

class _SkillFullpaneContentState extends State<_SkillFullpaneContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final skill = component.skill;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                skill.description,
                style: TextStyle(color: theme.onSurfaceVariant),
              ),
              Text(
                skill.location,
                style: TextStyle(color: theme.onSurfaceDim),
              ),
            ],
          ),
        ),
        Divider(color: theme.outline, height: 1),
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            thumbColor: theme.onSurfaceDim.withOpacity(0.4),
            trackColor: theme.surfaceVariant.withOpacity(0.3),
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
                child: HighlightedMarkdownText(skill.content),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

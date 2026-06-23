import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../commands/command_executor.dart';
import '../commands/registry.dart';
import '../lsp/actors/dart.dart';
import '../lsp/manager.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/git_status_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import '../services/recent_projects_store.dart';
import '../services/tool_executor.dart';
import '../services/web_provider_registry.dart';
import '../services/providers/tinyfish_web_provider.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/frame_profiler.dart';
import '../utils/run_metrics.dart';
import '../utils/url_launcher.dart';
import 'chat_history.dart';
import 'chat_input.dart';
import 'chat_toolbar.dart';
import 'chat_turn_orchestrator.dart';
import 'command_overlay.dart';
import 'extra_info_panel.dart';
import 'file_browser_overlay.dart';
import 'overlay_controller.dart';
import 'session_controller.dart';
import 'session_management_panel.dart';
import 'streaming_controller.dart';
import 'suggestion_overlay.dart';
import 'tool_detail_pane.dart';
import 'ui/toast.dart';
import 'ui/fullpane.dart';

/// Polling cadence for the coding-plan quota API.
///
/// Picked by [ChatPanel] on every build based on whether any
/// session is currently responding — the user is making API
/// calls, the quota is moving, so poll more often. 30s while
/// active gives near-real-time feedback on a heavy chat turn;
/// 180s when idle keeps the upstream endpoint mostly unbothered
/// during slow afternoons.
const Duration _kCodingPlanActiveInterval = Duration(seconds: 30);
const Duration _kCodingPlanIdleInterval = Duration(seconds: 180);

class ChatPanelBootState {
  final ProviderService providerService;
  final SessionStore store;
  final List<Session> sessions;
  final int currentSessionId;
  final int archivedCount;
  final Map<int, List<Message>> messageCache;
  final Map<String, int> currentFileReadState;

  /// Total number of messages in [currentSessionId]'s history, or null
  /// when the boot loader didn't run a COUNT(*) (e.g. empty session).
  /// When strictly greater than the size of `messageCache[currentSessionId]`,
  /// the chat panel kicks off the chunked loader in the background to
  /// fill in the older messages that boot skipped — see [loadChatPanelBootState].
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

/// Number of messages to load synchronously at boot. Tuned to be small
/// enough for a fast cold-cache first paint (with the v23/v24 indexes
/// on `messages.session_id`, this query reads only a few MB of pages),
/// but big enough that the user sees meaningful context (the bottom
/// of the chat with the most recent assistant turn). The remaining
/// older messages fill in via [SessionController.completeSwitchSession]
/// kicked off by [ChatPanel.initState] — same path as a mid-session
/// switch, so the boot UX matches the switch UX.
const int _kBootFirstChunkSize = 50;

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

  // Load only the first chunk synchronously. The previous single-fetch
  // `getMessages(limit: 1000)` blocked the splash screen until the full
  // session's worth of rows returned — and even with the v23 index on
  // `messages.session_id`, a 1000-row cold-cache read can still take
  // seconds. Loading just the latest 50 gets the chat panel mounted
  // quickly (typically <200ms with the index), and the remaining older
  // messages fill in via [SessionController.completeSwitchSession]
  // kicked off by the chat panel — same progressive flow as a mid-
  // session switch.
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
    // Surface the total so the chat panel knows whether the rest of
    // the session needs to be filled in via chunked loading.
    messagesTotal: messagesTotal,
  );
}

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;
  final ChatPanelBootState? bootState;
  final GitStatusService? gitStatusService;

  /// Shared store of recently-opened project directories. Owned by
  /// the binary (`bin/crux.dart`) and threaded through `_CruxApp`
  /// so this panel never creates its own instance — otherwise the
  /// cwd that the binary records at startup wouldn't be visible to
  /// the chat input's `/project` autocomplete (each store has its
  /// own in-memory list).
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

  /// History of recently-opened project directories. Loaded once
  /// during construction and threaded through to the chat input so
  /// the `/project` autocomplete can populate from real prior
  /// sessions rather than asking the user to type a path from
  /// scratch. Owned by the panel so it lives for the lifetime of
  /// the TUI (and so `/d-paths` can surface its on-disk location).
  late final RecentProjectsStore _recentProjectsStore;

  /// Live git-status snapshot of the project root. Owned by the
  /// panel (not by `_CruxApp`) so its lifetime exactly matches the
  /// chat panel's. The polling timer is started in [initState] and
  /// cancelled in [dispose]. The same instance is handed down to
  /// [ExtraInfoPanel] for both the status widget and the project
  /// widget's `path:branch ↑N ↓N` label, so a single timer drives
  /// both consumers.
  late final GitStatusService _gitStatusService;

  /// When non-null, a tool detail fullpane is shown for this tool call.
  ToolDetailData? _toolDetailData;

  bool _providerServiceReady = false;

  // ─── Coding-plan polling state ───────────────────────────────

  /// The active `CodingPlanProvider` mixin for the current
  /// model, or null if the active provider has no coding
  /// plan (DeepSeek, Local, custom) or no API key. Recomputed
  /// on every build; the toolbar reads this to decide
  /// whether to render the quota cell.
  ///
  /// The API key lives on the mixin itself (passed in via
  /// `startCodingPlanPolling(apiKey: …)`); we don't need to
  /// stash it separately on the panel.
  CodingPlanProvider? _activeCodingPlanProvider;

  // ─── Credit-balance polling state ────────────────────────────

  /// The active `CreditBalanceProvider` mixin for the current
  /// model, or null if the active provider has no credit
  /// balance or no API key. Recomputed on every build; the
  /// toolbar reads this to decide whether to render the
  /// balance cell.
  CreditBalanceProvider? _activeCreditBalanceProvider;

  /// The last provider name + activity state we synchronized
  /// coding-plan polling for. Used to short-circuit
  /// [_syncCodingPlanPolling] when nothing actually changed.
  String? _lastSyncedCpProviderName;
  bool? _lastSyncedCpHasActiveSession;

  /// The last provider name + activity state we synchronized
  /// credit-balance polling for. Used to short-circuit
  /// [_syncCreditBalancePolling] when nothing actually changed.
  String? _lastSyncedCbProviderName;
  bool? _lastSyncedCbHasActiveSession;

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
    final bootState = component.bootState;
    _providerService =
        bootState?.providerService ??
        ProviderService(
          userProvidersDir: component.userProvidersDir,
          builtInProvidersDir: component.builtInProvidersDir,
        );
    _store = bootState?.store ?? SessionStore(CruxDatabase());
    // Self-heal sessions whose `context_tokens` was reset to 0 by a
    // failed AI turn (network error / user ESC / stream interrupted
    // before the LLM reported any usage). Fire-and-forget — doesn't
    // block startup; repairs land before the next auto-compact
    // check fires on any of the affected sessions. Idempotent.
    unawaited(_store.repairStaleContextTokens());
    final tracker = FileReadTracker(
      onRecordRead: (sessionId, normalizedPath, mtimeMs) {
        return _store.saveFileReadState(sessionId, normalizedPath, mtimeMs);
      },
    );
    _tracker = tracker;
    // Wire the LSP manager. Phase 2.0: in-process actors. The
    // constructor is sync (no I/O) — the async `create()` helper
    // exists for the future IsolateChannel path. The session's
    // project directory (the cwd Crux was launched from) is the
    // root for finding project markers like `pubspec.yaml`.
    _lspManager = LspManager(
      workingDirectory: Directory.current.path,
      actorFactories: const {
        // Phase 2.0: dogfood the Dart server. The other 8 servers
        // from the design doc (typescript, python, rust, go, ruby,
        // lua, bash, yaml) get added in Phase 2.1 once we
        // validate the wiring through the live app.
        'dart': DartServerActor.new,
      },
    );
    // Set up the web-provider registry before the tool registry so
    // `registerDefaults` can route `webfetch` through the right
    // backend and decide whether to expose `websearch` at all.
    _webProviderRegistry = WebProviderRegistry()
      ..register(TinyFishWebProvider());
    unawaited(_webProviderRegistry.initialize());

    final registry = ToolRegistry();
    registry.registerDefaults(
      tracker,
      sessionStore: _store,
      webProviderRegistry: _webProviderRegistry,
      lsp: _lspManager,
    );
    final toolExecutor = ToolExecutor(registry);
    _toolRegistry = registry;
    _chatService = ChatService(
      _store,
      _providerService,
      LlmClient(),
      toolExecutor,
    );
    // Re-register the web tools when the user changes a provider
    // key. The stream fires after every `setApiKey` /
    // `removeApiKey`, so `/web-provider <name> key <value>`
    // lands the new `websearch` (or removes it) before the
    // LLM's next turn.
    _webProviderChangesSub = _webProviderRegistry.changes.listen((_) {
      registry.registerWebTools(_webProviderRegistry);
      setState(() {});
    });
    // Initialize the git-status service before handing it to collaborators.
    // `late final` reads throw during mount if this moves below the
    // `ChatTurnOrchestrator` construction.
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
    );

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
      _tracker.loadSession(
        bootState.currentSessionId,
        bootState.currentFileReadState,
      );

      // Boot loader only fetches the first chunk (~50 rows) so the
      // splash screen clears fast. If the session has more messages
      // than that, kick off the chunked loader in the background to
      // fill in the rest — same path a mid-session switch uses, so
      // the older history streams in via the same setState pipeline
      // (each chunk rebuilds the chat panel and the visible bubble
      // count grows). The chat panel's pre-existing onProgress
      // handler in [_switchSession] already proves the pattern
      // works; we're just applying it to the boot path.
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
    // Expose a per-frame snapshot of "what's running right now"
    // to the optional frame profiler. The snapshot is read at
    // the end of every frame (post-frame callback) so the report
    // can correlate slow frames with active timers / session
    // state. Only invoked while the profiler is actively
    // recording, so its cost is negligible when the profiler
    // is idle.
    FrameProfiler.instance.registerSnapshotProvider(_profilerSnapshot);
    // The recent-projects store is provided by `bin/crux.dart`,
    // which has already loaded the JSON file from disk and recorded
    // the launched cwd before we get here. Bind to it directly —
    // any `/project <path>` switches executed later in this session
    // will mutate this same instance and trigger a refresh via the
    // listener below, so the autocomplete overlay stays live.
    _recentProjectsStore = component.recentProjectsStore;
    _recentProjectsStore.addListener(_refresh);
    // The recent-projects store fires `notifyListeners()` after a
    // successful `/project <path>` switch (and also during
    // initial seeding by `bin/crux.dart`). We piggyback on that
    // signal to kick off a *synchronous* git-status refresh —
    // without it the user would see stale branch info for up to
    // 5s after switching projects.
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
    // Notify the frame profiler that a setState happened
    // before it propagates, so the next captured frame can
    // attribute itself to "setState" (or a timer, if one
    // fired first). No-op when the profiler is idle.
    FrameProfiler.instance.markSetState();
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

    // Split the old single-`await switchSession` path so the chat
    // panel can paint the new session's header + "Loading N
    // messages…" placeholder before any DB work happens. The
    // begin/complete split on SessionController also lets the chat
    // panel repaint between chunks via the onProgress callback,
    // turning a single blocking SELECT into a progressive fill-in
    // — the perceived latency for huge sessions drops from
    // "load all then paint" to "first paint in a few ms, then
    // messages stream in".
    final error = _sessionController.beginSwitchSession(id);
    if (error != null) {
      _showToast(error, mode: ToastMode.error);
      if (oldId != null && oldId != id) {
        final oldRt = _sessionController.runtime(oldId);
        if (oldRt.isResponding) {
          _streamingController.startMetricsTimer(oldId);
        }
      }
      setState(() {});
      return;
    }

    // First paint: new session header + the loading line in the
    // chat history's empty-state branch (or the cached messages if
    // this session was previously visited — the empty-state
    // branch only fires when the cache is actually empty).
    setState(() {});

    // Complete the switch: chunked message load + file-read state.
    // The two are independent reads, so kick them off in parallel
    // — file-read state is small (one keyed table) and finishes
    // quickly, but there's no reason to serialise it behind the
    // message load on the critical path.
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
    setState(() {});
  }

  /// Click handler for `ses://<id>` references inside an assistant
  /// message bubble. Delegates to [_switchSession] so the user
  /// gets the same loader, message-streaming, and input-stash
  /// behaviour they'd get from the session manager; surfaces any
  /// failure as a toast (e.g. `Session #N not found` when the
  /// referenced session was deleted, or `is running in another
  /// Crux instance` when another Crux owns it).
  ///
  /// No-op when the user clicks a ref to the session they're
  /// already viewing — switching to yourself would be a no-op
  /// anyway, but skipping it avoids the redundant setState and
  /// scroll-to-bottom.
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

  /// Resolve the active model's [CodingPlanProvider] mixin (if
  /// any) and re-align polling state with it. Idempotent — a
  /// no-op when neither the provider nor the session activity
  /// has changed since the last call. Called from [build] so
  /// model switches and turn start/stop transitions are picked
  /// up on the next paint.
  void _syncCodingPlanPolling() {
    if (!_providerServiceReady) return;

    // Identify the active provider name from the current model
    // (composite key form: `providerName/modelId`).
    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : null;

    // Look up the provider's LlmProvider instance and see if
    // it opted into the CodingPlanProvider mixin. Non-coding-
    // plan providers (DeepSeek, Local, custom) won't match.
    CodingPlanProvider? provider;
    String? apiKey;
    if (providerName != null) {
      final llm = _providerService.llmProviderByName(providerName);
      if (llm is CodingPlanProvider) {
        provider = llm;
        apiKey = _providerService.getApiKey(providerName);
        // If the key isn't set, treat the provider as "not
        // available" — no polling, no toolbar cell.
        if (apiKey == null || apiKey.isEmpty) {
          provider = null;
          apiKey = null;
        }
      }
    }

    // Is any session actively streaming? Drives the polling
    // cadence: 30s while busy, 180s when idle.
    final hasActive = _hasActiveSession();

    // No-op when nothing actually changed. The chat panel
    // rebuilds on every keystroke, so this short-circuit
    // matters — without it we'd re-issue start/stop on
    // every render.
    if (providerName == _lastSyncedCpProviderName &&
        hasActive == _lastSyncedCpHasActiveSession) {
      return;
    }

    // Provider changed (or activity changed for the same
    // provider). Stop the old polling, then start the new
    // one (if any). When activity flips while the provider
    // stays the same, just update the cadence — no need
    // to tear down the timer.
    final providerChanged = providerName != _lastSyncedCpProviderName;

    if (providerChanged && _activeCodingPlanProvider != null) {
      _activeCodingPlanProvider!.stopCodingPlanPolling();
      _activeCodingPlanProvider = null;
    }

    if (provider != null && apiKey != null) {
      _activeCodingPlanProvider = provider;
      provider.startCodingPlanPolling(
        apiKey: apiKey,
        interval: hasActive
            ? _kCodingPlanActiveInterval
            : _kCodingPlanIdleInterval,
      );
    }

    _lastSyncedCpProviderName = providerName;
    _lastSyncedCpHasActiveSession = hasActive;
  }

  /// True if any session in the panel is currently marked running.
  /// Covers non-current sessions too: a background session that's
  /// still streaming is "active" and the user wants the same
  /// freshness for it.
  ///
  /// Delegates to [SessionController.hasAnyRunningSession] so the
  /// Ctrl+C and `/quit` guards in [ChatInput] /
  /// [CommandExecutor] can't drift out of sync with this — they
  /// were once three independent copies of the same predicate,
  /// and the chat-input copy had been scoped to the current
  /// session by mistake.
  bool _hasActiveSession() => _sessionController.hasAnyRunningSession;

  void _refreshGitStatus() {
    unawaited(_gitStatusService.refresh());
  }

  /// Single exit path used by both `/quit` and the Ctrl+C handler.
  ///
  /// This is the load-bearing reason [ChatPanel] owns the exit
  /// rather than letting nocterm's default `CtrlCBehavior.immediateExit`
  /// do the work: that default calls `StdioBackend.requestExit(0)`,
  /// which schedules an `exit(0)` on a microtask — and that microtask
  /// runs before `runApp()`'s `runEventLoop` can notice `_shouldExit`
  /// (its `Timer.periodic(seconds: 1)` only fires once per second).
  /// Result: the process terminates without ever returning from
  /// `runApp()`, and the per-run summary that `bin/crux.dart` prints
  /// after `runApp()` returns never gets a chance to run.
  ///
  /// Doing the work ourselves lets us side-step the microtask race:
  ///
  ///   1. Stash the active theme on `RunMetrics` so any post-`runApp`
  ///      fallback in `bin/crux.dart` (only triggered by non-quit
  ///      exits like EOF on stdin) can still produce a styled summary.
  ///   2. Render the summary into the alt-screen so the user catches
  ///      a glimpse of it before the TUI tears down.
  ///   3. Manually emit the terminal-teardown escape codes that
  ///      `_performImmediateShutdown` would otherwise write, in the
  ///      same order nocterm uses internally — disable mouse/keyboard
  ///      tracking *before* leaving alt-screen, and pop the kitty
  ///      keyboard stack to match what nocterm enabled at startup.
  ///      Reversing any of these can leave the user's shell in a
  ///      state where the next prompt looks subtly wrong.
  ///   4. Re-print the styled summary into the main buffer so the
  ///      user sees it in the same place every other CLI tool's
  ///      output lands.
  ///   5. Chain `exit(0)` onto `stdout.flush()` so the flush
  ///      completes before the process terminates. Without the
  ///      explicit flush, dart:io's line-buffered stdout could drop
  ///      the box on a fast exit — especially when stdout is a TTY.
  ///
  /// We deliberately skip the public `shutdownApp()` entry point
  /// here because it funnels through the same microtask path we're
  /// trying to avoid. The fallback in `bin/crux.dart:_printRunSummary`
  /// still covers the rare cases where the exit is driven by
  /// something other than this method (e.g. the user closes stdin,
  /// or a future feature wires another shutdown path) — that's why
  /// step 1 above stashes the theme.
  void _quitAndPrintSummary() {
    RunMetrics.instance.setLastKnownTheme(
      component.themeController.activeTheme,
    );

    // Step 2: alt-screen copy. Best-effort — if formatting somehow
    // throws (it shouldn't, `_lastKnownTheme` was just set), keep
    // the main-buffer copy below safe.
    try {
      stdout.writeln();
      stdout.writeln(RunMetrics.instance.formatStyledSummary());
    } catch (_) {}

    // Step 3: terminal teardown escape codes, written directly to
    // stdout. Mirror the sequence in
    // `TerminalBinding._performImmediateShutdown` so the terminal
    // ends up in the same state it would after a normal exit.
    stdout.write('\x1B[?1003l'); // disable all motion tracking
    stdout.write('\x1B[?1006l'); // disable SGR mouse mode
    stdout.write('\x1B[?1002l'); // disable button event tracking
    stdout.write('\x1B[?1000l'); // disable basic mouse tracking
    stdout.write('\x1B[>4;0m'); // reset modifyOtherKeys
    stdout.write('\x1B[<u'); // pop kitty keyboard mode
    stdout.write('\x1B[?2004l'); // disable bracketed paste mode
    stdout.write('\x1B[?25h'); // show cursor
    stdout.write('\x1B[?1049l'); // leave alt-screen (main buffer)
    stdout.write('\x1B[0m'); // reset attributes

    // Step 4: re-print the styled summary into the main buffer
    // where every other CLI tool's output lands.
    stdout.writeln();
    stdout.writeln(RunMetrics.instance.formatStyledSummary());
    stdout.writeln();

    // Step 5: flush, then exit. The flush-then-exit chain is the
    // load-bearing piece — without it, dart:io's stdout buffer
    // can lose the last few bytes of the box on a fast exit.
    stdout.flush().then((_) => exit(0));
  }

  /// Resolve the active model's [CreditBalanceProvider] mixin
  /// (if any) and re-align polling state with it. Parallel to
  /// [_syncCodingPlanPolling] but for credit-balance providers
  /// (currently just DeepSeek).
  void _syncCreditBalancePolling() {
    if (!_providerServiceReady) return;

    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : null;

    CreditBalanceProvider? provider;
    String? apiKey;
    if (providerName != null) {
      final llm = _providerService.llmProviderByName(providerName);
      if (llm is CreditBalanceProvider) {
        provider = llm;
        apiKey = _providerService.getApiKey(providerName);
        if (apiKey == null || apiKey.isEmpty) {
          provider = null;
          apiKey = null;
        }
      }
    }

    final hasActive = _hasActiveSession();

    // No-op when nothing changed.
    if (providerName == _lastSyncedCbProviderName &&
        hasActive == _lastSyncedCbHasActiveSession) {
      return;
    }

    final providerChanged = providerName != _lastSyncedCbProviderName;

    if (providerChanged && _activeCreditBalanceProvider != null) {
      _activeCreditBalanceProvider!.stopCreditBalancePolling();
      _activeCreditBalanceProvider = null;
    }

    if (provider != null && apiKey != null) {
      _activeCreditBalanceProvider = provider;
      provider.startCreditBalancePolling(
        apiKey: apiKey,
        interval: hasActive
            ? _kCodingPlanActiveInterval
            : _kCodingPlanIdleInterval,
      );
    }

    _lastSyncedCbProviderName = providerName;
    _lastSyncedCbHasActiveSession = hasActive;
  }

  @override
  void dispose() {
    CommandRegistry.instance.removeListener(_refresh);
    // Drop the web-provider change subscription so the closure
    // over `setState` doesn't outlive the panel (otherwise
    // late key-change events would try to redraw a torn-down
    // widget tree).
    _webProviderChangesSub?.cancel();
    _webProviderChangesSub = null;
    FrameProfiler.instance.clearSnapshotProvider();
    // We only borrow the store — it's owned by `bin/crux.dart`,
    // which disposes it in `_CruxAppState.dispose()`. Dropping
    // our listener here keeps us from leaking the subscription
    // when the panel is torn down independently of the app
    // (relevant for tests that mount the panel in isolation).
    _recentProjectsStore.removeListener(_refresh);
    _recentProjectsStore.removeListener(_refreshGitStatus);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
    // Shut down LSP servers so the dart analysis process doesn't
    // outlive the panel (it would otherwise hang around until the
    // actor's kill timer fires). Fire-and-forget — dispose isn't
    // allowed to await.
    unawaited(_lspManager.shutdown());
    // Stop the coding-plan polling timer. The provider's
    // mixin owns the timer / stream / cache, so this just
    // tells it to stop firing. The mixin's `dispose` would
    // also close the stream controller, but we don't call
    // it here — the provider instance is shared with the
    // app's lifetime and other consumers may still want to
    // read `latestCodingPlanUsage`.
    _activeCodingPlanProvider?.stopCodingPlanPolling();
    _activeCodingPlanProvider = null;
    _activeCreditBalanceProvider?.stopCreditBalancePolling();
    _activeCreditBalanceProvider = null;
    // Stop the git-status poller. [GitStatusService.dispose]
    // cancels the timer AND clears listeners, so any subscriber
    // that outlives the panel won't keep firing into the void.
    _gitStatusService.dispose();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  /// Snapshot of chat-panel state for the frame profiler.
  /// Invoked at the end of every frame while a recording is
  /// active; the keys land in the per-frame `features` object
  /// in the JSON report so a slow frame can be attributed to
  /// "the metrics timer was on" or "tldr was generating" or
  /// "100 messages were rendered".
  ///
  /// Keep the keys flat and the values primitive — the map is
  /// JSON-serialised verbatim and a slow snapshot would defeat
  /// the point of the profiler.
  Map<String, dynamic> _profilerSnapshot() {
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final messages = _sessionController.currentMessages;
    final anyResponding = _sessionController.sessions.any(
      (s) => _sessionController.runtime(s.id).isResponding,
    );
    return {
      'sessionId': sessionId,
      'isResponding': rt?.isResponding ?? false,
      'isGeneratingTldr': rt?.isGeneratingTldr ?? false,
      'btwMode': rt?.btwMode ?? false,
      'interrupted': rt?.interrupted ?? false,
      'isGeneratingTitle': _sessionController.isGeneratingTitle,
      'messageCount': messages.length,
      'reasoningMsgs': messages
          .where((m) => m.reasoningContent.isNotEmpty)
          .length,
      'contextAnimActive': _streamingController.contextAnimTimerIsActive(),
      'anySessionResponding': anyResponding,
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
      // Wire the toolbar's "Compact" affordance (and `/compact`)
      // to the orchestrator's compaction entry point. Without
      // this, [CommandExecutor.executeCompact] sees a null
      // `compactSession` and surfaces the "Compaction
      // unavailable" toast — the click reaches the executor
      // but the actual implementation never runs.
      compactSession: _turnOrchestrator.compactCurrentSession,
      findLastUserMessage: _turnOrchestrator.findLastUserMessage,
      deleteMessagesFrom: _turnOrchestrator.deleteMessagesFrom,
      sendBtwTurn: _turnOrchestrator.sendBtwTurn,
      clearBtwTurns: _sessionController.clearBtwTurnsFor,
      // Hook `/quit` (and its alias `/exit`) to the same exit
      // path as Ctrl+C so the run-summary renderer sees the
      // current theme before the TUI tears down.
      quitApp: _quitAndPrintSummary,
      showFullpane: _openFullpane,
      recentProjectsStore: _recentProjectsStore,
    );
    await _commandExecutor.execute(text, ctx);
    setState(() {});
  }

  void _onModelButtonPressed() {
    _chatInputKey.currentState?.stashAndSetCommand('/model ');
  }

  void _onCompactButtonPressed() {
    unawaited(_executeCommand('/compact'));
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
                // `onTap` is the mouse equivalent of Enter on the
                // keyboard: insert the path at the active @ and
                // dismiss the popover. The chat input stores the
                // @-offset in the overlay; we re-resolve it here
                // via the text controller since the input is the
                // single source of truth for cursor position.
                setState(() {
                  overlay.selectedFileIndex = i;
                  overlay.insertAtMention(null);
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
    // Re-align the coding-plan polling timer with the current
    // active model + session activity. Idempotent — a no-op
    // when neither has changed since the last build.
    _syncCodingPlanPolling();

    // Re-align the credit-balance polling timer.
    _syncCreditBalancePolling();

    // Wrap the top-level build in a profiler section so
    // the report can show how much of each frame was spent
    // in the chat panel's build itself (vs. layout / paint
    // / nested widget builds that the chat history's own
    // timed section catches).
    return FrameProfiler.instance.timed('chatPanel.build', () {
      return LayoutBuilder(
        builder: (context, constraints) {
          final showInfoPanel = constraints.maxWidth >= _infoPanelShowThreshold;

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
                codingPlanProvider: _activeCodingPlanProvider,
                creditBalanceProvider: _activeCreditBalanceProvider,
                onCodingPlanTap: _activeCodingPlanProvider?.refreshNow,
                onCreditBalanceTap: _activeCreditBalanceProvider?.refreshNow,
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
                  // Auto-scroll to bottom when the user submits a message.
                  // This is critical when previous turns had expanded thinking
                  // bubbles that collapse on the new turn — without this, the
                  // scroll position drifts above the bottom and auto-scroll
                  // won't engage for the new streaming content.
                  scrollController.scrollToBottom();
                },
                onExecuteCommand: _executeCommand,
                onSwitchSession: _switchSession,
                onInitSessions: _initSessions,
                onCreateNewSession: _createNewSession,
                // Same exit path the `/quit` command uses
                // — see [_quitAndPrintSummary] for the
                // load-bearing reason we don't just call
                // `shutdownApp` here. The chat input always
                // returns `true` from its Ctrl+C handler so
                // nocterm's default `immediateExit` doesn't
                // race us to `exit(0)`.
                onQuitRequest: _quitAndPrintSummary,
                onAttachClipboardImage: (image) {
                  final sid = _sessionController.currentSessionId;
                  if (sid != null) {
                    _sessionController.addPendingImage(sid, image);
                    // Insert an inline text marker at the cursor so the
                    // user sees where the image is referenced in their
                    // message (mirroring opencode's `[image:filename]`
                    // placeholder pattern). The marker is purely
                    // informational — the actual image data lives in
                    // `pendingImages` and is sent alongside the text.
                    final index = _sessionController
                        .pendingImagesFor(sid)
                        .length;
                    _chatInputKey.currentState?.insertImageMarker(index);
                    _refresh();
                  }
                },
              ),
            ],
          );

          if (showInfoPanel) {
            final panelWidth =
                (_infoPanelWidthMin +
                        0.3 * (constraints.maxWidth - _infoPanelShowThreshold))
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
                    currentSessionId: _sessionController.currentSessionId ?? 0,
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
    });
  }
}

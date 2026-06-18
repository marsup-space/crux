import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../commands/command_executor.dart';
import '../commands/registry.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import '../services/recent_projects_store.dart';
import '../services/tool_executor.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_store.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/frame_profiler.dart';
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

class ChatPanel extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;

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
  late final ToolRegistry _toolRegistry;
  late final SessionController _sessionController;
  late final OverlayController _overlayController;
  late final StreamingController _streamingController;
  late final CommandExecutor _commandExecutor;
  late final ChatTurnOrchestrator _turnOrchestrator;
  late final FileReadTracker _tracker;

  /// History of recently-opened project directories. Loaded once
  /// during construction and threaded through to the chat input so
  /// the `/project` autocomplete can populate from real prior
  /// sessions rather than asking the user to type a path from
  /// scratch. Owned by the panel so it lives for the lifetime of
  /// the TUI (and so `/d-paths` can surface its on-disk location).
  late final RecentProjectsStore _recentProjectsStore;

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
    _providerService = ProviderService(
      userProvidersDir: component.userProvidersDir,
      builtInProvidersDir: component.builtInProvidersDir,
    );
    final db = CruxDatabase();
    _store = SessionStore(db);
    // Reconcile any sessions left in `running` from a previous Crux
    // process that didn't shut down cleanly. Fire-and-forget — the
    // UI's session list is loaded async by `_initSessions` below, and
    // the (very small) write will land before the user can navigate
    // to a session that was affected.
    _store.markOrphanedRunningSessionsAsInterrupted();
    final tracker = FileReadTracker(
      onRecordRead: (sessionId, normalizedPath, mtimeMs) {
        return _store.saveFileReadState(sessionId, normalizedPath, mtimeMs);
      },
    );
    _tracker = tracker;
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
    final providerName = slashIdx > 0
        ? modelKey.substring(0, slashIdx)
        : null;

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

  /// True if any session in the panel is currently
  /// `isResponding`. Covers non-current sessions too: a
  /// background session that's still streaming is "active"
  /// and the user wants the same freshness for it.
  bool _hasActiveSession() {
    for (final s in _sessionController.sessions) {
      if (_sessionController.runtime(s.id).isResponding) return true;
    }
    return false;
  }

  /// Resolve the active model's [CreditBalanceProvider] mixin
  /// (if any) and re-align polling state with it. Parallel to
  /// [_syncCodingPlanPolling] but for credit-balance providers
  /// (currently just DeepSeek).
  void _syncCreditBalancePolling() {
    if (!_providerServiceReady) return;

    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0
        ? modelKey.substring(0, slashIdx)
        : null;

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
    FrameProfiler.instance.clearSnapshotProvider();
    // We only borrow the store — it's owned by `bin/crux.dart`,
    // which disposes it in `_CruxAppState.dispose()`. Dropping
    // our listener here keeps us from leaking the subscription
    // when the panel is torn down independently of the app
    // (relevant for tests that mount the panel in isolation).
    _recentProjectsStore.removeListener(_refresh);
    _chatService.dispose();
    _sessionController.dispose();
    _streamingController.dispose();
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
    final rt = sessionId != null
        ? _sessionController.runtime(sessionId)
        : null;
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
      'reasoningMsgs':
          messages.where((m) => m.reasoningContent.isNotEmpty).length,
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
      recentProjectsStore: _recentProjectsStore,
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
            codingPlanProvider: _activeCodingPlanProvider,
            creditBalanceProvider: _activeCreditBalanceProvider,
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
                final index =
                    _sessionController.pendingImagesFor(sid).length;
                _chatInputKey.currentState?.insertImageMarker(index);
                _refresh();
              }
            },
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
    });
  }
}

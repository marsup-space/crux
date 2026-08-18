import 'dart:async';

import '../i18n/reply_language.dart';
import '../models/chat_types.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import '../storage/shell_monitor_log_store.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import 'auxiliary_prompts.dart';
import 'auxiliary_service.dart';
import 'chat_turn_executor.dart';
import 'compaction_service.dart';
import 'llm_client.dart';
import 'llm_error.dart';
import 'prompts/system_prompt.dart';
import 'provider_service.dart';
import 'session_lease_manager.dart';
import 'tool_executor.dart';
import 'wire_format.dart' as wire_format;
import 'wire_format.dart';

// Re-export the public API surface so existing callers only need to
// import this file.
export '../models/chat_types.dart';
export 'wire_format.dart'
    show
        buildApiMessages,
        currentContextTokens,
        estimateProjectedContextTokens,
        computeCompactionReserveAndThreshold,
        ResolvedChatTarget;

/// Facade for the chat subsystem.
///
/// Delegates to:
///   - [SessionLeaseManager] — session lease/heartbeat/cancel state
///   - [CompactionService] — in-place chat-log compaction
///   - [ChatTurnExecutor] — the agentic loop (stream LLM, run tools, persist)
///   - [AuxiliaryService] — title generation, TL;DR, system prompt rebuilds
///
/// This class is intentionally thin — it owns the lifecycle of its
/// collaborators and forwards public API calls to the right one.
class ChatService {
  final CompactionService _compaction;
  final ChatTurnExecutor _turnExecutor;
  final AuxiliaryService _auxiliaryService;
  final SessionStore _store;
  final ProviderService _providerService;
  final ReplyLanguageProvider _replyLanguage;

  /// Create a [ChatService] with the given dependencies.
  ///
  /// [replyLanguage] resolves the current reply-language policy at
  /// prompt-build time, so `/reply-language` and `/language` changes made
  /// mid-run are picked up on the next turn. Defaults to the fallback
  /// policy in tests / legacy harnesses.
  ChatService(
    SessionStore store,
    ProviderService providerService,
    LlmClient llmClient,
    ToolExecutor toolExecutor, {
    ReplyLanguageProvider? replyLanguage,
  })  : _store = store,
        _providerService = providerService,
        _replyLanguage =
            replyLanguage ?? (() => ReplyLanguageSettings.fallback),
        _compaction = CompactionService(
          store,
          providerService,
          replyLanguage: replyLanguage,
        ),
        _turnExecutor = ChatTurnExecutor(
          store,
          providerService,
          llmClient,
          toolExecutor,
          SessionLeaseManager(),
          replyLanguage: replyLanguage,
        ),
        _auxiliaryService = AuxiliaryService(
          providerService,
          store.messageStore,
          replyLanguage: replyLanguage,
        );

  /// Called when a write/edit tool call mutated the plan-mode document
  /// (§5 P4). Forwarded to the turn executor; wired by the chat panel
  /// to `PlanModeController.onAgentEdit`. `sessionId` identifies which
  /// session's turn made the edit.
  void Function(String oldContent, String newContent, int sessionId)?
      get onPlanDocMutated => _turnExecutor.onPlanDocMutated;
  set onPlanDocMutated(
      void Function(String oldContent, String newContent, int sessionId)?
          value) =>
      _turnExecutor.onPlanDocMutated = value;

  // ── Session lease ─────────────────────────────────────────────────

  /// Store for `shell_monitor_logs` (one row per aux-monitor event).
  /// Exposed so `/d-monitor` can read recent runs without going
  /// through the turn executor. Shared with the monitor log sink the
  /// executor wires into shell tools.
  ShellMonitorLogStore get shellMonitorLogStore => _store.shellMonitorLogStore;

  /// True when [sessionId] is actively streaming.
  bool isStreaming(int sessionId) =>
      _turnExecutor.leaseManager.isStreaming(sessionId);

  /// Request that the stream for [sessionId] be cancelled.
  void cancelStream(int sessionId) =>
      _turnExecutor.leaseManager.cancelStream(sessionId);

  // ── Auxiliary ─────────────────────────────────────────────────────

  /// Rebuild and persist the system prompt for [sessionId].
  Future<void> rebuildSystemPrompt(int sessionId) async {
    final session = await _store.getById(sessionId);
    if (session == null) return;
    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    if (slashIndex <= 0) return;
    final providerName = compositeKey.substring(0, slashIndex);
    final modelId = compositeKey.substring(slashIndex + 1);
    final provider = _providerService.providerByName(providerName);
    final model = provider?.modelById(modelId);
    if (provider == null || model == null) return;

    // For chats, always rebuild from the current (workspace-free)
    // template — a prompt cached before the workspace-leak fix would
    // otherwise survive because `built == session.systemPrompt` only
    // guards against no-op writes, not against a stale cached value.
    final built = session.isChat
        ? buildChatSystemPrompt(
            provider: provider,
            model: model,
            sessionStarted: session.createdAt,
            replyLanguage: _replyLanguage(),
          )
        : buildSystemPrompt(
            provider: provider,
            model: model,
            cwd: session.projectPath,
            worktree: session.projectPath,
            sessionStarted: session.createdAt,
            replyLanguage: _replyLanguage(),
          );
    if (built == session.systemPrompt) return;
    await _store.update(sessionId, systemPrompt: built);
  }

  /// Auto-compaction hook (deprecated — use [createChatLogCompaction]).
  @Deprecated('Use createChatLogCompaction (in-place chat log).')
  Future<CompactionResult?> maybeAutoCompactIntoChildSession({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required String incomingUserContent,
    required List<Map<String, dynamic>> toolDefs,
    Future<void> Function(Session childSession, Message placeholderMessage)?
    onChildReady,
  }) async {
    return null;
  }

  Future<String?> generateSessionTitle(int sessionId, {String? userContent}) =>
      _auxiliaryService.generateTitle(sessionId, userContent: userContent);

  Future<String?> generateTldr(
    String responseContent, {
    String? userQuestion,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) => _auxiliaryService.generateTldr(
    responseContent,
    userQuestion: userQuestion,
    detail: detail,
  );

  /// Summarize recent work for the home screen's Yesterday box.
  /// Single-round auxiliary call (no tools) over the most recent day
  /// with activity (walking back up to
  /// [AuxiliaryService.maxLookbackDays]), cached by the day-set
  /// fingerprint. See [AuxiliaryService.summarizeYesterday].
  Future<YesterdaySummary?> summarizeYesterday(
    List<Session> sessions, {
    String? language,
  }) => _auxiliaryService.summarizeYesterday(sessions, language: language);

  // ── Compaction ────────────────────────────────────────────────────

  /// In-place chat-log compaction. Returns a [ChatLogCompactionResult]
  /// when compaction fired, or `null` when nothing was needed.
  Future<ChatLogCompactionResult?> createChatLogCompaction({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required ToolRegistry toolRegistry,
    required CompactionReason reason,
  }) => _compaction.createChatLogCompaction(
    sessionId: sessionId,
    session: session,
    runtime: runtime,
    toolRegistry: toolRegistry,
    reason: reason,
  );

  /// Project what an in-place chat-log compaction would produce,
  /// WITHOUT writing to the DB.
  Future<ChatLogCompactionEstimate?> estimateChatLogCompaction({
    required int sessionId,
    required Session session,
    required ToolRegistry toolRegistry,
    String? incomingUserContent,
  }) => _compaction.estimateChatLogCompaction(
    sessionId: sessionId,
    session: session,
    toolRegistry: toolRegistry,
    incomingUserContent: incomingUserContent,
  );

  // Deprecated LLM-summary compaction path.
  @Deprecated('Use createChatLogCompaction (in-place chat-log compaction).')
  Future<CompactionResult> compactIntoChildSession({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required CompactionReason reason,
    required List<Map<String, dynamic>> toolDefs,
    ResolvedChatTarget? resolved,
    int? preTokensOverride,
    Future<void> Function(Session childSession, Message placeholderMessage)?
    onChildReady,
  }) async {
    throw StateError(
      'compactIntoChildSession is no longer supported. '
      'Use createChatLogCompaction (in-place chat-log compaction) instead.',
    );
  }

  // ── Turn execution ────────────────────────────────────────────────

  /// Run a single chat turn for [sessionId].
  Future<void> sendMessage({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required FutureOr<void> Function(ChatResponse response) onComplete,
    required void Function(LlmError error) onError,
    void Function(String status)? onStatus,
    FutureOr<void> Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    void Function(List<ToolCallData> toolCalls)? onToolExecutionStart,
    void Function(StreamingGuardAbortEvent event)? onStreamingGuardAbort,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
    List<ImageAttachment> images = const [],
  }) => _turnExecutor.sendMessage(
    sessionId: sessionId,
    session: session,
    runtime: runtime,
    onDelta: onDelta,
    onReasoning: onReasoning,
    onChunk: onChunk,
    onComplete: onComplete,
    onError: onError,
    onStatus: onStatus,
    onToolRound: onToolRound,
    onToolUse: onToolUse,
    onToolExecutionStart: onToolExecutionStart,
    onStreamingGuardAbort: onStreamingGuardAbort,
    onQueueDrain: onQueueDrain,
    onAbortSignal: onAbortSignal,
    userContent: userContent,
    images: images,
  );

  // ── Lifecycle ─────────────────────────────────────────────────────

  void dispose() {
    _turnExecutor.leaseManager.dispose();
    _turnExecutor.dispose();
  }

  // ── Static delegating methods (backward compatibility) ────────────
  // Tests call these as `ChatService.staticMethod(...)`. They delegate
  // to the top-level functions in wire_format.dart.

  static List<Map<String, dynamic>> buildApiMessages(
    List<Message> history,
    WireFamily wireFamily, {
    String? systemPrompt,
  }) => wire_format.buildApiMessages(
    history,
    wireFamily,
    systemPrompt: systemPrompt,
  );

  static int estimateProjectedContextTokens({
    required Session session,
    required String? systemPrompt,
    required List<Message> history,
    required String? incomingUserContent,
    required List<Map<String, dynamic>> toolDefs,
  }) => wire_format.estimateProjectedContextTokens(
    session: session,
    systemPrompt: systemPrompt,
    history: history,
    incomingUserContent: incomingUserContent,
    toolDefs: toolDefs,
  );

  static ({int reserve, int threshold}) computeCompactionReserveAndThreshold({
    required int contextSize,
  }) => wire_format.computeCompactionReserveAndThreshold(
    contextSize: contextSize,
  );

  static int currentContextTokens({
    required List<Message> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? toolDefs,
    String? incomingUserContent,
  }) => wire_format.currentContextTokens(
    messages: messages,
    systemPrompt: systemPrompt,
    toolDefs: toolDefs,
    incomingUserContent: incomingUserContent,
  );
}

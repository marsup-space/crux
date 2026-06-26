import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../components/tool_guard_bubble.dart' show ToolGuardKind;
import '../lsp/diagnostic.dart' show buildLspPayload, errorDiagnostics;
import '../lsp/protocol.dart' show LspDiagnostic;
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/message_store.dart';
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../tools/shell_guard.dart';
import '../tools/tool_def.dart';
import '../utils/frame_profiler.dart';
import '../utils/partial_json_field_extractor.dart';
import '../utils/token_estimate.dart';
import 'auxiliary_prompts.dart';
import 'auxiliary_service.dart';
import 'compaction/chat_log_builder.dart';
import 'compaction/summary_collector.dart';
import 'install_slug.dart';
import 'llm_client.dart';
import 'prompts/code_search_hint.dart';
import 'prompts/praise_prompts.dart';
import 'prompts/system_prompt.dart';
import 'provider_service.dart';
import 'tool_executor.dart';

class ChatResponse {
  final int promptTokens;
  final int completionTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;

  /// If non-null, the user queued a message during streaming that
  /// should be sent as a new turn immediately after this response
  /// completes. The caller (ChatPanel) uses this to auto-kick off
  /// a new `_sendTurn` so the queued message reaches the LLM
  /// without the user having to re-submit.
  final String? queuedMessage;

  const ChatResponse({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.promptCacheHitTokens = 0,
    this.promptCacheMissTokens = 0,
    this.queuedMessage,
  });
}

enum CompactionReason { auto, manual }

class CompactionResult {
  final Session childSession;
  final Message summaryMessage;
  final int preTokens;
  final int postEstimateTokens;
  final int toolcallRetryCount;

  const CompactionResult({
    required this.childSession,
    required this.summaryMessage,
    required this.preTokens,
    required this.postEstimateTokens,
    required this.toolcallRetryCount,
  });
}

/// Result of [ChatService.createChatLogCompaction] — the in-place
/// chat-log compaction that replaced the old LLM-summary + child
/// session path. The chat-log compaction inserts a
/// `role: 'compaction'` message IN the current session (no child
/// session); the wire layer skips messages older than the latest
/// compaction so the LLM only sees the new activity + the chat
/// log.
class ChatLogCompactionResult {
  /// The newly inserted compaction message. Its `content` is the
  /// meta-prompt-wrapped chat log; `meta` carries the strategy +
  /// source-id range + timestamp + preTokens.
  final Message compactionMessage;

  /// Files that the chat log summarised via `read files:`. The
  /// caller replays these through [FileReadTracker] so the
  /// read-before-write guard sees fresh mtimes post-compact.
  final List<FileReadMarker> fileMarkers;

  /// Projected token count of the full history + system prompt +
  /// tool defs before compaction.
  final int preTokens;

  /// Estimated token count after compaction (system prompt + chat
  /// log + tool defs). The session's `contextTokens` is rewritten
  /// to this value.
  final int postEstimateTokens;

  /// First / last message id included in the compacted range.
  final int sourceStartMessageId;
  final int sourceEndMessageId;

  const ChatLogCompactionResult({
    required this.compactionMessage,
    required this.fileMarkers,
    required this.preTokens,
    required this.postEstimateTokens,
    required this.sourceStartMessageId,
    required this.sourceEndMessageId,
  });
}

/// Pure-projection result of [ChatService.estimateChatLogCompaction] —
/// what an in-place chat-log compaction WOULD produce, without
/// writing to the DB. The chat panel's context bar surfaces this
/// as a `→ 56k` hint next to the current usage, and the
/// auto-compact toast shows it before the actual compact runs.
class ChatLogCompactionEstimate {
  final int preTokens;
  final int postEstimateTokens;
  final int messageCount;

  const ChatLogCompactionEstimate({
    required this.preTokens,
    required this.postEstimateTokens,
    required this.messageCount,
  });
}

/// Internal struct shared by [ChatService.createChatLogCompaction]
/// (which uses it to insert the compaction message) and
/// [ChatService.estimateChatLogCompaction] (which uses it only
/// for the pre/post token counts). The `toCompress` slice and
/// the rendered `wrapped` chat log are produced once and then
/// either persisted or discarded depending on the caller.
class _CompactionPreview {
  final List<Message> toCompress;
  final String wrapped;
  final List<FileReadMarker> fileMarkers;
  final int preTokens;
  final int postEstimateTokens;

  const _CompactionPreview({
    required this.toCompress,
    required this.wrapped,
    required this.fileMarkers,
    required this.preTokens,
    required this.postEstimateTokens,
  });
}

class ResolvedChatTarget {
  final String providerName;
  final String modelId;
  final ProviderConfig provider;
  final String apiKey;
  final ModelConfig modelConfig;
  final String? systemPrompt;

  const ResolvedChatTarget({
    required this.providerName,
    required this.modelId,
    required this.provider,
    required this.apiKey,
    required this.modelConfig,
    required this.systemPrompt,
  });
}

class StreamingGuardAbortEvent {
  final int index;
  final String callId;
  final String name;
  final String filePath;
  final String reason;

  /// Estimated tokens of the tool-call's partial JSON arguments
  /// that had streamed in by the moment we aborted. Counts only
  /// this tool call's own `input_delta` chunks — not earlier
  /// text/reasoning and not sibling tool calls in the same round.
  final int abortedInputTokensEstimate;

  const StreamingGuardAbortEvent({
    required this.index,
    required this.callId,
    required this.name,
    required this.filePath,
    required this.reason,
    required this.abortedInputTokensEstimate,
  });
}

class ChatService {
  final SessionStore _store;
  final MessageStore _messageStore;
  final ProviderService _providerService;
  final LlmClient _llmClient;
  final ToolExecutor _toolExecutor;
  final AuxiliaryService _auxiliaryService;
  final Set<int> _activeSessions = {};
  final Set<int> _cancelRequested = {};
  final Map<int, Timer> _leaseHeartbeatTimers = {};

  static const Duration _leaseHeartbeatInterval = Duration(seconds: 5);

  ChatService(
    this._store,
    this._providerService,
    this._llmClient,
    this._toolExecutor,
  ) : _messageStore = _store.messageStore,
      _auxiliaryService = AuxiliaryService(
        _providerService,
        _store.messageStore,
      );

  bool isStreaming(int sessionId) => _activeSessions.contains(sessionId);

  void _markSessionActive(int sessionId) {
    _activeSessions.add(sessionId);
    _startLeaseHeartbeat(sessionId);
  }

  void _markSessionInactive(int sessionId) {
    _activeSessions.remove(sessionId);
    _stopLeaseHeartbeat(sessionId);
  }

  void _startLeaseHeartbeat(int sessionId) {
    _stopLeaseHeartbeat(sessionId);
    _store.heartbeatRunningSession(sessionId);
    _leaseHeartbeatTimers[sessionId] = Timer.periodic(
      _leaseHeartbeatInterval,
      (_) => _store.heartbeatRunningSession(sessionId),
    );
  }

  void _stopLeaseHeartbeat(int sessionId) {
    _leaseHeartbeatTimers.remove(sessionId)?.cancel();
  }

  void cancelStream(int sessionId) {
    _cancelRequested.add(sessionId);
  }

  /// Rebuild and persist the system prompt for [sessionId].
  ///
  /// Call this after any change that invalidates the cache key:
  /// model switch, provider TOML reload, project notes edit, etc.
  /// The next turn will pick up the new value automatically.
  ///
  /// Idempotent — calling when the system prompt is already current
  /// is a no-op (the result is byte-identical so the column write
  /// is wasted but harmless).
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

    final built = buildSystemPrompt(
      provider: provider,
      model: model,
      cwd: session.projectPath,
      worktree: session.projectPath,
      sessionStarted: session.createdAt,
    );
    if (built == session.systemPrompt) return;
    await _store.update(sessionId, systemPrompt: built);
  }

  Future<String?> generateSessionTitle(int sessionId, {String? userContent}) =>
      _auxiliaryService.generateTitle(sessionId, userContent: userContent);

  Future<String?> generateTldr(
    String responseContent, {
    String? userQuestion,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) =>
      _auxiliaryService.generateTldr(
        responseContent,
        userQuestion: userQuestion,
        detail: detail,
      );

  /// Auto-compaction hook used by the orchestrator on each new
/// user turn. Returns a [ChatLogCompactionResult] when compaction
/// fired, or `null` when nothing was needed (most turns).
///
/// Old signature kept as a stub: the LLM-summary + child-session
/// path has been retired in favour of the in-place chat-log path.
/// New callers should invoke [createChatLogCompaction] directly.
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
    // LLM-summary compaction has been retired. Callers should
    // invoke [createChatLogCompaction] directly when they want
    // the chat-log compaction; auto-compaction in [sendTurn] now
    // drives the in-place path itself.
    return null;
  }

  /// In-place chat-log compaction. Builds a deterministic
  /// activity-log summary of the messages after the latest
  /// existing compaction (or all messages if none) and inserts
  /// a single `role: 'compaction'` message into the SAME session
  /// — no child session. The wire layer ([buildApiMessages])
  /// then skips everything older than the latest compaction, so
  /// the LLM only sees the post-compaction tail + the chat log.
  ///
  /// Returns `null` when there's nothing compressible (empty
  /// history, or the only thing after the last compaction is
  /// already another compaction message).
  Future<ChatLogCompactionResult?> createChatLogCompaction({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required ToolRegistry toolRegistry,
    required CompactionReason reason,
  }) async {
    if (_envTruthy('CRUX_DISABLE_COMPACT')) return null;

    final history = await _messageStore.getMessages(sessionId);
    final toolDefs = toolRegistry.toApiTools();
    final resolved = await _resolveChatTarget(session);

    // Find the tail to compact and project the post-compaction
    // sizes. Shared with [estimateChatLogCompaction] so the
    // pre-/post-tokens shown in the hint match what the actual
    // compaction produces.
    final preview = _buildCompactionPreview(
      session: session,
      history: history,
      toolDefs: toolDefs,
      resolved: resolved,
      incomingUserContent: null,
      toolRegistry: toolRegistry,
    );
    if (preview == null) return null;
    final toCompress = preview.toCompress;

    // Final gate: skip when the projection says compacting would
    // grow the context (post > pre). The chat panel's
    // `_executeCommand` and the context bar's `onTap: null`
    // already short-circuit user-facing paths, but those rely
    // on the cached estimate. The cached value is a fast pre-
    // filter; this is the authoritative gate. It also covers
    // the auto-compact path in `sendTurn` (which doesn't read
    // the chat panel's cache) and any future programmatic
    // caller. Same `>` boundary as the hover label so the
    // behavior is consistent across all entry points.
    if (preview.postEstimateTokens > preview.preTokens) {
      return null;
    }

    // Replace prior compactions. In the "replace from scratch"
    // model the session only ever has one `compaction`-role
    // message — the latest one. Delete the prior `complete`
    // ones BEFORE inserting the new compaction so the chat
    // history briefly has zero of them (the in-flight message
    // list is in-memory; the new compaction is added
    // immediately after this DELETE returns, so a concurrent
    // reader can only see "0 or 1" compactions, never 2+).
    // `deleteCompleteCompactions` skips in-progress markers
    // (status: 'compacting') — those represent a half-finished
    // write and are reaped by their own try/catch block.
    await _messageStore.deleteCompleteCompactions(sessionId);

    final compactionMessage = await _messageStore.addMessage(
      sessionId,
      role: 'compaction',
      content: preview.wrapped,
      model: session.model,
      meta: jsonEncode({
        'status': 'complete',
        'strategy': 'chat-log-v1',
        'reason': reason.name,
        'sourceStartMessageId': toCompress.first.id,
        'sourceEndMessageId': toCompress.last.id,
        'compactedAt': DateTime.now().millisecondsSinceEpoch,
        'preTokens': preview.preTokens,
      }),
    );

    await _store.update(sessionId, contextTokens: preview.postEstimateTokens);
    // Mirror the new value onto the in-memory `Session` object.
    // [SessionController.computeBaseContext] reads
    // `session.contextTokens` (NOT the DB column) when computing
    // the next turn's `turnBaseTokens` — without this mirror,
    // the very next `sendTurn` after a compact would still see
    // the pre-compact value and the context bar would jump back
    // up to it for the duration of the new turn, only settling
    // back down once `_sendMessageUnsafe` overwrites the in-
    // memory value at the end of the turn.
    session.contextTokens = preview.postEstimateTokens;
    runtime.contextTargetTokens = preview.postEstimateTokens;
    runtime.contextDisplayTokens = preview.postEstimateTokens.toDouble();

    return ChatLogCompactionResult(
      compactionMessage: compactionMessage,
      fileMarkers: preview.fileMarkers,
      preTokens: preview.preTokens,
      postEstimateTokens: preview.postEstimateTokens,
      sourceStartMessageId: toCompress.first.id,
      sourceEndMessageId: toCompress.last.id,
    );
  }

  /// Project what an in-place chat-log compaction would produce
  /// right now, WITHOUT writing to the DB or updating the
  /// runtime. Used by the context bar's hint label and the
  /// auto-compact / `/compact` toasts so the user sees the
  /// `X → Y` estimate before (or alongside) the actual compact.
  ///
  /// The estimate is fast for typical sessions: a deterministic
  /// `buildChatLog` walk over the messages plus one read per
  /// `read`/`write`/`edit` tool call (bounded at
  /// [kInlineReadMaxChars] = 100KB per file). Returns `null`
  /// when there's nothing to compact.
  Future<ChatLogCompactionEstimate?> estimateChatLogCompaction({
    required int sessionId,
    required Session session,
    required ToolRegistry toolRegistry,
    String? incomingUserContent,
  }) async {
    if (_envTruthy('CRUX_DISABLE_COMPACT')) return null;

    final history = await _messageStore.getMessages(sessionId);
    final toolDefs = toolRegistry.toApiTools();
    final resolved = await _resolveChatTarget(session);

    final preview = _buildCompactionPreview(
      session: session,
      history: history,
      toolDefs: toolDefs,
      resolved: resolved,
      incomingUserContent: incomingUserContent,
      toolRegistry: toolRegistry,
    );
    if (preview == null) return null;
    return ChatLogCompactionEstimate(
      preTokens: preview.preTokens,
      postEstimateTokens: preview.postEstimateTokens,
      messageCount: preview.toCompress.length,
    );
  }

  /// Wrap the raw chat log markdown in the meta-prompt the LLM
  /// sees at wire-format layer. Tells the model the previous
  /// turns were pruned, points it at the log block, and invites
  /// it to continue from the most recent user message.
  static String _renderChatLogForModel(String chatLogMarkdown) {
    return '''
The following is an automated activity log of earlier turns in this session.
Each line shows a user's request, the assistant's tool calls (with intent),
and a one-line result summary. Full tool outputs are not retained; re-invoke
tools when you need the actual content. Continue the conversation based on
the most recent user message below this log.

<compacted-session-log>
$chatLogMarkdown
</compacted-session-log>
''';
  }

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
    // LLM-summary compaction has been retired in favour of
    // [createChatLogCompaction], which inserts a compaction
    // marker in the SAME session rather than spawning a child.
    // This stub remains so callers that still reference the old
    // API surface fail loudly with a clear migration message
    // instead of silently doing nothing.
    throw StateError(
      'compactIntoChildSession is no longer supported. '
      'Use createChatLogCompaction (in-place chat-log compaction) instead.',
    );
  }

  /// Shared projection used by both [createChatLogCompaction]
  /// (which actually inserts the compaction message and updates
  /// session state) and [estimateChatLogCompaction] (which only
  /// wants the pre/post token numbers for the hint label).
  ///
  /// Returns `null` when there's nothing to compact. The
  /// returned struct carries the rendered chat log + the
  /// resolved `toCompress` slice so the caller can either
  /// insert it as a message (real compact) or just read the
  /// token counts (estimate).
  _CompactionPreview? _buildCompactionPreview({
    required Session session,
    required List<Message> history,
    required List<Map<String, dynamic>> toolDefs,
    required ResolvedChatTarget? resolved,
    required String? incomingUserContent,
    required ToolRegistry toolRegistry,
  }) {
    // "Replace from scratch" model: each new compact builds a
    // fresh chat log from the full non-compaction history. The
    // prior `compaction`-role messages are no longer needed —
    // their content is going to be folded into the new one (and
    // physically deleted by `createChatLogCompaction` before the
    // new one is inserted). The `toCompress` slice is therefore
    // EVERY non-compaction message in the session, not just the
    // tail since the last compact.
    //
    // The wire layer's "skip messages before the latest
    // compaction" rule still applies — but in the new model there
    // is only ever one compaction per session at a time (the
    // previous ones are deleted), so the rule collapses to
    // "skip everything before the single live compaction".
    final toCompress = <Message>[];
    for (final m in history) {
      if (m.role == 'compaction') continue;
      toCompress.add(m);
    }
    if (toCompress.isEmpty) return null;

    // Pre-tokens: the CURRENT context size — exactly what the
    // context bar shows. Using `session.contextTokens` (the
    // SSoT, derived from the LLM's last `tokensIn` plus the
    // visible response) makes the hover label's pre side
    // agree with the bar value to the token. The previous
    // per-message sum over `toCompress` was wrong: it
    // disagreed with the bar by tens of thousands of tokens
    // because (a) it counted per-message content estimates
    // instead of cumulative prompt tokens, and (b) it
    // excluded the OLD compaction's contribution to the
    // current prompt. The user reading `155,342` on the bar
    // and `140k → 20k` on hover saw two different numbers
    // and asked which is right — both should be the same.
    final preTokens = session.contextTokens > 0
        ? session.contextTokens
        : currentContextTokens(
            messages: history,
            systemPrompt: resolved?.systemPrompt ?? session.systemPrompt,
            toolDefs: toolDefs,
          );

    // Build the chat log via the live tool registry — each tool's
    // own [ToolDef.renderPruneInline] / [extractPruneSummary]
    // decide how to render. The summary section's read-files cap
    // ([kInlineSummarySectionMaxChars]) keeps the post-compact
    // size bounded regardless of how many files the session
    // touched.
    final logResult = buildChatLog(
      messages: toCompress,
      workingDirectory: session.projectPath,
      toolRegistry: toolRegistry,
    );

    // In the new model, no chain accumulation: prior compactions
    // are about to be physically deleted, so the new chat log
    // IS the entire chat log — there's nothing to fold in. The
    // `wrapped` value is just the rendered markdown wrapped in
    // the `<compacted-session-log>` meta-prompt envelope.
    final wrapped = _renderChatLogForModel(logResult.markdown);

    // Post-tokens: the size of the NEXT prompt if we compact
    // now — system + new chat log + tools + the user's typed
    // (but unsent) message. The OLD compaction is gone from
    // the wire format (it's now "before" the latest compaction
    // and is skipped), and the post-compact tail has been
    // folded into the new chat log — so neither contributes
    // to the post side. This becomes the session's new
    // [contextTokens] so the next-turn projection is honest
    // about the post-compaction size.
    final postEstimateTokens =
        estimateTokens(wrapped) +
        estimateTokens(resolved?.systemPrompt ?? session.systemPrompt ?? '') +
        estimateToolDefsTokens(toolDefs) +
        (incomingUserContent != null && incomingUserContent.isNotEmpty
            ? estimateTokens(incomingUserContent)
            : 0);

    return _CompactionPreview(
      toCompress: toCompress,
      wrapped: wrapped,
      fileMarkers: logResult.fileMarkers,
      preTokens: preTokens,
      postEstimateTokens: postEstimateTokens,
    );
  }

  /// Run a single chat turn for [sessionId].
  ///
  /// [userContent] is the new user prompt for this turn. Pass `null`
  /// to skip the user-message persist and re-submit the existing
  /// history as-is — used by `/continue` when the conversation
  /// already ends on a role that the LLM API will accept as a
  /// trailing turn (a `tool` result, or a `user` message that's
  /// already a valid final turn). When `null`, no new user message
  /// is appended; the LLM is called with the wire-format history
  /// as it stands. When non-null, the user turn is persisted and
  /// the LLM is called with the new message appended.
  Future<void> sendMessage({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required FutureOr<void> Function(ChatResponse response) onComplete,
    required void Function(String error) onError,
    void Function(String status)? onStatus,
    FutureOr<void> Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    void Function(List<ToolCallData> toolCalls)? onToolExecutionStart,
    void Function(StreamingGuardAbortEvent event)? onStreamingGuardAbort,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
    List<ImageAttachment> images = const [],
  }) async {
    try {
      await _sendMessageUnsafe(
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
    } on SessionLeaseClaimException catch (e) {
      runtime.pauseStreamingTimer();
      runtime.isResponding = false;
      runtime.roundStreaming = false;
      runtime.roundStartTime = null;
      runtime.roundFirstTokenTime = null;
      _markSessionInactive(sessionId);
      onError(e.toString());
    } catch (e) {
      await _recoverFromUnexpectedTurnExit(
        sessionId: sessionId,
        session: session,
        runtime: runtime,
      );
      onError('Unhandled chat service error: $e');
    }
  }

  Future<void> _recoverFromUnexpectedTurnExit({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
  }) async {
    runtime.pauseStreamingTimer();
    runtime.isResponding = false;
    runtime.roundStreaming = false;
    runtime.roundStartTime = null;
    runtime.roundFirstTokenTime = null;
    _markSessionInactive(sessionId);
    _cancelRequested.remove(sessionId);

    if (session.status == SessionStatus.running) {
      session.status = SessionStatus.idle;
      session.updatedAt = DateTime.now();
      try {
        final updated = await _store.update(
          sessionId,
          status: SessionStatus.idle,
        );
        session.status = updated.status;
        session.updatedAt = updated.updatedAt;
      } catch (_) {
        // Keep the in-memory SSoT sane even if persistence fails while
        // unwinding an unexpected provider/tool/storage exception.
      }
    }
  }

  Future<void> _sendMessageUnsafe({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required FutureOr<void> Function(ChatResponse response) onComplete,
    required void Function(String error) onError,
    void Function(String status)? onStatus,
    FutureOr<void> Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    void Function(List<ToolCallData> toolCalls)? onToolExecutionStart,
    void Function(StreamingGuardAbortEvent event)? onStreamingGuardAbort,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
    List<ImageAttachment> images = const [],
  }) async {
    final updatedSession = await _store.update(
      sessionId,
      status: SessionStatus.running,
    );
    session.status = updatedSession.status;
    session.runningOwnerId = updatedSession.runningOwnerId;
    session.runningHeartbeatAt = updatedSession.runningHeartbeatAt;
    session.updatedAt = updatedSession.updatedAt;

    if (userContent != null) {
      await _messageStore.addMessage(
        sessionId,
        role: 'user',
        content: userContent,
        images: images,
      );
    }

    runtime.isResponding = true;
    runtime.tokPerSec = 0.0;
    runtime.tokCount = 0.0;

    _markSessionActive(sessionId);

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
    final modelConfig = provider?.modelById(modelId);

    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await _store.update(sessionId, status: SessionStatus.needUserAction);
      session.status = SessionStatus.needUserAction;
      runtime.isResponding = false;
      _markSessionInactive(sessionId);
      onError(
        'No API key for provider "$providerName". Use /provider to connect.',
      );
      return;
    }

    // --- Resolve the system prompt ---
    // Read from the session row if present; otherwise build fresh
    // and persist. The cached form is byte-identical across turns
    // in the same session, so the Anthropic provider's
    // `cache_control: ephemeral` marker on the system message
    // hits on every subsequent turn.
    //
    // On a model switch, the caller (the /model handler, not yet
    // implemented) is responsible for clearing `session.systemPrompt`
    // and calling `rebuildSystemPrompt` — the new build will
    // include the new provider/model's tuning text, which changes
    // the cache key and busts the prefix as required.
    String? systemPrompt = session.systemPrompt;
    if (systemPrompt == null || systemPrompt.isEmpty) {
      if (modelConfig == null) {
        // The model id from the session row doesn't match any
        // known model in the provider's TOML. This usually means
        // the user removed the model from their config mid-
        // session, or the session was created against a model
        // that's no longer registered. Skip the system prompt
        // entirely; the LLM call itself will likely fail later
        // with a model-not-found error, which the chat panel
        // surfaces.
        systemPrompt = null;
      } else {
        systemPrompt = buildSystemPrompt(
          provider: provider,
          model: modelConfig,
          cwd: session.projectPath,
          worktree: session.projectPath,
          sessionStarted: session.createdAt,
        );
        session.systemPrompt = systemPrompt;
        await _store.update(sessionId, systemPrompt: systemPrompt);
      }
    }

    final history = await _messageStore.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = buildApiMessages(
      history,
      wireFamily,
      systemPrompt: systemPrompt,
    );
    final toolDefs = _toolExecutor.getApiToolDefinitions();

    // Per-round text/reasoning accumulators, hoisted out of the agentic
    // loop so the post-loop persist (just below the `while (true)`)
    // can read the final round's content. Inside the loop, these are
    // cleared at the end of every tool round (both Anthropic and
    // OpenAI branches), so by the time we break out of the loop they
    // hold exactly the last round's text/reasoning — the "final
    // answer" content. This avoids the prior bug where an accumulating
    // buffer concatenated every round into the final `ai` row, which
    // caused earlier rounds' text to appear twice in the next request
    // (once in their own `tool_call` assistant message, once in the
    // concatenated `ai` message) — wasting tokens and invalidating
    // the server-side prompt-cache (KV) prefix on every turn.
    final roundTextBuffer = StringBuffer();
    final roundReasoningBuffer = StringBuffer();
    final roundReasoningSignatureBuffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    // Per-round thinking metrics. Reset at the top of each loop
    // iteration so every tool_call message gets its own thinking
    // duration and token count rather than inheriting stale values
    // from a prior round.
    int roundReasoningTokens = 0;
    double roundThinkingDurationMs = 0;
    DateTime? roundFirstContentTime;
    DateTime? roundFirstDeltaTime;
    DateTime? roundFirstReasoningTime;
    DateTime? roundLastReasoningTime;
    DateTime? roundLastDeltaTime;

    var firstTokenEver = true;

    void stopActiveRound({bool accumulate = false}) {
      if (accumulate &&
          runtime.roundStreaming &&
          runtime.roundFirstTokenTime != null) {
        runtime.cumulativeGenMs +=
            DateTime.now()
                .difference(runtime.roundFirstTokenTime!)
                .inMicroseconds /
            1000.0;
      }
      runtime.roundStreaming = false;
      runtime.roundStartTime = null;
      runtime.roundFirstTokenTime = null;
    }

    // Resolve the per-turn round-trip cap from provider/model TOML config.
    // Precedence: model-level max_rounds → provider default_max_rounds
    // → null (unbounded, the default). When set, the agentic loop bails
    // out after that many model→tool→model round-trips and surfaces a
    // soft "step limit reached" signal to the UI.
    final maxRounds = provider.effectiveMaxRoundsFor(modelConfig!);
    var stepCount = 0;
    var stepLimitReached = false;

    while (true) {
      if (maxRounds != null) {
        stepCount++;
        if (stepCount > maxRounds) {
          stepLimitReached = true;
          break;
        }
      }

      if (_cancelRequested.contains(sessionId)) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _markSessionInactive(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      runtime.startStreamingTimer();
      // Mark this LLM request round as active immediately. tok/s should
      // include the model's thinking/TTFT, response streaming, and tool-call
      // generation time, then pause again while local tools execute.
      runtime.roundStartTime = DateTime.now();
      runtime.roundStreaming = true;
      runtime.roundFirstTokenTime = null;

      // Reset per-round thinking metrics so every tool_call message
      // gets its own duration and token count.
      roundReasoningTokens = 0;
      roundReasoningSignatureBuffer.clear();
      roundThinkingDurationMs = 0;
      roundFirstContentTime = null;
      roundFirstDeltaTime = null;
      roundFirstReasoningTime = null;
      roundLastReasoningTime = null;
      roundLastDeltaTime = null;

      final streamCancelToken = LlmStreamCancelToken();
      final streamingGuard = _StreamingGuardAccumulator();
      _PendingStreamingGuardAbort? pendingGuardAbort;

      final stream = _llmClient.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: List<Map<String, dynamic>>.from(apiMessages),
        thinkingMode: runtime.thinkingMode,
        reasoningEffort: runtime.reasoningEffort,
        thinkingBudget: modelConfig.thinkingBudget,
        maxTokens: modelConfig.maxTokens,
        temperature: modelConfig.temperature,
        tools: toolDefs.isNotEmpty ? toolDefs : null,
        userId: '${InstallSlug.slug}-$sessionId',
        cancelToken: streamCancelToken,
      );

      final chunks = <LlmChunk>[];

      final useLerp = modelConfig.streamLerp;
      String lerpPendingText = '';
      String lerpPendingReasoning = '';
      SchedulerHandle? lerpTimer;
      var lerpStreamDone = false;
      Completer<void>? lerpDrainCompleter;

      // Per-frame emission budget for the lerp timer. Tracks
      // wall-clock excess over the 16 ms target — when a frame
      // is slow (say 20 ms), the 4 ms gap accumulates here; once
      // the accumulator hits another 16 ms, we have budget for
      // one extra character on the next frame. This keeps the
      // emission rate proportional to actual frame time, so a
      // 30 fps frame emits more characters than a 60 fps frame
      // (preserving the user-perceived streaming rate even
      // during sustained slowdowns).
      //
      // Spec: "at least 1 character per frame, expecting 16ms.
      // If the delta is 20ms we have a 4ms gap; if 4 frames
      // each take 20ms we accumulate a 16ms gap, and on that
      // frame the minimum to spit is 2 characters."
      const double lerpBaselineMs = 16.0;
      double lerpAccumulatedBudgetMs = 0.0;

      try {
        void ensureLerpTimer() {
          if (lerpTimer != null) return;
          lerpTimer = NoctermScheduler.instance.every(
            const Duration(milliseconds: 16),
            (tick) {
              FrameProfiler.instance.markTimer('lerp');
              // Stop emitting if the stream was cancelled.
              if (_cancelRequested.contains(sessionId)) {
                lerpTimer?.cancel();
                lerpTimer = null;
                if (lerpDrainCompleter != null &&
                    !lerpDrainCompleter.isCompleted) {
                  lerpDrainCompleter.complete();
                }
                return;
              }

              final totalPending =
                  lerpPendingText.length + lerpPendingReasoning.length;
              if (totalPending == 0) {
                if (lerpStreamDone &&
                    lerpDrainCompleter != null &&
                    !lerpDrainCompleter.isCompleted) {
                  lerpDrainCompleter.complete();
                }
                return;
              }

              // Delta-time aware budget: convert the wall-clock
              // tick delta to ms and accumulate the excess over
              // the 16 ms baseline. We only credit positive excess
              // — a faster-than-16ms frame doesn't carry debt
              // forward, it just doesn't earn extra credit. The
              // floor() gives us whole "16 ms slots" of credit;
              // each slot is one extra character beyond the
              // baseline. We never let the accumulator go below
              // zero.
              final deltaMs = tick.delta == Duration.zero
                  ? lerpBaselineMs
                  : tick.delta.inMicroseconds / 1000.0;
              if (deltaMs > lerpBaselineMs) {
                lerpAccumulatedBudgetMs += deltaMs - lerpBaselineMs;
              }
              final extraFromBudget =
                  (lerpAccumulatedBudgetMs / lerpBaselineMs).floor();
              lerpAccumulatedBudgetMs -= extraFromBudget * lerpBaselineMs;

              // The two emission-rate knobs from the original
              // implementation, kept for behavior parity:
              //   * `alpha` — the per-frame fraction of
              //     `totalPending` to emit (drains the queue
              //     smoothly during a flood).
              //   * `minCount` — the hard minimum per frame
              //     (1 while streaming, 2 once the stream is
              //     done and we're draining the tail).
              final alpha = lerpStreamDone ? 0.03 : 0.016;
              final baselineMin = lerpStreamDone ? 2 : 1;
              final floodCount = (totalPending * alpha).ceil();

              // Combine: at least `baselineMin + extraFromBudget`
              // characters, or the flood fraction of the queue,
              // whichever is larger. The + extraFromBudget is
              // the delta-time piece — the user-perceived rate
              // of the reasoning block tracks wall-clock even
              // when frames drift off 16 ms.
              final minCount = baselineMin + extraFromBudget;
              final count = (minCount > floodCount ? minCount : floodCount)
                  .clamp(1, totalPending);

              var remaining = count;

              if (lerpPendingText.isNotEmpty) {
                final take = remaining.clamp(0, lerpPendingText.length);
                if (take > 0) {
                  final emit = lerpPendingText.substring(0, take);
                  lerpPendingText = lerpPendingText.substring(take);
                  onDelta(emit);
                  remaining -= take;
                }
              }

              if (remaining > 0 && lerpPendingReasoning.isNotEmpty) {
                final take = remaining.clamp(0, lerpPendingReasoning.length);
                if (take > 0) {
                  final emit = lerpPendingReasoning.substring(0, take);
                  lerpPendingReasoning = lerpPendingReasoning.substring(take);
                  onReasoning(emit);
                }
              }

              onChunk();
            },
            name: 'streamLerp',
            owner: this,
            priority: SchedulePriority.animation,
          );
        }

        await for (final chunk in stream) {
          // Check if the caller requested a cancel. Without this,
          // the stream keeps consuming chunks until the LLM finishes
          // naturally, even after cancelStream() was called. Breaking
          // here lets the interrupt take effect on the very next chunk.
          if (_cancelRequested.contains(sessionId)) {
            lerpTimer?.cancel();
            break;
          }

          if (chunk.error != null) {
            lerpTimer?.cancel();
            runtime.pauseStreamingTimer();
            stopActiveRound();
            runtime.isResponding = false;
            await _store.update(sessionId, status: SessionStatus.idle);
            session.status = SessionStatus.idle;
            _markSessionInactive(sessionId);
            onError(chunk.error!);
            return;
          }

          if (chunk.guardAbort) {
            lerpTimer?.cancel();
            pendingGuardAbort ??= streamingGuard.pendingAbort;
            break;
          }

          chunks.add(chunk);

          if (chunk.reasoningSignatureDelta != null) {
            roundReasoningSignatureBuffer.write(chunk.reasoningSignatureDelta);
          }

          // First emitted delta of the current round (text, reasoning, or
          // tool_use). The LLM round itself was marked active before the
          // request so tok/s includes thinking/TTFT; this timestamp is kept
          // for TTFT and reasoning-duration boundaries.
          if (chunk.textDelta != null ||
              chunk.reasoningContent != null ||
              chunk.toolUse != null) {
            final now = DateTime.now();
            if (runtime.roundFirstTokenTime == null) {
              runtime.roundFirstTokenTime = now;
              roundFirstDeltaTime = now;
            }
            // Always track the last delta time so we can compute
            // reasoning duration from stream boundaries when the LLM
            // reports reasoningTokens but doesn't stream reasoning
            // content separately.
            roundLastDeltaTime = now;
            if (chunk.toolUse != null) {
              final toolUse = chunk.toolUse!;
              if (toolUse.inputDelta.isNotEmpty) {
                runtime.cumulativeCompletionTokens += estimateTokens(
                  toolUse.inputDelta,
                );
              }
              // Forward the raw delta to the chat panel so the live
              // streaming bubble can show a per-tool "ToolName (~Nt)"
              // row that materializes as the JSON arguments stream
              // in. The chat panel folds this into
              // [StreamingController] state and re-renders.
              onToolUse?.call(toolUse);
              final guardAbort = await streamingGuard.accumulateAndCheck(
                toolUse,
                toolExecutor: _toolExecutor,
                workingDirectory: session.projectPath,
              );
              if (guardAbort != null) {
                pendingGuardAbort = guardAbort;
                onStreamingGuardAbort?.call(
                  StreamingGuardAbortEvent(
                    index: guardAbort.index,
                    callId: guardAbort.callId,
                    name: guardAbort.name,
                    filePath: guardAbort.filePath,
                    reason: guardAbort.guard.reason ?? 'guard',
                    abortedInputTokensEstimate:
                        guardAbort.abortedInputTokensEstimate,
                  ),
                );
                await streamCancelToken.cancelActiveStream(
                  reason: guardAbort.guard.reason ?? 'guard',
                  guardAbort: true,
                );
                lerpTimer?.cancel();
                break;
              }
            }
            if (firstTokenEver &&
                (chunk.textDelta != null || chunk.reasoningContent != null)) {
              final now = DateTime.now();
              final elapsed =
                  now.difference(runtime.responseStartTime!).inMicroseconds /
                  1000.0;
              runtime.ttftMs = elapsed;
              runtime.ttftReceived = true;
              // Stash the wall-clock time of the first delta so the
              // tok/s display can measure generation rate from this
              // point on, excluding the TTFT wait. Without this, the
              // tok/s denominator is inflated by the time spent
              // waiting for the model to start emitting — significant
              // for thinking-mode providers (MiniMax, etc.) where
              // TTFT includes a long thinking preamble.
              runtime.firstTokenTime = now;
              firstTokenEver = false;
            }
            if (chunk.textDelta != null) {
              roundTextBuffer.write(chunk.textDelta);
              // Track when the first content (non-reasoning) delta
              // arrives in this round — used as the reasoning-end
              // boundary in the fallback duration calculation when
              // the LLM reports reasoningTokens but doesn't stream
              // reasoning content separately.
              roundFirstContentTime ??= now;
              if (useLerp) {
                lerpPendingText += chunk.textDelta!;
                ensureLerpTimer();
              } else {
                onDelta(chunk.textDelta!);
              }
            }
            if (chunk.reasoningContent != null) {
              roundReasoningBuffer.write(chunk.reasoningContent);
              // Track the first and last reasoning delta timestamps so
              // we can compute the actual reasoning stream duration.
              // This works even when the LLM doesn't report a
              // thinking_duration field — we measure wall-clock time
              // from first reasoning token to last reasoning token.
              roundFirstReasoningTime ??= now;
              roundLastReasoningTime = now;
              if (useLerp) {
                lerpPendingReasoning += chunk.reasoningContent!;
                ensureLerpTimer();
              } else {
                onReasoning(chunk.reasoningContent!);
              }
            }
            if ((!useLerp &&
                    (chunk.textDelta != null ||
                        chunk.reasoningContent != null)) ||
                chunk.toolUse != null) {
              // Repaint trigger for the chat panel. Text/reasoning
              // deltas are gated on `!useLerp` because the lerp
              // timer's 60fps tick is the repaint source in that
              // mode (see `ensureLerpTimer`). Tool-use deltas always
              // fire immediately so the in-progress tool call row
              // appears in the live bubble the moment the LLM
              // starts streaming one — the lerp timer is not
              // running at that point (no pending text).
              onChunk();
            }
          }

          if (chunk.promptTokens != null) {
            promptTokens = chunk.promptTokens!;
          }
          if (chunk.completionTokens != null) {
            completionTokens = chunk.completionTokens!;
          }
          if (chunk.promptCacheHitTokens != null) {
            promptCacheHitTokens = chunk.promptCacheHitTokens!;
          }
          if (chunk.promptCacheMissTokens != null) {
            promptCacheMissTokens = chunk.promptCacheMissTokens!;
          }
          if (chunk.reasoningTokens != null) {
            reasoningTokens = chunk.reasoningTokens!;
          }
        }
      } catch (e) {
        lerpTimer?.cancel();
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _markSessionInactive(sessionId);
        onError(e.toString());
        return;
      }

      // If the stream was cancelled mid-chunk, exit the agentic loop
      // immediately — don't process partial chunks, execute tools, or
      // call onComplete. The caller (_interruptResponse in ChatPanel)
      // has already handled cleanup.
      if (_cancelRequested.contains(sessionId)) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _markSessionInactive(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      lerpStreamDone = true;

      // Round stream finished. Fold this round's wall-clock generation
      // time into the per-turn cumulative total and clear the
      // round-streaming flag so the metrics timer pauses while tools
      // execute and while we wait for the next LLM response. Done
      // BEFORE the lerp drain so the denominator reflects only the
      // LLM's actual generation time, not the visual lerp animation
      // (up to 10s of post-stream UI smoothing).
      final roundTextReasoningTokens = estimateTokens(
        roundTextBuffer.toString() + roundReasoningBuffer.toString(),
      );
      if (roundTextReasoningTokens > 0) {
        runtime.cumulativeCompletionTokens += roundTextReasoningTokens;
      }
      stopActiveRound(accumulate: true);

      // Compute per-round thinking duration from the wall-clock time
      // between the first and last reasoning tokens in the stream.
      // This works even when the LLM doesn't report a duration field —
      // we measure it directly from when reasoning deltas arrive.
      //
      // Three cases:
      // 1. Reasoning content was streamed: use first→last reasoning
      //    delta timestamps for an accurate measurement.
      // 2. No reasoning content streamed, but reasoningTokens > 0:
      //    the LLM did think but didn't stream the reasoning (e.g.
      //    some OpenAI-compatible providers). Fall back to the
      //    wall-clock time from the first delta to either the first
      //    content delta or the last delta of the round.
      // 3. No reasoning at all: duration stays 0.
      if (roundFirstReasoningTime != null && roundLastReasoningTime != null) {
        // Case 1: we saw reasoning content in the stream.
        roundThinkingDurationMs =
            roundLastReasoningTime
                .difference(roundFirstReasoningTime)
                .inMicroseconds /
            1000.0;
      } else if (reasoningTokens > 0 && roundFirstDeltaTime != null) {
        // Case 2: the LLM reports reasoning tokens but didn't stream
        // reasoning content. Use stream boundaries as an approximation:
        // from the first delta of any kind to either the first content
        // delta (if there is one) or the last delta of the round.
        final reasoningEnd =
            roundFirstContentTime ?? roundLastDeltaTime ?? DateTime.now();
        roundThinkingDurationMs =
            reasoningEnd.difference(roundFirstDeltaTime).inMicroseconds /
            1000.0;
      }
      // Capture per-round reasoning tokens before the final round
      // overwrites the cumulative value.
      roundReasoningTokens = reasoningTokens;

      if (lerpTimer != null) {
        if (lerpPendingText.isEmpty && lerpPendingReasoning.isEmpty) {
          lerpTimer?.cancel();
          lerpTimer = null;
        } else {
          lerpDrainCompleter = Completer<void>();
          await lerpDrainCompleter.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          lerpTimer?.cancel();
          lerpTimer = null;
        }
      }

      runtime.pauseStreamingTimer();

      final precomputedCallResults = <String, ToolResult>{};
      final List<ToolCall> toolCalls;
      final guardAbort = pendingGuardAbort;
      if (guardAbort != null) {
        toolCalls = _completeToolCallsBeforeIndex(chunks, guardAbort.index);
        final stubCall = ToolCall(
          callId: guardAbort.callId,
          name: guardAbort.name,
          input: {
            '_aborted_by_guard': guardAbort.guard.reason ?? 'guard',
            'filePath': guardAbort.filePath,
          },
        );
        toolCalls.add(stubCall);
        precomputedCallResults[stubCall.callId] = _buildGuardAbortedToolResult(
          guardAbort,
        );
      } else {
        final finishReason = ToolExecutor.parseFinishReason(chunks);

        if (finishReason != 'tool_use') break;

        // Check for cancel before executing tools — the user may have
        // interrupted after the LLM finished streaming but before tools
        // started executing.
        if (_cancelRequested.contains(sessionId)) {
          runtime.pauseStreamingTimer();
          stopActiveRound();
          runtime.isResponding = false;
          await _store.update(sessionId, status: SessionStatus.idle);
          session.status = SessionStatus.idle;
          _markSessionInactive(sessionId);
          _cancelRequested.remove(sessionId);
          return;
        }

        toolCalls = ToolExecutor.parseToolUseFromChunks(chunks);
      }
      if (toolCalls.isEmpty) break;

      final roundText = roundTextBuffer.toString();
      final roundReasoning = roundReasoningBuffer.toString();
      final roundReasoningSignature = roundReasoningSignatureBuffer.toString();

      // Compute `hintEnabled` once at the top of the round so the
      // same value gates both in-context hint signals (praise on
      // rounds with ≥2 calls, single-call reminder on rounds with
      // 1 call once the threshold is reached) and the user-facing
      // bubble (persisted to the DB right after `addToolRound`).
      // Computing it twice would be a bug magnet if the resolver
      // ever grew side effects (caching, telemetry).
      //
      // `llmProviderByName` returns null only if the provider name
      // has no registered LLM (a misconfigured user TOML). In that
      // pathological case we fall back to the same default the
      // `LlmProvider` base class uses — `true` — so hints still
      // fire; the user will hit a more obvious error elsewhere
      // (the LLM call itself will fail).
      final llm = _providerService.llmProviderByName(providerName);
      final hintEnabled = llm == null
          ? true
          : llm.effectiveHintParallelCallsFor(
              modelOverride: modelConfig.hintParallelCalls,
              providerOverride: provider.hintParallelCalls,
            );
      // Threshold for the single-call hint. Same precedence as
      // `hintEnabled` itself (model > provider > class default).
      // Used below to gate the reminder injection.
      final hintSingleThreshold = llm == null
          ? 10
          : llm.effectiveHintParallelCallsSingleThresholdFor(
              modelOverride: modelConfig.hintParallelCallsSingleThreshold,
              providerOverride: provider.hintParallelCallsSingleThreshold,
            );

      // Execute tools.
      final assistantMsg = _toolExecutor.formatAssistantToolCallsMessage(
        toolCalls,
        roundText,
        wireFamily,
        reasoningContent: roundReasoning,
        reasoningSignature: roundReasoningSignature,
      );
      apiMessages.add(assistantMsg);
      final executingToolCalls = [
        for (final call in toolCalls)
          if (!precomputedCallResults.containsKey(call.callId))
            ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
      ];
      if (executingToolCalls.isNotEmpty) {
        onToolExecutionStart?.call(executingToolCalls);
      }
      final callResults = <String, ToolResult>{...precomputedCallResults};
      var roundResultTokens = 0;
      // Hoisted so the post-persist `addMessage` for the user-facing
      // praise bubble (below) can re-check the count. Filled by the
      // parallel dispatch below.
      var successfulCalls = 0;
      try {
        final isAnthropic = wireFamily == WireFamily.anthropicCompatible;
        final content = isAnthropic ? <Map<String, dynamic>>[] : null;
        final abortSignalsByCallId = <String, AbortSignal>{};
        for (final call in toolCalls) {
          final abortSignal = AbortSignal(sessionId: sessionId);
          abortSignalsByCallId[call.callId] = abortSignal;
          onAbortSignal?.call(abortSignal);
        }

        final toolResultEntries = await Future.wait([
          for (final call in toolCalls)
            if (!precomputedCallResults.containsKey(call.callId))
              () async {
                final abortSignal = abortSignalsByCallId[call.callId]!;
                if (_cancelRequested.contains(sessionId)) {
                  abortSignal.abort();
                  return MapEntry(
                    call.callId,
                    ToolResult.error('Tool aborted'),
                  );
                }
                final ctx = ToolContext(
                  sessionId: sessionId,
                  messageId: -1,
                  abort: abortSignal,
                  callId: call.callId,
                  workingDirectory: session.projectPath,
                  // Pass the runtime so the shell tool can read/write
                  // the consecutive-shell-violations counter. Other
                  // tools ignore the field. Without this, the shell
                  // guard's detector would never see the streak and
                  // every violation would land at the mild tier — the
                  // firm/reject escalation that motivates the feature
                  // would never fire.
                  sessionRuntime: runtime,
                );
                final result = await _toolExecutor.executeTool(call, ctx);
                if (_shouldAbortParallelToolSiblings(result)) {
                  for (final sibling in abortSignalsByCallId.entries) {
                    if (sibling.key != call.callId) sibling.value.abort();
                  }
                }
                return MapEntry(call.callId, result);
              }(),
        ]);

        if (_cancelRequested.contains(sessionId)) {
          for (final signal in abortSignalsByCallId.values) {
            signal.abort();
          }
          runtime.pauseStreamingTimer();
          stopActiveRound();
          runtime.isResponding = false;
          await _store.update(sessionId, status: SessionStatus.idle);
          session.status = SessionStatus.idle;
          _markSessionInactive(sessionId);
          _cancelRequested.remove(sessionId);
          return;
        }

        for (final entry in toolResultEntries) {
          callResults[entry.key] = entry.value;
        }

        // ── code_search preference hint ──────────────────────────────
        // Append a one-shot nudge to the FIRST `grep` or `glob` tool
        // result in the session, teaching the LLM that `code_search`
        // (semantic search) is the preferred surface for conceptual
        // code-search questions. Different from the shell-tool fallback
        // guard's `code_search` verdict (which fires when the LLM uses
        // `rg | head` style bash pipelines) — this hint fires when the
        // LLM uses grep/glob DIRECTLY as a tool, regardless of bash.
        //
        // Only fires once per session. The flag is per-chat (in-memory,
        // resets on app restart) so a long chat sees the hint on its
        // very first grep/glob use, then never again. Mirrors the
        // existing single-call-hint / shell-guard pattern: the
        // injected text is bracketed with a `[Crux system note — …]`
        // marker so the LLM pattern-matches the intent.
        //
        // Hooked BEFORE the apiMessages-building loop so the appended
        // reminder flows into the LLM-facing tool_result block (and
        // into the persisted record via `_buildToolResultForPersist`,
        // which reads the same `result.output`). No separate user-
        // facing bubble row — the reminder is visible in the chat
        // history inside the tool's output, matching the shell-guard
        // append pattern.
        if (!runtime.hasShownCodeSearchHint ||
            nextCodeSearchHintThreshold(
              runtime.contextTargetTokens,
              runtime.codeSearchHintLastThreshold,
            ) !=
                null) {
          const hintTriggerTools = <String>{'grep', 'glob'};
          for (final call in toolCalls) {
            if (call.parseError != null) continue;
            final lower = call.name.toLowerCase();
            if (!hintTriggerTools.contains(lower)) continue;
            final result = callResults[call.callId];
            if (result == null) continue;
            if (result.title == 'Error') continue;
            if (result.metadata['guardTriggered'] == true) continue;

            // Construct a new ToolResult with the hint appended.
            // `ToolResult.output` is `final`, so we rebuild the
            // record rather than mutating in place. Same
            // truncated/outputPath/metadata as the original.
            callResults[call.callId] = ToolResult(
              title: result.title,
              output: result.output + renderCodeSearchHintEmbedded(),
              truncated: result.truncated,
              outputPath: result.outputPath,
              metadata: result.metadata,
            );
            // Update state: the initial one-shot flips
            // `hasShownCodeSearchHint`; threshold re-fires bump
            // `codeSearchHintLastThreshold` to the threshold that
            // just fired. Both transitions are mutually exclusive
            // per round — the one-shot fires only when the flag
            // is still false (no threshold to fire because the
            // context is well below the first threshold or the
            // one-shot hasn't fired yet but context already
            // crossed one). In that case the threshold helper
            // would also return a value, so we check the one-shot
            // first and prefer it.
            if (!runtime.hasShownCodeSearchHint) {
              runtime.hasShownCodeSearchHint = true;
            } else {
              final threshold = nextCodeSearchHintThreshold(
                runtime.contextTargetTokens,
                runtime.codeSearchHintLastThreshold,
              );
              if (threshold != null) {
                runtime.codeSearchHintLastThreshold = threshold;
              }
            }
            break; // only the first grep/glob in the round
          }
        }

        for (final call in toolCalls) {
          final result = callResults[call.callId]!;
          if (isAnthropic) {
            content!.add({
              'type': 'tool_result',
              'tool_use_id': call.callId,
              'content': result.output,
            });
          } else {
            apiMessages.add({
              'role': 'tool',
              'tool_call_id': call.callId,
              'content': result.output,
            });
          }
          roundResultTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: result.output,
          );
          // Tally a successful call (no parse error and the tool didn't
          // throw). Used after the loop to gate both the in-context
          // praise and the user-facing bubble.
          if (call.parseError == null &&
              result.title != 'Error' &&
              result.metadata['guardTriggered'] != true) {
            successfulCalls++;
          }
        }

        // ── Shell-tool fallback guard: streak maintenance ────────
        // The detector + state machine in `shell_base.dart` /
        // `shell_guard.dart` increments the consecutive-violations
        // counter on every detected fallback. Here we reset it
        // whenever a "proper" tool succeeded — any Tier 1 or Tier 2
        // tool (semantic_search / find_similar_code / webfetch /
        // websearch / read / write / edit / grep / glob). Resetting
        // here (after
        // the tool loop, when every result has landed) means the
        // streak is broken by ANY successful proper-tool call in
        // the round, even if it ran in parallel with a shell call.
        //
        // We use the same "successful" predicate as
        // `successfulCalls` (no parse error, not an Error title,
        // not a guard-triggered result) so a `read` that errored
        // out doesn't accidentally reset the streak.
        //
        // Reset BEFORE the in-context hint injection below so the
        // helper that persists the shell_guard bubble sees the
        // post-reset counter value (it would otherwise show a
        // stale "2nd" ordinal when the LLM just used read + bash
        // in the same round).
        const properToolsForShellGuardReset = <String>{
          // Tier 1 — semantic understanding.
          'semantic_search',
          'find_similar_code',
          'webfetch',
          'websearch',
          // Tier 2 — file operations.
          'read',
          'write',
          'edit',
          'grep',
          'glob',
        };
        var hadProperToolSuccess = false;
        for (final call in toolCalls) {
          if (call.parseError != null) continue;
          final lower = call.name.toLowerCase();
          if (!properToolsForShellGuardReset.contains(lower)) continue;
          final result = callResults[call.callId];
          if (result == null) continue;
          if (result.title == 'Error') continue;
          if (result.metadata['guardTriggered'] == true) continue;
          hadProperToolSuccess = true;
          break;
        }
        if (hadProperToolSuccess) {
          runtime.consecutiveShellViolations = 0;
        }

        // In-context hint injection. Two complementary signals, both gated
        // on `hintEnabled`:
        //
        //   1. **Praise** — fires when the round had ≥2 successful
        //      tool calls. Positive reinforcement so the model keeps
        //      batching independent calls in long sessions.
        //   2. **Single-call reminder** — fires when the round had
        //      exactly 1 successful tool call AND the
        //      session-scoped consecutive-single-call counter just
        //      crossed the configured threshold (default 10).
        //      Corrective nudge for the opposite drift: the model
        //      has regressed to one tool call per round.
        //
        // Both are appended to the last tool's `content` field
        // (rather than a separate `user` message or a sibling `text`
        // block). A new `user` message reads as a fresh human turn
        // (the LLM would think the user just spoke and pivot its
        // reply), and a sibling `text` block inside the
        // post-tool-round `user` message muddies "this turn is tool
        // results" with "the user is also saying X." By placing the
        // hint inside the last tool's content — wrapped in its own
        // marker tag — every `tool`/`tool_result` still
        // unambiguously says "this came from a tool", and the hint
        // is just a trailing system-tagged note in one of them.
        // Different markers (`…parallel-tool-call hint` vs
        // `…single-tool-call hint`) let the model pattern-match
        // which signal it's seeing.
        //
        // Both injections are pure helpers (see `praise_prompts.dart`,
        // which despite the file name hosts both signals' helpers) so
        // tests can drive them directly. The Anthropic `user`
        // message that wraps the tool_results must be pushed to
        // `apiMessages` *first* so the helper can find it as
        // `apiMessages.last`; for OpenAI the tool messages are
        // already in `apiMessages` from the for-loop above.
        //
        // Both hints are deliberately NOT persisted to the DB — they
        // shape this session's behaviour and are gone on resumption.
        // The user-facing `parallel_praise` and `single_call_reminder`
        // bubbles (persisted below) are separate artefacts: the
        // praise bubble is the positive signal made visible to the
        // user, and the reminder bubble is the corrective signal made
        // visible. They're persisted only when the in-context hint
        // also fires, so the chat history never claims a nudge that
        // didn't happen.

        // First: update the consecutive-single-call counter based
        // on this round. We use the round's *successful* call count
        // (the same value that gates the praise hint) so failed
        // calls don't pollute the drift signal — the model intended
        // to make N calls; whether they all returned successfully
        // is a different question. The per-round transitions are
        // documented on
        // [SessionRuntimeState.consecutiveSingleToolCallRounds].
        if (successfulCalls == 1) {
          runtime.consecutiveSingleToolCallRounds += 1;
        } else {
          // 0 calls (LLM replied with text) or ≥2 calls (model is
          // batching again) both end the drift streak.
          runtime.consecutiveSingleToolCallRounds = 0;
        }

        if (isAnthropic) {
          apiMessages.add({'role': 'user', 'content': content});
        }
        if (guardAbort == null && hintEnabled && successfulCalls >= 2) {
          injectParallelToolCallHintIntoLastTool(
            apiMessages,
            isAnthropic: isAnthropic,
            count: successfulCalls,
          );
        } else if (guardAbort == null &&
            hintEnabled &&
            successfulCalls == 1 &&
            runtime.consecutiveSingleToolCallRounds > 0 &&
            runtime.consecutiveSingleToolCallRounds % hintSingleThreshold ==
                0) {
          // Fire the reminder every `threshold` consecutive
          // single-tool-call rounds. The modulo gate means the
          // reminder is rhythmic rather than spammy — it doesn't
          // fire on every single-call round, only on the ones that
          // land on multiples of the threshold. The counter resets
          // to 0 once the model returns to ≥2 calls (above), so a
          // long stretch of single-call rounds produces reminders
          // at round 10, 20, 30, … until the streak breaks.
          //
          // `> 0` guards against a 0 threshold (TOML explicit
          // `hint_parallel_calls_single_threshold = 0`) — without
          // it, every single-call round would fire. The modulo
          // already collapses 0 to "always", but the `> 0` makes
          // the intent explicit and protects against the case
          // where the counter hasn't yet been incremented.
          // Wire-format split by severity (see `praise_prompts.dart`
          // for the rationale):
          //   * **mild / firm** (rounds < 3 * threshold) — append
          //     the hint inside the last tool's `content`, framed
          //     with a tier-specific marker. Same shape as the
          //     praise hint.
          //   * **urgent** (rounds >= 3 * threshold, i.e. 30+ with
          //     default threshold) — push a fresh `user`-role
          //     message after the tool results. The prior two tiers
          //     evidently did not change behaviour, so escalate to
          //     a placement the LLM cannot miss.
          final count = runtime.consecutiveSingleToolCallRounds;
          if (singleCallHintSeverityFor(
                count,
                threshold: hintSingleThreshold,
              ) ==
              SingleCallHintSeverity.urgent) {
            injectParallelSingleCallHintAsUserMessage(
              apiMessages,
              isAnthropic: isAnthropic,
              consecutiveCount: count,
              threshold: hintSingleThreshold,
            );
          } else {
            injectParallelSingleCallHintIntoLastTool(
              apiMessages,
              isAnthropic: isAnthropic,
              consecutiveCount: count,
              threshold: hintSingleThreshold,
            );
          }
        }
      } catch (e) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _markSessionInactive(sessionId);
        onError('Tool execution error: $e');
        return;
      }

      final toolCallData = toolCalls
          .map(
            (call) => ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
          )
          .toList();

      // ── Persist (tool_call + tool_results in one transaction) ──
      try {
        await _messageStore.addToolRound(
          sessionId,
          roundText: roundText,
          reasoningContent: roundReasoning,
          reasoningSignature: roundReasoningSignature,
          reasoningTokens: roundReasoningTokens,
          thinkingDurationMs:
              (roundReasoning.isNotEmpty || roundReasoningTokens > 0)
              ? roundThinkingDurationMs.round()
              : 0,
          reasoningEffort: runtime.thinkingMode == 'disabled'
              ? null
              : runtime.reasoningEffort ?? 'normal',
          toolCalls: toolCallData,
          results: [
            for (final call in toolCalls)
              _buildToolResultForPersist(
                call.callId,
                callResults[call.callId]!,
              ),
          ],
        );
        // Persist user-facing LSP-diagnostics bubbles right after
        // the tool_call row, one per file that had error-severity
        // diagnostics. Mirrors the parallel_praise pattern: inline
        // under the tool-call list, persisted, no in-context hint
        // (the LLM can call `read` on the file path the bubble
        // references to see the actual errors).
        //
        // The metadata lives on [ToolResult.metadata] under the
        // `lsp` key, set by `EditTool`/`WriteTool` after a
        // successful mutation. The chat service only sees the
        // serialized `output` going into the tool_result block of
        // the API request, but it has the full [ToolResult] in
        // [callResults] for the persist path.
        for (final call in toolCalls) {
          final result = callResults[call.callId];
          if (result == null) continue;
          final lsp = result.metadata['lsp'];
          if (lsp is! List || lsp.isEmpty) continue;
          // The bubble's count and the tool detail pane's count
          // must agree. `result.metadata['lsp']` carries the raw
          // list from the LSP server (any severity); the detail
          // pane filters to error-severity only via
          // [errorDiagnostics], so we apply the same filter
          // here. Crux only surfaces errors in the user-facing
          // UI — warnings / info / hint stay in the embedded
          // `<crux-lsp>` JSON for the model's own consumption.
          // If the file produced zero errors (e.g. only warnings)
          // there's nothing to bubble and we skip the row, which
          // also keeps the bubble from disagreeing with an empty
          // detail-pane section.
          final errors = errorDiagnostics(lsp.cast<LspDiagnostic>());
          if (errors.isEmpty) continue;
          final relPath = _relativeFilePathFromCall(call, session.projectPath);
          await _messageStore.addMessage(
            sessionId,
            role: 'lsp_diagnostics',
            content: relPath,
            parallelCount: errors.length,
          );
        }

        // Persist user-facing tool-guard bubbles (auto-read,
        // read-before-write, size-mismatch). Same idea: the
        // model's view is unchanged (the tool's `output` already
        // contains the explanation), but a small `⚠` bubble
        // makes the user aware of what happened without bloating
        // the tool_call row. The kind is encoded as the
        // `parallelCount` int; the file path goes in `content`.
        for (final call in toolCalls) {
          final result = callResults[call.callId];
          if (result == null) continue;
          final kind = _guardKindFromResult(result);
          if (kind == null) continue;
          final relPath = _relativeFilePathFromCall(call, session.projectPath);
          await _messageStore.addMessage(
            sessionId,
            role: 'tool_guard',
            content: relPath,
            parallelCount: kind.index,
          );
        }

        // Persist the user-facing `parallel_praise` bubble right after
        // the tool_call row, so the chat history renders it inline
        // under the matching tool-call list. Same `hintEnabled`
        // gate as the in-context praise hint so the two never
        // disagree.
        if (guardAbort == null && hintEnabled && successfulCalls >= 2) {
          await _messageStore.addMessage(
            sessionId,
            role: 'parallel_praise',
            content: renderParallelPraiseBubbleLabel(successfulCalls),
            parallelCount: successfulCalls,
          );
        }
        // Mirror of the praise block above for the single-call
        // reminder. Same `hintEnabled` gate AND the same modulo gate
        // as the in-context hint injection above so all three
        // surfaces (in-context hint, DB bubble, user-facing UI)
        // fire and stay silent together. `parallelCount` is reused
        // as the telemetry-int column for system-role bubbles — see
        // the dispatch in `message_bubble.dart` and the
        // `Message.parallelCount` docstring.
        if (guardAbort == null &&
            hintEnabled &&
            successfulCalls == 1 &&
            runtime.consecutiveSingleToolCallRounds > 0 &&
            runtime.consecutiveSingleToolCallRounds % hintSingleThreshold ==
                0) {
          await _messageStore.addMessage(
            sessionId,
            role: 'single_call_reminder',
            content: renderSingleCallReminderBubbleLabel(
              runtime.consecutiveSingleToolCallRounds,
              threshold: hintSingleThreshold,
            ),
            parallelCount: runtime.consecutiveSingleToolCallRounds,
          );
        }

        // ── Shell-tool fallback guard: user-facing bubble ─────────
        // For every tool call whose result carries the `shellGuard`
        // metadata key (set by ShellBase when the detector flagged
        // a violation at any severity), persist a `shell_guard`
        // bubble right after the tool_call row. Mirrors the
        // `parallel_praise` / `single_call_reminder` pattern: a
        // small visible affordance that fires for every
        // violation, so the user can scan chat history and see
        // exactly which rounds drifted toward bash+cat fallbacks.
        //
        // Same `hintEnabled` gate as the in-context hints above
        // so all three surfaces (in-context reminder, DB bubble,
        // user-facing UI) fire and stay silent together. The
        // severity / streak after the call comes from the result
        // metadata (the shell tool set it before returning), so
        // we don't re-derive it here.
        if (guardAbort == null && hintEnabled) {
          for (final call in toolCalls) {
            final result = callResults[call.callId];
            if (result == null) continue;
            if (result.metadata['shellGuard'] != true) continue;
            final kindName = result.metadata['shellGuardKind'] as String?;
            final severityName =
                result.metadata['shellGuardSeverity'] as String?;
            final streakAfter =
                result.metadata['shellGuardStreakAfter'] as int?;
            if (kindName == null ||
                severityName == null ||
                streakAfter == null) {
              continue;
            }
            // Re-parse the verdict fields through the same enum
            // values the shell tool used, then render via the
            // canonical helper in `shell_guard.dart` so the
            // bubble's `content` matches the in-context reminder.
            final kind = ShellGuardKind.values.firstWhere(
              (k) => k.name == kindName,
              orElse: () => ShellGuardKind.none,
            );
            final severity = ShellGuardSeverity.values.firstWhere(
              (s) => s.name == severityName,
              orElse: () => ShellGuardSeverity.none,
            );
            if (kind == ShellGuardKind.none ||
                severity == ShellGuardSeverity.none) {
              continue;
            }
            final verdict = ShellGuardVerdict(
              kind: kind,
              severity: severity,
              what: '',
              toolName: _shellGuardToolNameForKind(kind),
              example: '',
              command: '',
              streakAfter: streakAfter,
            );
            await _messageStore.addMessage(
              sessionId,
              role: 'shell_guard',
              content: renderShellGuardBubbleLabel(verdict),
              // Reuse `parallelCount` as the multi-purpose
              // telemetry-int column for system-role bubbles.
              // For `shell_guard` rows it carries the post-call
              // streak value (1, 2, 3+) so the bubble can pick
              // the right ordinal without re-parsing the label.
              parallelCount: streakAfter,
            );
          }
        }
      } catch (e) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _markSessionInactive(sessionId);
        onError('Persistence error: $e');
        return;
      }

      roundTextBuffer.clear();
      roundReasoningBuffer.clear();
      await onToolRound?.call(roundResultTokens);

      // After the tool round completes, check if the user queued
      // any messages while the agent was streaming. If so, inject
      // the drained content as a user message into both the API
      // message list and the store so the next LLM round sees it.
      final queuedContent = onQueueDrain?.call();
      if (queuedContent != null) {
        await _messageStore.addMessage(
          sessionId,
          role: 'user',
          content: queuedContent,
        );
        apiMessages.add({'role': 'user', 'content': queuedContent});
      }
    }

    final content = roundTextBuffer.toString();
    final reasoningContent = roundReasoningBuffer.toString();
    final reasoningSignature = roundReasoningSignatureBuffer.toString();

    final thinkingMs = (reasoningContent.isNotEmpty || reasoningTokens > 0)
        ? roundThinkingDurationMs.round()
        : 0;

    await _messageStore.addMessage(
      sessionId,
      role: 'ai',
      content: content,
      reasoningContent: reasoningContent,
      reasoningSignature: reasoningSignature,
      reasoningTokens: reasoningTokens,
      thinkingDurationMs: thinkingMs,
      reasoningEffort: runtime.thinkingMode == 'disabled'
          ? null
          : runtime.reasoningEffort ?? 'normal',
      model: compositeKey,
      tokensIn: promptTokens,
      tokensOut: completionTokens,
    );

    await _store.update(
      sessionId,
      status: SessionStatus.done,
      tokensIn: session.tokensIn + promptTokens,
      tokensOut: session.tokensOut + completionTokens,
      // Don't overwrite `contextTokens` with 0 when the AI turn didn't
      // report any tokens (network error / user ESC / stream
      // interrupted). Falling back to 0 makes the next auto-compact
      // check use the buggy fallback path (which double-counts per-
      // message cumulative `tokensIn`), and the UI's `computeBaseContext`
      // fallback would inflate the displayed context by adding tool
      // results that the prior `contextTokens` already covered. Keep
      // the previous value instead — `repairStaleContextTokens` will
      // reconstruct it from the last AI message on the next launch.
      contextTokens: promptTokens > 0
          ? promptTokens + completionTokens - reasoningTokens
          : session.contextTokens,
      ttftMs: session.ttftMs > 0 ? session.ttftMs : runtime.ttftMs,
      tokPerSec: runtime.tokPerSec,
      promptCacheHitTokens: session.promptCacheHitTokens + promptCacheHitTokens,
    );

    session.status = SessionStatus.done;
    session.tokensIn += promptTokens;
    session.tokensOut += completionTokens;
    session.contextTokens = promptTokens + completionTokens - reasoningTokens;
    if (session.ttftMs <= 0 && runtime.ttftMs > 0) {
      session.ttftMs = runtime.ttftMs;
    }
    session.tokPerSec = runtime.tokPerSec;
    session.promptCacheHitTokens += promptCacheHitTokens;
    session.updatedAt = DateTime.now();

    runtime.isResponding = false;
    _markSessionInactive(sessionId);
    _cancelRequested.remove(sessionId);

    if (stepLimitReached) {
      // Soft signal to the user (toast in the UI) that the agent loop
      // stopped because of the per-turn step cap (configured in the
      // provider's TOML: `default_max_rounds` or per-model `max_rounds`).
      // The session is left in `done` state with whatever text + tool
      // history was generated up to this point, so the user can read
      // it and send another message to continue. This is not an error
      // — it's a safety brake configured by the provider.
      onError(
        'Step limit reached ($maxRounds tool rounds). '
        'Send another message to continue.',
      );
    }

    // After the final response, drain any remaining queued messages.
    // The caller's onComplete handler can use this to start a new
    // turn if the queue had messages.
    final finalQueuedContent = onQueueDrain?.call();

    await onComplete(
      ChatResponse(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        promptCacheHitTokens: promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens,
        queuedMessage: finalQueuedContent,
      ),
    );
  }

  static List<Map<String, dynamic>> buildApiMessages(
    List<Message> history,
    WireFamily wireFamily, {
    String? systemPrompt,
  }) {
    final result = <Map<String, dynamic>>[];

    // Prepend the system prompt. The Anthropic provider converts
    // this single `role: 'system'` message to a single text block
    // with `cache_control: ephemeral`, so the cache prefix is
    // stable across turns within a session. The OpenAI-compatible
    // path treats it as a regular message in the conversation.
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      result.add({'role': 'system', 'content': systemPrompt});
    }

    // In-place compaction: messages BEFORE the latest complete
    // compaction message are stale context the LLM doesn't need —
    // the latest compaction message itself summarises them. In
    // the "replace from scratch" model, there's only ever ONE
    // `compaction`-role message in the session (the previous
    // ones are physically deleted by
    // [createChatLogCompaction] before the new one is inserted),
    // so the wire layer sees exactly one compaction block. We
    // emit it as a single `user` role with the
    // `_renderCompactionSummaryForModel` header. Prior live
    // messages before the compaction are skipped; messages
    // after it form the live tail.
    var lastCompactionIdx = -1;
    for (var i = 0; i < history.length; i++) {
      if (history[i].role == 'compaction' &&
          _isCompleteCompactionMessage(history[i])) {
        lastCompactionIdx = i;
      }
    }

    for (var i = 0; i < history.length; i++) {
      final m = history[i];

      // Skip stale messages before the latest compaction, INCLUDING
      // older compaction messages — see comment above.
      if (lastCompactionIdx >= 0 && i < lastCompactionIdx) {
        continue;
      }

      switch (m.role) {
        case 'user':
          if (m.images.isNotEmpty) {
            // Multi-modal user message with images.
            final content = <Map<String, dynamic>>[];
            for (final img in m.images) {
              if (wireFamily == WireFamily.anthropicCompatible) {
                content.add({
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': img.mediaType,
                    'data': img.base64Data,
                  },
                });
              } else {
                content.add({
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:${img.mediaType};base64,${img.base64Data}',
                  },
                });
              }
            }
            if (m.content.isNotEmpty) {
              content.add({'type': 'text', 'text': m.content});
            }
            result.add({'role': 'user', 'content': content});
          } else {
            result.add({'role': 'user', 'content': m.content});
          }
        case 'compaction':
          if (_isCompleteCompactionMessage(m)) {
            result.add({
              'role': 'user',
              'content': _renderCompactionSummaryForModel(m.content),
            });
          }
        case 'system':
          result.add({'role': 'system', 'content': m.content});
        case 'ai':
          if (wireFamily == WireFamily.anthropicCompatible &&
              m.reasoningContent.isNotEmpty &&
              m.reasoningSignature.isNotEmpty) {
            result.add({
              'role': 'assistant',
              'content': [
                {
                  'type': 'thinking',
                  'thinking': m.reasoningContent,
                  'signature': m.reasoningSignature,
                },
                if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
              ],
            });
          } else {
            result.add({
              'role': 'assistant',
              'content': m.content.isEmpty ? null : m.content,
            });
          }
        case 'tool_call':
          if (wireFamily == WireFamily.anthropicCompatible) {
            final content = <Map<String, dynamic>>[];
            if (m.reasoningContent.isNotEmpty &&
                m.reasoningSignature.isNotEmpty) {
              content.add({
                'type': 'thinking',
                'thinking': m.reasoningContent,
                'signature': m.reasoningSignature,
              });
            }
            if (m.content.isNotEmpty) {
              content.add({'type': 'text', 'text': m.content});
            }
            for (final call in m.toolCalls) {
              content.add({
                'type': 'tool_use',
                'id': call.callId,
                'name': call.name,
                'input': call.input,
              });
            }
            result.add({'role': 'assistant', 'content': content});
          } else {
            final toolCalls = m.toolCalls
                .map(
                  (call) => {
                    'id': call.callId,
                    'type': 'function',
                    'function': {
                      'name': call.name,
                      'arguments': jsonEncode(call.input),
                    },
                  },
                )
                .toList();
            result.add({
              'role': 'assistant',
              'content': m.content.isNotEmpty ? m.content : null,
              'tool_calls': toolCalls,
            });
          }
        case 'tool':
          if (wireFamily == WireFamily.anthropicCompatible) {
            final last = result.isNotEmpty ? result.last : null;
            final toolResult = {
              'type': 'tool_result',
              'tool_use_id': m.toolCallId,
              'content': m.content,
            };
            if (last != null &&
                last['role'] == 'user' &&
                last['content'] is List) {
              (last['content'] as List<dynamic>).add(toolResult);
            } else {
              result.add({
                'role': 'user',
                'content': [toolResult],
              });
            }
          } else {
            result.add({
              'role': 'tool',
              'tool_call_id': m.toolCallId,
              'content': m.content,
            });
          }
      }
    }

    return result;
  }

  Future<ResolvedChatTarget?> _resolveChatTarget(Session session) async {
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
    final modelConfig = provider?.modelById(modelId);
    if (provider == null ||
        apiKey == null ||
        apiKey.isEmpty ||
        modelConfig == null) {
      return null;
    }

    String? systemPrompt = session.systemPrompt;
    if (systemPrompt == null || systemPrompt.isEmpty) {
      systemPrompt = buildSystemPrompt(
        provider: provider,
        model: modelConfig,
        cwd: session.projectPath,
        worktree: session.projectPath,
        sessionStarted: session.createdAt,
      );
      session.systemPrompt = systemPrompt;
      await _store.update(session.id, systemPrompt: systemPrompt);
    }

    return ResolvedChatTarget(
      providerName: providerName,
      modelId: modelId,
      provider: provider,
      apiKey: apiKey,
      modelConfig: modelConfig,
      systemPrompt: systemPrompt,
    );
  }

  /// Compute the next-turn projected prompt size in tokens.
  ///
  /// Thin wrapper around [currentContextTokens] (the SSoT) —
  /// all callers go through here. When the session has a
  /// cached `contextTokens` (i.e. at least one successful AI
  /// turn), use it as a fast path; otherwise fall through to
  /// the SSoT which handles both the no-AI fallback (content
  /// estimate + system + tools) and the AI-exists path
  /// (last AI's cumulative `tokensIn` + visible response).
  static int estimateProjectedContextTokens({
    required Session session,
    required String? systemPrompt,
    required List<Message> history,
    required String? incomingUserContent,
    required List<Map<String, dynamic>> toolDefs,
  }) {
    if (session.contextTokens > 0) {
      return session.contextTokens +
          (incomingUserContent != null && incomingUserContent.isNotEmpty
              ? estimateTokens(incomingUserContent)
              : 0);
    }
    return currentContextTokens(
      messages: history,
      systemPrompt: systemPrompt,
      toolDefs: toolDefs,
      incomingUserContent: incomingUserContent,
    );
  }

  /// Compute the reserve and threshold for auto-compaction.
///
/// Reserve is a flat 10k tokens — the headroom the chat-log
/// compaction pass itself leaves for the next turn's user
/// message and the LLM's response (with a small safety
/// margin). The reserve used to be 40k (a 20k summary output
/// budget + 20k for the incoming turn) under the old
/// LLM-summary child-session path. The chat-log compaction
/// doesn't need an LLM call — the chat log is a deterministic
/// transformation of history and lands in a few hundred to a
/// few thousand tokens. Carrying the 20k summary budget forward
/// was over-allocating the threshold headroom, which made the
/// auto-compact fire earlier than it needed to (a 200k-context
/// model compacted at 160k, leaving 40k of headroom mostly
/// unused). 10k is enough for the next turn + safety margin.
///
/// Intentionally constant across models; per-model reserve
/// tuning is a separate design question.
///
/// Threshold = `contextSize - reserve`. Auto-compact fires when
/// projectedTokens > threshold.
  static ({int reserve, int threshold}) computeCompactionReserveAndThreshold({
    required int contextSize,
  }) {
    const reserve = 10000;
    final threshold = contextSize - reserve;
    return (reserve: reserve, threshold: threshold);
  }

  // ─── Context size SSoT ───────────────────────────────────────
  //
  // Every place that wants to know "how big is the prompt the
  // LLM will see for this set of messages" should call
  // [currentContextTokens]. The old code had at least three
  // independent ways of computing the same number (this class's
  // [estimateProjectedContextTokens], [SessionController.computeBaseContext],
  // and the buggy per-message helper that summed `tokensIn +
  // tokensOut` across every AI turn — each `tokensIn` is
  // already cumulative, so summing gives N × final_prompt,
  // which inflated the pre-compact estimate to 2-3× the bar
  // value and looked like nonsense to the user ("475k → 8k"
  // when the bar said 226k).
  //
  // [currentContextTokens] is the single source of truth: walk
  // backwards to the last AI message with reported `tokensIn`,
  // use that one value (already cumulative for everything up
  // to and including itself), then add the visible response
  // and any messages after it. Fall back to per-message
  // content estimates when no AI has reported tokens yet.
  //
  // Includes system + tool defs implicitly (via `tokensIn`).
  // For the next-turn projection, callers can add
  // [incomingUserContent].

  /// Single source of truth: the size of the prompt the LLM
  /// will see for [messages] on the next turn, including
  /// system + tool defs (implicitly, via the last AI's
  /// `tokensIn`) and any [incomingUserContent] the user has
  /// typed but not yet sent.
  ///
  /// Algorithm (avoids the double-count trap from summing
  /// `tokensIn` across turns):
  /// 1. Walk backwards to find the last AI message with
  ///    non-zero `tokensIn`. Its `tokensIn` is the LLM's
  ///    reported prompt for the turn that produced it —
  ///    already cumulative for all messages up to and
  ///    including the user message that triggered it.
  /// 2. Add the visible response (`tokensOut - reasoning`).
  /// 3. Add the content cost of any messages after the last
  ///    AI (e.g. a user message the LLM hasn't seen yet — but
  ///    those are usually 0 in this SSoT; callers add them
  ///    via [incomingUserContent]).
  /// 4. Fallback (no AI has reported tokens — fresh session,
  ///    or every turn failed): sum content estimates of all
  ///    messages + system + tools + incoming.
  ///
  /// CRITICAL: do NOT sum `tokensIn` across multiple AI
  /// messages. Each turn's `tokensIn` is cumulative, so
  /// summing gives N × final_prompt — the classic double-
  /// count trap this function exists to prevent.
  static int currentContextTokens({
    required List<Message> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? toolDefs,
    String? incomingUserContent,
  }) {
    int lastAiIdx = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'ai' && m.tokensIn > 0) {
        lastAiIdx = i;
        break;
      }
    }
    if (lastAiIdx < 0) {
      // Fallback: no AI has reported tokens. Content-only
      // doesn't include system + tools, so add them.
      var total = estimateTokens(systemPrompt ?? '') +
          estimateToolDefsTokens(toolDefs ?? const []);
      for (final m in messages) {
        total += _contentOnlyMessageTokens(m);
      }
      if (incomingUserContent != null && incomingUserContent.isNotEmpty) {
        total += estimateTokens(incomingUserContent);
      }
      return total;
    }
    final lastAi = messages[lastAiIdx];
    final visibleResponse = (lastAi.tokensOut - lastAi.reasoningTokens)
        .clamp(0, 1 << 31);
    var total = lastAi.tokensIn + visibleResponse;
    for (var i = lastAiIdx + 1; i < messages.length; i++) {
      total += _contentOnlyMessageTokens(messages[i]);
    }
    if (incomingUserContent != null && incomingUserContent.isNotEmpty) {
      total += estimateTokens(incomingUserContent);
    }
    return total;
  }

  /// Content-only token estimate for a message. Never uses
  /// `tokensIn` / `tokensOut` — those are reserved for
  /// [currentContextTokens] which handles cumulative
  /// accounting correctly. Use this when you need a
  /// per-message estimate that won't double-count.
  static int _contentOnlyMessageTokens(Message m) {
    var total = estimateTokens(m.content);
    if (m.reasoningContent.isNotEmpty) {
      total += estimateTokens(m.reasoningContent);
    }
    for (final call in m.toolCalls) {
      total += estimateToolRoundTripTokens(
        toolName: call.name,
        args: call.input,
        resultOutput: '',
      );
    }
    return total;
  }

  /// Wrap a compaction message's content for the LLM. We only emit
  /// the LATEST compaction on the wire (see `buildApiMessages`),
  /// and its content already chains all prior compactions, so a
  /// single `## Compacted history` header is enough to mark the
  /// boundary between prior-session memory and live context. No
  /// XML wrapper, no "treat this as the only context" prose — the
  /// chat log itself uses `user:` / `crux:` formatting that's
  /// clearly distinguishable from a live exchange.
  static String _renderCompactionSummaryForModel(String summary) {
    return '## Compacted history (from earlier in this session)\n\n$summary';
  }

  static bool _isCompleteCompactionMessage(Message message) {
    if (message.meta.isEmpty) return true;
    try {
      final decoded = jsonDecode(message.meta);
      if (decoded is Map<String, dynamic>) {
        return (decoded['status'] as String? ?? 'complete') == 'complete';
      }
    } catch (_) {
      return true;
    }
    return true;
  }

  bool _envTruthy(String key) {
    final value = Platform.environment[key];
    if (value == null) return false;
    final normalized = value.trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  void dispose() {
    _cancelRequested.clear();
    for (final timer in _leaseHeartbeatTimers.values) {
      timer.cancel();
    }
    _leaseHeartbeatTimers.clear();
    _activeSessions.clear();
    _llmClient.dispose();
    _auxiliaryService.dispose();
  }
}

/// Compute a project-relative path for the file referenced by a tool
/// call, used by the LSP-diagnostics bubble. Best-effort: if the call
/// has no `filePath` arg, or the path doesn't live under the project
/// root, the absolute path is returned unchanged.
String _relativeFilePathFromCall(ToolCall call, String projectPath) {
  final raw = call.input['filePath'];
  if (raw is! String || raw.isEmpty) return '';
  final abs = p.isAbsolute(raw)
      ? p.normalize(raw)
      : p.normalize(p.join(projectPath, raw));
  final rel = p.relative(abs, from: projectPath);
  if (rel.startsWith('..') || p.isAbsolute(rel)) return abs;
  return rel;
}

/// Build a persist-ready record for a tool result. If the result
/// carries LSP diagnostics in its metadata, embed them as a
/// magic-marker JSON block in the persisted `output` so the
/// detail view can render a dedicated "LSP errors" section.
///
/// The visible text the model sees is unchanged; the marker is
/// appended after a blank line so a regex-based parser in the
/// detail view can extract it. The marker content is structured
/// JSON so the model can also use it directly to self-correct on
/// the next turn.
({String callId, String output, String meta}) _buildToolResultForPersist(
  String callId,
  ToolResult result,
) {
  // Pick the UI metadata we want to surface in the chat-history
  // bubble (and any future detail view). We only forward
  // well-known, agent-invisible keys here — anything else in
  // `result.metadata` is *not* persisted and is consumed only by
  // the LLM-API request path. See [Message.meta].
  String? meta;
  final routing = result.metadata['routing'];
  if (routing is String && routing.isNotEmpty) {
    meta = '{"routing":${_jsonString(routing)}}';
  }

  final lsp = result.metadata['lsp'];
  if (lsp is! List || lsp.isEmpty) {
    return (callId: callId, output: result.output, meta: meta ?? '');
  }
  final payload = buildLspPayload(lsp.cast());
  if (payload.isEmpty) {
    return (callId: callId, output: result.output, meta: meta ?? '');
  }
  return (callId: callId, output: '${result.output}$payload', meta: meta ?? '');
}

/// Minimal JSON string escaping — only the characters that show
/// up in our well-known meta values. Avoids pulling in a jsonEncode
/// dependency for a one-line literal.
String _jsonString(String s) {
  return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// Map a [ShellGuardKind] back to its dedicated-tool name. Mirrors
/// the private `_toolForKind` helper in `shell_guard.dart` — kept
/// here as a one-line switch so we don't have to plumb the
/// `toolName` field through the persisted metadata. Used by the
/// `shell_guard` bubble persistence block above to render the
/// "use `<tool>` instead" hint without rebuilding the verdict.
String _shellGuardToolNameForKind(ShellGuardKind kind) {
  switch (kind) {
    case ShellGuardKind.read:
      return 'read';
    case ShellGuardKind.glob:
      return 'glob';
    case ShellGuardKind.grep:
      return 'grep';
    case ShellGuardKind.codeSearch:
      return 'semantic_search';
    case ShellGuardKind.none:
      return '';
  }
}

/// Map a tool result's metadata into a [ToolGuardKind] for the
/// user-facing hint bubble. Returns null when no guard was
/// triggered (the common case). The kind is encoded as a
/// `parallelCount` int in the persisted `tool_guard` message.
ToolGuardKind? _guardKindFromResult(ToolResult result) {
  final meta = result.metadata;
  if (meta['guardAbortedMidStream'] == true) {
    return ToolGuardKind.streamingAbort;
  }
  if (meta['autoRead'] == true) {
    return ToolGuardKind.autoRead;
  }
  if (meta['guardTriggered'] == true) {
    switch (meta['guardKind']) {
      case 'size_mismatch':
        return ToolGuardKind.sizeMismatch;
      case 'read_before_write':
      default:
        // The plain `{'guardTriggered': true}` shape (no
        // guardKind) is the read-before-write guard set by the
        // write tool's `tracker.checkWriteGuard` path. Map it
        // here to keep the write tool's metadata schema simple.
        return ToolGuardKind.readBeforeWrite;
    }
  }
  return null;
}

/// Results that mean the current tool round should stop still-running
/// sibling tools as early as possible. This stays deliberately narrower
/// than "anything non-zero": shell commands often return useful non-zero
/// statuses during investigation, while guard-triggered writes and
/// executor-level errors mean continuing the round is likely wasteful
/// or unsafe.
bool _shouldAbortParallelToolSiblings(ToolResult result) {
  return result.title == 'Error' || result.metadata['guardTriggered'] == true;
}

const earlyAbortSystemNoteMarker = '[Crux system note — tool-call early abort]';

List<ToolCall> _completeToolCallsBeforeIndex(List<LlmChunk> chunks, int index) {
  final priorChunks = [
    for (final chunk in chunks)
      if (chunk.toolUse == null || chunk.toolUse!.index < index) chunk,
  ];
  return ToolExecutor.parseToolUseFromChunks(
    priorChunks,
  ).where((call) => call.parseError == null).toList();
}

ToolResult _buildGuardAbortedToolResult(_PendingStreamingGuardAbort pending) {
  final reason = pending.guard.reason ?? 'guard';
  return ToolResult(
    title: 'Tool call aborted by guard',
    output:
        '${pending.guard.header}\n\n'
        '${pending.guard.content}\n\n'
        '$earlyAbortSystemNoteMarker\n'
        'Crux stopped this ${pending.name} tool call while its arguments '
        'were still streaming. The tool was not executed. Reason: $reason. '
        'Aborted after ~${pending.abortedInputTokensEstimate} generated '
        'tool-argument tokens. '
        'Use the current file content above to retry with a valid tool call.',
    metadata: {
      'guardTriggered': true,
      'guardAbortedMidStream': true,
      'guardReason': reason,
      'tokensBeforeAbortEstimate': pending.abortedInputTokensEstimate,
    },
  );
}

class _PendingStreamingGuardAbort {
  final int index;
  final String callId;
  final String name;
  final String filePath;
  final GuardResult guard;

  /// Estimated token count of this tool call's `input_delta`
  /// chunks at the moment of abort. Counts only this tool call's
  /// own partial JSON — not the turn's text/reasoning and not
  /// sibling tool calls.
  final int abortedInputTokensEstimate;

  const _PendingStreamingGuardAbort({
    required this.index,
    required this.callId,
    required this.name,
    required this.filePath,
    required this.guard,
    required this.abortedInputTokensEstimate,
  });
}

class _StreamingToolAccum {
  String? callId;
  String? name;
  final input = StringBuffer();
  String? filePath;
  String? oldString;
  bool checkedWriteGuard = false;
  bool checkedEditGuard = false;
}

class _StreamingGuardAccumulator {
  final Map<int, _StreamingToolAccum> _byIndex = {};
  int _maxSeenIndex = -1;
  _PendingStreamingGuardAbort? pendingAbort;

  Future<_PendingStreamingGuardAbort?> accumulateAndCheck(
    ToolUseChunk chunk, {
    required ToolExecutor toolExecutor,
    required String workingDirectory,
  }) async {
    final acc = _byIndex.putIfAbsent(chunk.index, _StreamingToolAccum.new);
    if (chunk.callId.isNotEmpty) acc.callId = chunk.callId;
    if (chunk.name.isNotEmpty) acc.name = chunk.name;
    acc.input.write(chunk.inputDelta);
    if (chunk.index > _maxSeenIndex) _maxSeenIndex = chunk.index;

    final toolName = acc.name;
    if (toolName != 'write' && toolName != 'edit') return null;
    if (chunk.index != _maxSeenIndex) return null;

    final partial = acc.input.toString();
    acc.filePath ??= PartialJsonFieldExtractor.extractStringField(
      partial,
      'filePath',
    );
    final filePath = acc.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    if (toolName == 'write') {
      if (acc.checkedWriteGuard) return null;
      acc.checkedWriteGuard = true;
      final guard = await toolExecutor.checkWriteGuard(
        filePath: filePath,
        workingDirectory: workingDirectory,
      );
      if (guard == null) return null;
      return pendingAbort = _PendingStreamingGuardAbort(
        index: chunk.index,
        callId: acc.callId ?? '',
        name: toolName!,
        filePath: filePath,
        guard: guard,
        abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
      );
    }

    acc.oldString ??= PartialJsonFieldExtractor.extractStringField(
      partial,
      'oldString',
    );
    final oldString = acc.oldString;
    if (oldString == null || oldString.isEmpty) return null;
    if (acc.checkedEditGuard) return null;
    acc.checkedEditGuard = true;
    final guard = await toolExecutor.checkEditGuard(
      filePath: filePath,
      oldString: oldString,
      workingDirectory: workingDirectory,
    );
    if (guard == null) return null;
    return pendingAbort = _PendingStreamingGuardAbort(
      index: chunk.index,
      callId: acc.callId ?? '',
      name: toolName!,
      filePath: filePath,
      guard: guard,
      abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
    );
  }
}

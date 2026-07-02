import 'dart:convert';
import 'dart:io';

import '../models/chat_types.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../utils/token_estimate.dart';
import 'provider_service.dart';
import 'wire_format.dart';
import 'compaction/chat_log_builder.dart';
import 'compaction/summary_collector.dart';

/// Internal struct shared by [createChatLogCompaction] (which uses it
/// to insert the compaction message) and [estimateChatLogCompaction]
/// (which uses it only for the pre/post token counts).
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

/// In-place chat-log compaction engine.
///
/// Builds a deterministic activity-log summary of the messages after
/// the latest existing compaction (or all messages if none) and
/// inserts a single `role: 'compaction'` message into the SAME
/// session — no child session. The wire layer ([buildApiMessages])
/// then skips everything older than the latest compaction, so the
/// LLM only sees the post-compaction tail + the chat log.
///
/// Extracted from `chat_service.dart` so the compaction logic can be
/// tested and reasoned about independently of the agentic loop.
class CompactionService {
  final SessionStore _store;
  final ProviderService _providerService;

  CompactionService(this._store, this._providerService);

  /// In-place chat-log compaction. Returns `null` when there's
  /// nothing compressible or when compacting would grow the context.
  Future<ChatLogCompactionResult?> createChatLogCompaction({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required ToolRegistry toolRegistry,
    required CompactionReason reason,
  }) async {
    if (_envTruthy('CRUX_DISABLE_COMPACT')) return null;

    final history = await _store.messageStore.getMessages(sessionId);
    final toolDefs = toolRegistry.toApiTools();
    final resolved = await ResolvedChatTarget.resolve(
      session,
      _providerService,
      _store,
    );

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

    // Final gate: skip when compacting would grow the context.
    if (preview.postEstimateTokens > preview.preTokens) {
      return null;
    }

    // Replace prior compactions — delete the old ones BEFORE
    // inserting the new one so the chat history briefly has zero
    // compaction messages (never 2+).
    await _store.messageStore.deleteCompleteCompactions(sessionId);

    final compactionMessage = await _store.messageStore.addMessage(
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

  /// Project what an in-place chat-log compaction would produce,
  /// WITHOUT writing to the DB. Returns `null` when there's nothing
  /// to compact.
  Future<ChatLogCompactionEstimate?> estimateChatLogCompaction({
    required int sessionId,
    required Session session,
    required ToolRegistry toolRegistry,
    String? incomingUserContent,
  }) async {
    if (_envTruthy('CRUX_DISABLE_COMPACT')) return null;

    final history = await _store.messageStore.getMessages(sessionId);
    final toolDefs = toolRegistry.toApiTools();
    final resolved = await ResolvedChatTarget.resolve(
      session,
      _providerService,
      _store,
    );

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

  // ── Private ──────────────────────────────────────────────────────

  /// Shared projection used by both [createChatLogCompaction] and
  /// [estimateChatLogCompaction]. Returns `null` when there's
  /// nothing to compact.
  _CompactionPreview? _buildCompactionPreview({
    required Session session,
    required List<Message> history,
    required List<Map<String, dynamic>> toolDefs,
    required ResolvedChatTarget? resolved,
    required String? incomingUserContent,
    required ToolRegistry toolRegistry,
  }) {
    // "Replace from scratch" model: each new compact builds a fresh
    // chat log from the full non-compaction history.
    final toCompress = <Message>[];
    for (final m in history) {
      if (m.role == 'compaction') continue;
      toCompress.add(m);
    }
    if (toCompress.isEmpty) return null;

    // Pre-tokens: the CURRENT context size.
    final preTokens = session.contextTokens > 0
        ? session.contextTokens
        : currentContextTokens(
            messages: history,
            systemPrompt: resolved?.systemPrompt ?? session.systemPrompt,
            toolDefs: toolDefs,
          );

    // Build the chat log via the live tool registry.
    final logResult = buildChatLog(
      messages: toCompress,
      workingDirectory: session.projectPath,
      toolRegistry: toolRegistry,
    );

    final wrapped = _renderChatLogForModel(logResult.markdown);

    // Post-tokens: the size of the NEXT prompt if we compact now.
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

  /// Wrap the raw chat log markdown in the meta-prompt the LLM sees.
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

  static bool _envTruthy(String key) {
    final value = Platform.environment[key];
    if (value == null) return false;
    final normalized = value.trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }
}

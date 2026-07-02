/// Pure data types for the chat subsystem.
library;

import '../models/message.dart';
import '../models/session.dart';
import '../services/compaction/summary_collector.dart';

/// Token usage + optional queued-message returned at the end of a chat
/// turn. The caller uses [queuedMessage] to auto-kick off a new turn
/// when the user queued a message during streaming.
class ChatResponse {
  final int promptTokens;
  final int completionTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;

  /// If non-null, the user queued a message during streaming that
  /// should be sent as a new turn immediately after this response
  /// completes.
  final String? queuedMessage;

  const ChatResponse(
    this.promptTokens,
    this.completionTokens,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens, [
    this.queuedMessage,
  ]);
}

/// Why compaction fired — automatic (context pressure) or manual
/// (`/compact` or toolbar button).
enum CompactionReason { auto, manual }

/// Result of the deprecated LLM-summary + child-session compaction path.
/// Retained as a stub; the in-place chat-log path replaced it.
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

/// Result of in-place chat-log compaction — the compaction message
/// that was inserted, the file markers it summarised, and the
/// pre/post token counts.
class ChatLogCompactionResult {
  /// The newly inserted compaction message.
  final Message compactionMessage;

  /// Files that the chat log summarised via `read files:`.
  final List<FileReadMarker> fileMarkers;

  /// Projected token count before compaction.
  final int preTokens;

  /// Estimated token count after compaction.
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
/// what an in-place chat-log compaction WOULD produce, without writing
/// to the DB.
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

/// Event emitted when a tool call is aborted mid-stream by a guard
/// (e.g. read-before-write). The turn executor surfaces this to the
/// UI so the chat panel can show a "tool aborted" notice.
class StreamingGuardAbortEvent {
  final int index;
  final String callId;
  final String name;
  final String filePath;
  final String reason;

  /// Estimated tokens of the tool-call's partial JSON arguments
  /// that had streamed in by the moment we aborted.
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

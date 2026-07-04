import '../models/message.dart';
import '../tools/tool_def.dart';
import 'llm_client.dart';
import 'llm_error.dart';

sealed class ChatTurnEvent {
  final int sessionId;
  final int turnId;

  const ChatTurnEvent({required this.sessionId, required this.turnId});
}

final class ChatTurnDelta extends ChatTurnEvent {
  final String delta;

  const ChatTurnDelta({
    required super.sessionId,
    required super.turnId,
    required this.delta,
  });
}

final class ChatTurnReasoningDelta extends ChatTurnEvent {
  final String reasoning;

  const ChatTurnReasoningDelta({
    required super.sessionId,
    required super.turnId,
    required this.reasoning,
  });
}

final class ChatTurnChunk extends ChatTurnEvent {
  const ChatTurnChunk({required super.sessionId, required super.turnId});
}

final class ChatTurnStatusChanged extends ChatTurnEvent {
  final String status;

  const ChatTurnStatusChanged({
    required super.sessionId,
    required super.turnId,
    required this.status,
  });
}

final class ChatTurnToolRoundCompleted extends ChatTurnEvent {
  final int toolResultTokens;

  const ChatTurnToolRoundCompleted({
    required super.sessionId,
    required super.turnId,
    required this.toolResultTokens,
  });
}

final class ChatTurnToolUseDelta extends ChatTurnEvent {
  final ToolUseChunk chunk;

  const ChatTurnToolUseDelta({
    required super.sessionId,
    required super.turnId,
    required this.chunk,
  });
}

final class ChatTurnToolExecutionStarted extends ChatTurnEvent {
  final List<ToolCallData> toolCalls;

  const ChatTurnToolExecutionStarted({
    required super.sessionId,
    required super.turnId,
    required this.toolCalls,
  });
}

final class ChatTurnStreamingGuardAborted extends ChatTurnEvent {
  final int index;
  final String callId;
  final String name;
  final String filePath;
  final String reason;
  final int abortedInputTokensEstimate;

  const ChatTurnStreamingGuardAborted({
    required super.sessionId,
    required super.turnId,
    required this.index,
    required this.callId,
    required this.name,
    required this.filePath,
    required this.reason,
    required this.abortedInputTokensEstimate,
  });
}

final class ChatTurnAbortSignalRegistered extends ChatTurnEvent {
  final AbortSignal signal;

  const ChatTurnAbortSignalRegistered({
    required super.sessionId,
    required super.turnId,
    required this.signal,
  });
}

final class ChatTurnQueueDrainRequested extends ChatTurnEvent {
  const ChatTurnQueueDrainRequested({
    required super.sessionId,
    required super.turnId,
  });
}

final class ChatTurnCompleted extends ChatTurnEvent {
  final int promptTokens;
  final int completionTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;
  final String? queuedMessage;

  const ChatTurnCompleted({
    required super.sessionId,
    required super.turnId,
    required this.promptTokens,
    required this.completionTokens,
    required this.promptCacheHitTokens,
    required this.promptCacheMissTokens,
    this.queuedMessage,
  });
}

final class ChatTurnFailed extends ChatTurnEvent {
  final LlmError error;

  const ChatTurnFailed({
    required super.sessionId,
    required super.turnId,
    required this.error,
  });
}

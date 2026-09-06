import '../models/session_runtime_state.dart';
import 'llm_client.dart';

/// Returns whether [chunk] carries output emitted by the model.
///
/// Tool-use argument deltas are model output just like prose and reasoning
/// deltas. They must therefore establish the turn's first-output timestamp,
/// even when a round contains no user-visible text.
bool isModelOutputChunk(LlmChunk chunk) {
  return chunk.textDelta != null ||
      chunk.reasoningContent != null ||
      chunk.toolUse != null;
}

/// Records TTFT for the first output emitted during a response.
///
/// Returns `true` when this call captured the timestamp. The runtime ignores
/// subsequent output, keeping TTFT anchored to the first model event across
/// tool-execution follow-up rounds.
bool recordFirstModelOutput(
  SessionRuntimeState runtime,
  LlmChunk chunk, {
  DateTime? now,
}) {
  if (!isModelOutputChunk(chunk) || runtime.ttftReceived) return false;

  final timestamp = now ?? DateTime.now();
  runtime.recordFirstToken(timestamp);
  return runtime.ttftReceived;
}

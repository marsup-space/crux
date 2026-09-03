import 'package:bloc/bloc.dart';

import '../services/llm_client.dart';
import '../utils/token_estimate.dart';

/// Snapshot of an in-progress tool call as it streams in from the
/// LLM. The LLM emits `tool_use` chunks one at a time, each carrying
/// a delta of the input JSON. We accumulate the JSON per call index
/// so the streaming bubble can render a live preview without
/// requiring the full call to have arrived.
class StreamingToolCall {
  final String callId;
  final String name;
  final String accumulatedInputJson;
  final StreamingToolAbortInfo? abortInfo;

  const StreamingToolCall({
    required this.callId,
    required this.name,
    required this.accumulatedInputJson,
    this.abortInfo,
  });

  int get estimatedInputTokens => estimateTokens(accumulatedInputJson);

  StreamingToolCall copyWith({
    String? callId,
    String? name,
    String? accumulatedInputJson,
    StreamingToolAbortInfo? abortInfo,
  }) {
    return StreamingToolCall(
      callId: callId ?? this.callId,
      name: name ?? this.name,
      accumulatedInputJson: accumulatedInputJson ?? this.accumulatedInputJson,
      abortInfo: abortInfo ?? this.abortInfo,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StreamingToolCall &&
        other.callId == callId &&
        other.name == name &&
        other.accumulatedInputJson == accumulatedInputJson &&
        other.abortInfo == abortInfo;
  }

  @override
  int get hashCode =>
      Object.hash(callId, name, accumulatedInputJson, abortInfo);
}

class StreamingToolAbortInfo {
  final String reason;

  /// Estimated token count of this tool call's streamed
  /// `input_delta` at the moment the guard fired.
  final int abortedInputTokensEstimate;

  const StreamingToolAbortInfo({
    required this.reason,
    required this.abortedInputTokensEstimate,
  });

  @override
  bool operator ==(Object other) {
    return other is StreamingToolAbortInfo &&
        other.reason == reason &&
        other.abortedInputTokensEstimate == abortedInputTokensEstimate;
  }

  @override
  int get hashCode => Object.hash(reason, abortedInputTokensEstimate);
}

class ExecutingToolCall {
  final String callId;
  final String name;
  final String inputPreview;

  /// The tool call's `intent` argument (shell tools). Mirror of the
  /// controller-side field; part of ==/hashCode so a re-emit with a
  /// different intent still notifies listeners.
  final String intent;

  const ExecutingToolCall({
    required this.callId,
    required this.name,
    required this.inputPreview,
    this.intent = '',
  });

  @override
  bool operator ==(Object other) {
    return other is ExecutingToolCall &&
        other.callId == callId &&
        other.name == name &&
        other.inputPreview == inputPreview &&
        other.intent == intent;
  }

  @override
  int get hashCode => Object.hash(callId, name, inputPreview, intent);
}

class StreamingCubitState {
  StreamingCubitState({
    Map<int, String> streamingContent = const {},
    Map<int, String> streamingReasoning = const {},
    Map<int, DateTime> waitingForModelSince = const {},
    Map<int, DateTime> executingToolsSince = const {},
    Map<int, List<ExecutingToolCall>> executingToolCalls = const {},
    Map<int, Map<int, StreamingToolCall>> streamingToolCalls = const {},
    this.contextBarHovered = false,
  }) : streamingContent = Map.unmodifiable(streamingContent),
       streamingReasoning = Map.unmodifiable(streamingReasoning),
       waitingForModelSince = Map.unmodifiable(waitingForModelSince),
       executingToolsSince = Map.unmodifiable(executingToolsSince),
       executingToolCalls = _deepUnmodifiableListMap(executingToolCalls),
       streamingToolCalls = _deepUnmodifiableNestedMap(streamingToolCalls);

  final Map<int, String> streamingContent;
  final Map<int, String> streamingReasoning;
  final Map<int, DateTime> waitingForModelSince;
  final Map<int, DateTime> executingToolsSince;
  final Map<int, List<ExecutingToolCall>> executingToolCalls;
  final Map<int, Map<int, StreamingToolCall>> streamingToolCalls;
  final bool contextBarHovered;

  String streamingContentFor(int sessionId) =>
      streamingContent[sessionId] ?? '';

  String streamingReasoningFor(int sessionId) =>
      streamingReasoning[sessionId] ?? '';

  double? waitingForModelSeconds(int sessionId, {DateTime? now}) {
    final since = waitingForModelSince[sessionId];
    if (since == null) return null;
    return (now ?? DateTime.now()).difference(since).inMilliseconds / 1000.0;
  }

  double? executingToolsSeconds(int sessionId, {DateTime? now}) {
    final since = executingToolsSince[sessionId];
    if (since == null) return null;
    return (now ?? DateTime.now()).difference(since).inMilliseconds / 1000.0;
  }

  List<ExecutingToolCall> executingToolCallsFor(int sessionId) {
    return executingToolCalls[sessionId] ?? const <ExecutingToolCall>[];
  }

  List<StreamingToolCall> streamingToolCallsFor(int sessionId) {
    final perSession = streamingToolCalls[sessionId];
    if (perSession == null || perSession.isEmpty) {
      return const <StreamingToolCall>[];
    }
    final keys = perSession.keys.toList()..sort();
    return [for (final key in keys) perSession[key]!];
  }

  int streamingToolInputTokensFor(int sessionId) {
    final perSession = streamingToolCalls[sessionId];
    if (perSession == null || perSession.isEmpty) return 0;
    return perSession.values.fold<int>(
      0,
      (sum, call) => sum + call.estimatedInputTokens,
    );
  }

  bool hasLiveStreamingFor(int sessionId) {
    return (streamingContent[sessionId]?.isNotEmpty ?? false) ||
        (streamingReasoning[sessionId]?.isNotEmpty ?? false) ||
        (streamingToolCalls[sessionId]?.isNotEmpty ?? false) ||
        (executingToolCalls[sessionId]?.isNotEmpty ?? false);
  }

  bool hasStreamingToolAbort(int sessionId) {
    final perSession = streamingToolCalls[sessionId];
    if (perSession == null) return false;
    return perSession.values.any((call) => call.abortInfo != null);
  }

  StreamingCubitState copyWith({
    Map<int, String>? streamingContent,
    Map<int, String>? streamingReasoning,
    Map<int, DateTime>? waitingForModelSince,
    Map<int, DateTime>? executingToolsSince,
    Map<int, List<ExecutingToolCall>>? executingToolCalls,
    Map<int, Map<int, StreamingToolCall>>? streamingToolCalls,
    bool? contextBarHovered,
  }) {
    return StreamingCubitState(
      streamingContent: streamingContent ?? this.streamingContent,
      streamingReasoning: streamingReasoning ?? this.streamingReasoning,
      waitingForModelSince: waitingForModelSince ?? this.waitingForModelSince,
      executingToolsSince: executingToolsSince ?? this.executingToolsSince,
      executingToolCalls: executingToolCalls ?? this.executingToolCalls,
      streamingToolCalls: streamingToolCalls ?? this.streamingToolCalls,
      contextBarHovered: contextBarHovered ?? this.contextBarHovered,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StreamingCubitState &&
        _mapEquals(other.streamingContent, streamingContent) &&
        _mapEquals(other.streamingReasoning, streamingReasoning) &&
        _mapEquals(other.waitingForModelSince, waitingForModelSince) &&
        _mapEquals(other.executingToolsSince, executingToolsSince) &&
        _mapListEquals(other.executingToolCalls, executingToolCalls) &&
        _nestedMapEquals(other.streamingToolCalls, streamingToolCalls) &&
        other.contextBarHovered == contextBarHovered;
  }

  @override
  int get hashCode => Object.hash(
    _mapHash(streamingContent),
    _mapHash(streamingReasoning),
    _mapHash(waitingForModelSince),
    _mapHash(executingToolsSince),
    _mapListHash(executingToolCalls),
    _nestedMapHash(streamingToolCalls),
    contextBarHovered,
  );
}

class StreamingCubit extends Cubit<StreamingCubitState> {
  StreamingCubit({StreamingCubitState? initialState})
    : super(initialState ?? StreamingCubitState());

  void appendStreamingContent(int sessionId, String delta) {
    emit(
      state.copyWith(
        streamingContent: {
          ...state.streamingContent,
          sessionId: state.streamingContentFor(sessionId) + delta,
        },
        waitingForModelSince: _withoutKey(
          state.waitingForModelSince,
          sessionId,
        ),
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
      ),
    );
  }

  void appendStreamingReasoning(int sessionId, String delta) {
    emit(
      state.copyWith(
        streamingReasoning: {
          ...state.streamingReasoning,
          sessionId: state.streamingReasoningFor(sessionId) + delta,
        },
        waitingForModelSince: _withoutKey(
          state.waitingForModelSince,
          sessionId,
        ),
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
      ),
    );
  }

  void updateStreamingToolCall(int sessionId, ToolUseChunk chunk) {
    final perSession = Map<int, StreamingToolCall>.from(
      state.streamingToolCalls[sessionId] ?? const <int, StreamingToolCall>{},
    );
    final existing = perSession[chunk.index];
    perSession[chunk.index] = existing == null
        ? StreamingToolCall(
            callId: chunk.callId,
            name: chunk.name,
            accumulatedInputJson: chunk.inputDelta,
          )
        : existing.copyWith(
            callId: existing.callId.isEmpty ? chunk.callId : existing.callId,
            name: existing.name.isEmpty ? chunk.name : existing.name,
            accumulatedInputJson:
                existing.accumulatedInputJson + chunk.inputDelta,
          );

    emit(
      state.copyWith(
        streamingToolCalls: {
          ...state.streamingToolCalls,
          sessionId: perSession,
        },
        waitingForModelSince: _withoutKey(
          state.waitingForModelSince,
          sessionId,
        ),
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
      ),
    );
  }

  void beginWaitingForModel(int sessionId, {DateTime? now}) {
    emit(
      state.copyWith(
        streamingContent: _withoutKey(state.streamingContent, sessionId),
        streamingReasoning: _withoutKey(state.streamingReasoning, sessionId),
        streamingToolCalls: _withoutKey(state.streamingToolCalls, sessionId),
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
        waitingForModelSince: {
          ...state.waitingForModelSince,
          sessionId: now ?? DateTime.now(),
        },
      ),
    );
  }

  void beginExecutingTools(
    int sessionId,
    List<ExecutingToolCall> calls, {
    DateTime? now,
  }) {
    emit(
      state.copyWith(
        streamingContent: _withoutKey(state.streamingContent, sessionId),
        streamingReasoning: _withoutKey(state.streamingReasoning, sessionId),
        streamingToolCalls: _withoutKey(state.streamingToolCalls, sessionId),
        waitingForModelSince: _withoutKey(
          state.waitingForModelSince,
          sessionId,
        ),
        executingToolsSince: {
          ...state.executingToolsSince,
          sessionId: now ?? DateTime.now(),
        },
        executingToolCalls: {
          ...state.executingToolCalls,
          sessionId: List<ExecutingToolCall>.unmodifiable(calls),
        },
      ),
    );
  }

  void finishExecutingTools(int sessionId) {
    if (!state.executingToolsSince.containsKey(sessionId) &&
        !state.executingToolCalls.containsKey(sessionId)) {
      return;
    }
    emit(
      state.copyWith(
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
      ),
    );
  }

  void markStreamingToolCallAborted(
    int sessionId, {
    required int index,
    required String callId,
    required String name,
    required String reason,
    required int abortedInputTokensEstimate,
  }) {
    final perSession = Map<int, StreamingToolCall>.from(
      state.streamingToolCalls[sessionId] ?? const <int, StreamingToolCall>{},
    );
    final existing = perSession[index];
    final abortInfo = StreamingToolAbortInfo(
      reason: reason,
      abortedInputTokensEstimate: abortedInputTokensEstimate,
    );
    perSession[index] = existing == null
        ? StreamingToolCall(
            callId: callId,
            name: name,
            accumulatedInputJson: '',
            abortInfo: abortInfo,
          )
        : existing.copyWith(
            callId: existing.callId.isEmpty ? callId : existing.callId,
            name: existing.name.isEmpty ? name : existing.name,
            abortInfo: abortInfo,
          );

    emit(
      state.copyWith(
        streamingToolCalls: {
          ...state.streamingToolCalls,
          sessionId: perSession,
        },
      ),
    );
  }

  void clearStreamingFor(int sessionId) {
    emit(
      state.copyWith(
        streamingContent: _withoutKey(state.streamingContent, sessionId),
        streamingReasoning: _withoutKey(state.streamingReasoning, sessionId),
        streamingToolCalls: _withoutKey(state.streamingToolCalls, sessionId),
        waitingForModelSince: _withoutKey(
          state.waitingForModelSince,
          sessionId,
        ),
        executingToolsSince: _withoutKey(state.executingToolsSince, sessionId),
        executingToolCalls: _withoutKey(state.executingToolCalls, sessionId),
      ),
    );
  }

  void setContextBarHovered(bool hovered) {
    emit(state.copyWith(contextBarHovered: hovered));
  }
}

Map<int, List<T>> _deepUnmodifiableListMap<T>(Map<int, List<T>> source) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<T>.unmodifiable(entry.value),
  });
}

Map<int, Map<int, T>> _deepUnmodifiableNestedMap<T>(
  Map<int, Map<int, T>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: Map<int, T>.unmodifiable(entry.value),
  });
}

Map<K, V> _withoutKey<K, V>(Map<K, V> source, K key) {
  return Map<K, V>.from(source)..remove(key);
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapListEquals<K, V>(Map<K, List<V>> a, Map<K, List<V>> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || !_listEquals(entry.value, other)) return false;
  }
  return true;
}

bool _nestedMapEquals<K1, K2, V>(Map<K1, Map<K2, V>> a, Map<K1, Map<K2, V>> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.entries.every(
    (entry) => b[entry.key] != null && _mapEquals(entry.value, b[entry.key]!),
  );
}

int _mapHash<K, V>(Map<K, V> map) {
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

int _mapListHash<K, V>(Map<K, List<V>> map) {
  return Object.hashAllUnordered(
    map.entries.map(
      (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
    ),
  );
}

int _nestedMapHash<K1, K2, V>(Map<K1, Map<K2, V>> map) {
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, _mapHash(entry.value))),
  );
}

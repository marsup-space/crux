import 'package:bloc/bloc.dart';

enum CompactionPhase { idle, compacting, failed }

class CompactionSessionState {
  const CompactionSessionState({
    this.phase = CompactionPhase.idle,
    this.turnsSinceLastCompact = 0,
    this.consecutiveFailures = 0,
    this.lastPreTokens,
    this.lastPostEstimateTokens,
    this.lastError,
  });

  final CompactionPhase phase;
  final int turnsSinceLastCompact;
  final int consecutiveFailures;
  final int? lastPreTokens;
  final int? lastPostEstimateTokens;
  final String? lastError;

  bool get isCompacting => phase == CompactionPhase.compacting;

  CompactionSessionState copyWith({
    CompactionPhase? phase,
    int? turnsSinceLastCompact,
    int? consecutiveFailures,
    Object? lastPreTokens = _unset,
    Object? lastPostEstimateTokens = _unset,
    Object? lastError = _unset,
  }) {
    return CompactionSessionState(
      phase: phase ?? this.phase,
      turnsSinceLastCompact:
          turnsSinceLastCompact ?? this.turnsSinceLastCompact,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastPreTokens: identical(lastPreTokens, _unset)
          ? this.lastPreTokens
          : lastPreTokens as int?,
      lastPostEstimateTokens: identical(lastPostEstimateTokens, _unset)
          ? this.lastPostEstimateTokens
          : lastPostEstimateTokens as int?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompactionSessionState &&
        other.phase == phase &&
        other.turnsSinceLastCompact == turnsSinceLastCompact &&
        other.consecutiveFailures == consecutiveFailures &&
        other.lastPreTokens == lastPreTokens &&
        other.lastPostEstimateTokens == lastPostEstimateTokens &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    turnsSinceLastCompact,
    consecutiveFailures,
    lastPreTokens,
    lastPostEstimateTokens,
    lastError,
  );
}

class CompactionCubitState {
  CompactionCubitState({Map<int, CompactionSessionState> sessions = const {}})
    : sessions = Map.unmodifiable(sessions);

  final Map<int, CompactionSessionState> sessions;

  CompactionSessionState sessionState(int sessionId) {
    return sessions[sessionId] ?? const CompactionSessionState();
  }

  CompactionCubitState copyWith({Map<int, CompactionSessionState>? sessions}) {
    return CompactionCubitState(sessions: sessions ?? this.sessions);
  }

  @override
  bool operator ==(Object other) {
    return other is CompactionCubitState &&
        _mapEquals(other.sessions, sessions);
  }

  @override
  int get hashCode => _mapHash(sessions);
}

class CompactionCubit extends Cubit<CompactionCubitState> {
  CompactionCubit({CompactionCubitState? initialState})
    : super(initialState ?? CompactionCubitState());

  bool shouldSkipAutoCheck(int sessionId) {
    return state.sessionState(sessionId).turnsSinceLastCompact > 0;
  }

  void advanceHysteresis(int sessionId) {
    final current = state.sessionState(sessionId);
    var turns = current.turnsSinceLastCompact;
    if (turns > 0) {
      turns += 1;
      if (turns > 3) turns = 0;
    }
    _put(sessionId, current.copyWith(turnsSinceLastCompact: turns));
  }

  void markCheckSkippedBelowThreshold(int sessionId) {
    _put(
      sessionId,
      state.sessionState(sessionId).copyWith(turnsSinceLastCompact: 0),
    );
  }

  void beginCompaction(int sessionId) {
    _put(
      sessionId,
      state
          .sessionState(sessionId)
          .copyWith(phase: CompactionPhase.compacting, lastError: null),
    );
  }

  void markCompactionSucceeded({
    required int sessionId,
    required int preTokens,
    required int postEstimateTokens,
  }) {
    _put(
      sessionId,
      state
          .sessionState(sessionId)
          .copyWith(
            phase: CompactionPhase.idle,
            turnsSinceLastCompact: 1,
            consecutiveFailures: 0,
            lastPreTokens: preTokens,
            lastPostEstimateTokens: postEstimateTokens,
            lastError: null,
          ),
    );
  }

  void markCompactionFailed(int sessionId, String error) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        phase: CompactionPhase.failed,
        turnsSinceLastCompact: 1,
        consecutiveFailures: current.consecutiveFailures + 1,
        lastError: error,
      ),
    );
  }

  void resetHysteresis(int sessionId) {
    _put(
      sessionId,
      state
          .sessionState(sessionId)
          .copyWith(
            phase: CompactionPhase.idle,
            turnsSinceLastCompact: 0,
            lastError: null,
          ),
    );
  }

  void removeSession(int sessionId) {
    emit(state.copyWith(sessions: _withoutKey(state.sessions, sessionId)));
  }

  void _put(int sessionId, CompactionSessionState value) {
    emit(state.copyWith(sessions: {...state.sessions, sessionId: value}));
  }
}

const _unset = Object();

Map<K, V> _withoutKey<K, V>(Map<K, V> source, K key) {
  final next = Map<K, V>.from(source)..remove(key);
  return next;
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

int _mapHash<K, V>(Map<K, V> map) {
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

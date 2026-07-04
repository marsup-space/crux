import 'package:bloc/bloc.dart';

import 'turn_registry.dart';

enum ChatTurnPhase { idle, responding, failed, interrupted }

class ChatTurnSessionState {
  const ChatTurnSessionState({
    this.phase = ChatTurnPhase.idle,
    this.turnId,
    this.kind,
    this.responseStartTime,
    this.roundStartTime,
    this.roundStreaming = false,
    this.lastStatus,
    this.lastError,
    this.isGeneratingTldr = false,
  });

  final ChatTurnPhase phase;
  final int? turnId;
  final TurnKind? kind;
  final DateTime? responseStartTime;
  final DateTime? roundStartTime;
  final bool roundStreaming;
  final String? lastStatus;
  final String? lastError;
  final bool isGeneratingTldr;

  bool get isResponding => phase == ChatTurnPhase.responding;
  bool get interrupted => phase == ChatTurnPhase.interrupted;
  bool get btwMode => kind == TurnKind.btw && isResponding;

  ChatTurnSessionState copyWith({
    ChatTurnPhase? phase,
    Object? turnId = _unset,
    Object? kind = _unset,
    Object? responseStartTime = _unset,
    Object? roundStartTime = _unset,
    bool? roundStreaming,
    Object? lastStatus = _unset,
    Object? lastError = _unset,
    bool? isGeneratingTldr,
  }) {
    return ChatTurnSessionState(
      phase: phase ?? this.phase,
      turnId: identical(turnId, _unset) ? this.turnId : turnId as int?,
      kind: identical(kind, _unset) ? this.kind : kind as TurnKind?,
      responseStartTime: identical(responseStartTime, _unset)
          ? this.responseStartTime
          : responseStartTime as DateTime?,
      roundStartTime: identical(roundStartTime, _unset)
          ? this.roundStartTime
          : roundStartTime as DateTime?,
      roundStreaming: roundStreaming ?? this.roundStreaming,
      lastStatus: identical(lastStatus, _unset)
          ? this.lastStatus
          : lastStatus as String?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
      isGeneratingTldr: isGeneratingTldr ?? this.isGeneratingTldr,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChatTurnSessionState &&
        other.phase == phase &&
        other.turnId == turnId &&
        other.kind == kind &&
        other.responseStartTime == responseStartTime &&
        other.roundStartTime == roundStartTime &&
        other.roundStreaming == roundStreaming &&
        other.lastStatus == lastStatus &&
        other.lastError == lastError &&
        other.isGeneratingTldr == isGeneratingTldr;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    turnId,
    kind,
    responseStartTime,
    roundStartTime,
    roundStreaming,
    lastStatus,
    lastError,
    isGeneratingTldr,
  );
}

class ChatTurnCubitState {
  ChatTurnCubitState({Map<int, ChatTurnSessionState> sessions = const {}})
    : sessions = Map.unmodifiable(sessions);

  final Map<int, ChatTurnSessionState> sessions;

  ChatTurnSessionState sessionState(int sessionId) {
    return sessions[sessionId] ?? const ChatTurnSessionState();
  }

  bool isResponding(int sessionId) => sessionState(sessionId).isResponding;

  ChatTurnCubitState copyWith({Map<int, ChatTurnSessionState>? sessions}) {
    return ChatTurnCubitState(sessions: sessions ?? this.sessions);
  }

  @override
  bool operator ==(Object other) {
    return other is ChatTurnCubitState && _mapEquals(other.sessions, sessions);
  }

  @override
  int get hashCode => _mapHash(sessions);
}

class ChatTurnCubit extends Cubit<ChatTurnCubitState> {
  ChatTurnCubit({ChatTurnCubitState? initialState})
    : super(initialState ?? ChatTurnCubitState());

  void beginTurn({
    required int sessionId,
    required int turnId,
    required TurnKind kind,
    DateTime? now,
  }) {
    final startedAt = now ?? DateTime.now();
    _put(
      sessionId,
      ChatTurnSessionState(
        phase: ChatTurnPhase.responding,
        turnId: turnId,
        kind: kind,
        responseStartTime: startedAt,
      ),
    );
  }

  void beginModelRound(int sessionId, {DateTime? now}) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        roundStartTime: now ?? DateTime.now(),
        roundStreaming: true,
      ),
    );
  }

  void finishModelRound(int sessionId) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(roundStartTime: null, roundStreaming: false),
    );
  }

  void completeTurn(int sessionId, int turnId) {
    final current = state.sessionState(sessionId);
    if (current.turnId != turnId) return;
    _put(
      sessionId,
      current.copyWith(
        phase: ChatTurnPhase.idle,
        turnId: null,
        kind: null,
        responseStartTime: null,
        roundStartTime: null,
        roundStreaming: false,
        lastError: null,
      ),
    );
  }

  void failTurn(int sessionId, int turnId, String error) {
    final current = state.sessionState(sessionId);
    if (current.turnId != turnId) return;
    _put(
      sessionId,
      current.copyWith(
        phase: ChatTurnPhase.failed,
        turnId: null,
        kind: null,
        responseStartTime: null,
        roundStartTime: null,
        roundStreaming: false,
        lastError: error,
      ),
    );
  }

  void interruptTurn(int sessionId) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        phase: ChatTurnPhase.interrupted,
        turnId: null,
        kind: null,
        roundStartTime: null,
        roundStreaming: false,
      ),
    );
  }

  void setStatus(int sessionId, String? status) {
    _put(sessionId, state.sessionState(sessionId).copyWith(lastStatus: status));
  }

  void setGeneratingTldr(int sessionId, bool generating) {
    _put(
      sessionId,
      state.sessionState(sessionId).copyWith(isGeneratingTldr: generating),
    );
  }

  void removeSession(int sessionId) {
    emit(state.copyWith(sessions: _withoutKey(state.sessions, sessionId)));
  }

  void _put(int sessionId, ChatTurnSessionState value) {
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

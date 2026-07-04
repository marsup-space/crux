import '../tools/tool_def.dart';

enum TurnKind { normal, btw }

class TurnHandle {
  const TurnHandle({
    required this.sessionId,
    required this.turnId,
    required this.kind,
  });

  final int sessionId;
  final int turnId;
  final TurnKind kind;
}

class TurnRegistry {
  final Map<int, TurnHandle> _activeTurns = {};
  final Set<int> _interruptedSessions = {};
  final Map<int, List<AbortSignal>> _abortSignals = {};
  final Set<int> _btwCancelRequested = {};
  final Set<int> _streamingGuardAbortedSessions = {};

  TurnHandle beginNormalTurn(int sessionId, int turnId) {
    return _beginTurn(
      TurnHandle(sessionId: sessionId, turnId: turnId, kind: TurnKind.normal),
    );
  }

  TurnHandle beginBtwTurn(int sessionId, int turnId) {
    return _beginTurn(
      TurnHandle(sessionId: sessionId, turnId: turnId, kind: TurnKind.btw),
    );
  }

  TurnHandle _beginTurn(TurnHandle handle) {
    _activeTurns[handle.sessionId] = handle;
    _interruptedSessions.remove(handle.sessionId);
    _btwCancelRequested.remove(handle.sessionId);
    _streamingGuardAbortedSessions.remove(handle.sessionId);
    _abortSignals.remove(handle.sessionId);
    return handle;
  }

  TurnHandle? activeTurn(int sessionId) => _activeTurns[sessionId];

  bool isCurrent(int sessionId, int turnId) {
    final active = _activeTurns[sessionId];
    return active != null && active.turnId == turnId;
  }

  bool isInterrupted(int sessionId) => _interruptedSessions.contains(sessionId);

  void markInterrupted(int sessionId) {
    _interruptedSessions.add(sessionId);
  }

  bool consumeInterrupted(int sessionId) {
    return _interruptedSessions.remove(sessionId);
  }

  void finishTurn(int sessionId, int turnId) {
    if (!isCurrent(sessionId, turnId)) return;
    _activeTurns.remove(sessionId);
    _interruptedSessions.remove(sessionId);
    _abortSignals.remove(sessionId);
    _btwCancelRequested.remove(sessionId);
    _streamingGuardAbortedSessions.remove(sessionId);
  }

  void registerAbortSignal(int sessionId, AbortSignal signal) {
    _abortSignals.putIfAbsent(sessionId, () => <AbortSignal>[]).add(signal);
  }

  List<AbortSignal> takeAbortSignals(int sessionId) {
    return _abortSignals.remove(sessionId) ?? const <AbortSignal>[];
  }

  void clearAbortSignals(int sessionId) {
    _abortSignals.remove(sessionId);
  }

  void requestBtwCancel(int sessionId) {
    _btwCancelRequested.add(sessionId);
  }

  bool consumeBtwCancel(int sessionId) {
    return _btwCancelRequested.remove(sessionId);
  }

  void markStreamingGuardAborted(int sessionId) {
    _streamingGuardAbortedSessions.add(sessionId);
  }

  bool consumeStreamingGuardAborted(int sessionId) {
    return _streamingGuardAbortedSessions.remove(sessionId);
  }

  void clearSession(int sessionId) {
    _activeTurns.remove(sessionId);
    _interruptedSessions.remove(sessionId);
    _abortSignals.remove(sessionId);
    _btwCancelRequested.remove(sessionId);
    _streamingGuardAbortedSessions.remove(sessionId);
  }
}

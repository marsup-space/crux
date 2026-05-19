import 'dart:async';

class BusyError implements Exception {
  final int sessionId;
  BusyError(this.sessionId);

  @override
  String toString() => 'Session #$sessionId is busy';
}

class SessionLock {
  final Map<int, Completer<void>> _locks = {};

  Future<void> acquire(int sessionId) async {
    while (_locks.containsKey(sessionId)) {
      await _locks[sessionId]!.future;
    }
    final completer = Completer<void>();
    _locks[sessionId] = completer;
  }

  void release(int sessionId) {
    final completer = _locks.remove(sessionId);
    completer?.complete();
  }

  bool isBusy(int sessionId) => _locks.containsKey(sessionId);

  void releaseAll() {
    for (final completer in _locks.values) {
      completer.complete();
    }
    _locks.clear();
  }
}

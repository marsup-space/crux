import 'dart:async';

/// Manages session lease state: which sessions are actively streaming,
/// heartbeat timers for running sessions, and cancellation flags.
///
/// Extracted from `chat_service.dart` so the lease/heartbeat/cancel
/// state machine lives in its own file instead of being one of six
/// responsibilities on the god class.
class SessionLeaseManager {
  final Set<int> _activeSessions = {};
  final Set<int> _cancelRequested = {};
  final Map<int, Timer> _leaseHeartbeatTimers = {};

  static const Duration _leaseHeartbeatInterval = Duration(seconds: 5);

  /// True when [sessionId] is actively streaming (i.e. a turn is
  /// in progress and the session has been marked active).
  bool isStreaming(int sessionId) => _activeSessions.contains(sessionId);

  /// True when [cancelStream] has been called for [sessionId] but the
  /// turn hasn't yet noticed and cleaned up.
  bool isCancelRequested(int sessionId) =>
      _cancelRequested.contains(sessionId);

  /// Request that the stream for [sessionId] be cancelled. The turn
  /// executor checks this flag between chunks and bails out of the
  /// agentic loop when it sees the flag set.
  void cancelStream(int sessionId) {
    _cancelRequested.add(sessionId);
  }

  /// Mark [sessionId] as actively streaming and start the lease
  /// heartbeat timer. [heartbeat] is invoked immediately and then
  /// every 5s until [markSessionInactive] is called.
  void markSessionActive(
    int sessionId, {
    required Future<void> Function(int) heartbeat,
  }) {
    _activeSessions.add(sessionId);
    _startLeaseHeartbeat(sessionId, heartbeat);
  }

  /// Mark [sessionId] as no longer streaming and stop the heartbeat
  /// timer. Idempotent — calling when the session is already
  /// inactive is a no-op.
  void markSessionInactive(int sessionId) {
    _activeSessions.remove(sessionId);
    _stopLeaseHeartbeat(sessionId);
  }

  /// Clear the cancel-request flag for [sessionId]. Called by the
  /// turn executor after it has noticed the flag and bailed out of
  /// the agentic loop.
  void clearCancelRequest(int sessionId) {
    _cancelRequested.remove(sessionId);
  }

  /// Cancel all heartbeat timers and clear all state. Called by
  /// [ChatService.dispose].
  void dispose() {
    _cancelRequested.clear();
    for (final timer in _leaseHeartbeatTimers.values) {
      timer.cancel();
    }
    _leaseHeartbeatTimers.clear();
    _activeSessions.clear();
  }

  // ── Private ──────────────────────────────────────────────────────

  void _startLeaseHeartbeat(
    int sessionId,
    Future<void> Function(int) heartbeat,
  ) {
    _stopLeaseHeartbeat(sessionId);
    heartbeat(sessionId);
    _leaseHeartbeatTimers[sessionId] = Timer.periodic(
      _leaseHeartbeatInterval,
      (_) => heartbeat(sessionId),
    );
  }

  void _stopLeaseHeartbeat(int sessionId) {
    _leaseHeartbeatTimers.remove(sessionId)?.cancel();
  }
}

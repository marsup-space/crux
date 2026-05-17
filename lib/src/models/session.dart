import 'dart:async';
import 'message.dart';

enum SessionStatus {
  idle,
  running,
  needUserAction,
  done,
}

class Session {
  final int id;
  final String title;
  String model;
  SessionStatus status;
  final List<Message> messages;
  final DateTime createdAt;
  DateTime lastActivityAt;

  // Per-session context state
  int contextTargetTokens;
  double contextDisplayTokens;

  // Per-session response state
  bool isResponding;
  Timer? responseTimer;
  Timer? metricsTimer;
  double tokPerSec;
  double ttftMs;
  DateTime? responseStartTime;
  double tokCount;
  double mockTtftTargetMs;
  double mockTokRate;
  int mockResponseIndex;

  Session({
    required this.id,
    required this.title,
    this.model = '',
    this.contextTargetTokens = 50000,
    this.contextDisplayTokens = 50000.0,
    this.status = SessionStatus.idle,
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? lastActivityAt,
    this.isResponding = false,
    this.tokPerSec = 0.0,
    this.ttftMs = 0.0,
    this.tokCount = 0.0,
    this.mockTtftTargetMs = 0.0,
    this.mockTokRate = 0.0,
    this.mockResponseIndex = 0,
  })  : messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        lastActivityAt = lastActivityAt ?? DateTime.now();

  /// Display string for session ID, e.g. "#1"
  String get displayId => '#$id';

  @override
  String toString() {
    return 'Session($displayId: $title, status: $status, '
        'messages: ${messages.length}, responding: $isResponding)';
  }
}

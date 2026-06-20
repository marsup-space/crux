enum SessionStatus { idle, running, needUserAction, done, interrupted }

class Session {
  final int id;
  final String slug;
  String title;
  String model;
  SessionStatus status;
  final String agent;
  final int? parentId;
  final String projectPath;
  int tokensIn;
  int tokensOut;
  int contextTokens;
  double ttftMs;
  double tokPerSec;
  int promptCacheHitTokens;
  String thinkingMode;
  String? reasoningEffort;
  String? runningOwnerId;
  DateTime? runningHeartbeatAt;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? archivedAt;

  /// The rendered system prompt — the joined content of all four
  /// layers, ready to be sent as a single `role: 'system'` message.
  /// `null` for legacy sessions or for sessions whose system prompt
  /// has not yet been built. Set on first turn of a new session,
  /// replaced on model switch.
  String? systemPrompt;

  Session({
    required this.id,
    this.slug = '',
    this.title = '',
    this.model = '',
    this.status = SessionStatus.idle,
    this.agent = '',
    this.parentId,
    this.projectPath = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.contextTokens = 0,
    this.ttftMs = 0.0,
    this.tokPerSec = 0.0,
    this.promptCacheHitTokens = 0,
    this.thinkingMode = 'enabled',
    this.reasoningEffort = 'normal',
    this.runningOwnerId,
    this.runningHeartbeatAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.archivedAt,
    this.systemPrompt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  String get displayId => '#$id';

  @override
  String toString() {
    return 'Session($displayId: $title, status: $status)';
  }
}

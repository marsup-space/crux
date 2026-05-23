enum SessionStatus {
  idle,
  running,
  needUserAction,
  done,
}

class Session {
  final int id;
  final String slug;
  String title;
  String model;
  SessionStatus status;
  final String agent;
  final int? parentId;
  final String projectPath;
  double cost;
  int tokensIn;
  int tokensOut;
  int contextTokens;
  String thinkingMode;
  String? reasoningEffort;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? archivedAt;

  Session({
    required this.id,
    this.slug = '',
    this.title = '',
    this.model = '',
    this.status = SessionStatus.idle,
    this.agent = '',
    this.parentId,
    this.projectPath = '',
    this.cost = 0.0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.contextTokens = 0,
    this.thinkingMode = 'enabled',
    this.reasoningEffort = 'normal',
    DateTime? createdAt,
    DateTime? updatedAt,
    this.archivedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  String get displayId => '#$id';

  bool get isArchived => archivedAt != null;

  @override
  String toString() {
    return 'Session($displayId: $title, status: $status)';
  }
}

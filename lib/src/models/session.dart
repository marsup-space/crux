import 'session_runtime_state.dart';

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

  /// Per-session chat display mode (verbose vs vibe). In-memory only —
  /// mirrored from [SessionRuntimeState.chatDisplayMode] by
  /// [SessionController.persistChatDisplayMode]. Not persisted to the
  /// database; defaults to [ChatDisplayMode.vibe] on app restart.
  ChatDisplayMode chatDisplayMode;

  /// Optional per-session override for the sampling temperature
  /// that the `/temperature` slash command sets. When non-null this
  /// wins over the model's TOML-configured default at the API-call
  /// site (see `chat_turn_executor.dart`). User input is clamped to
  /// `[0.0, 1.0]`; `null` means "no override".
  double? temperatureOverride;

  String? runningOwnerId;
  DateTime? runningHeartbeatAt;

  /// Session kind from the DB row: `'chat'` for Chat mode, anything
  /// else (`NULL`, `''`, `'session'`) for a regular workspace session.
  /// Use [isChat] rather than comparing this field directly.
  final String? kind;

  /// True for Chat-mode sessions: workspace-free, minimal system
  /// prompt, listed globally across Crux instances in the "Chats"
  /// section rather than the project-scoped "Sessions" list.
  bool get isChat => kind == 'chat';

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
    this.chatDisplayMode = ChatDisplayMode.vibe,
    this.temperatureOverride,
    this.runningOwnerId,
    this.runningHeartbeatAt,
    this.kind,
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

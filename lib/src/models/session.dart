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

  /// True when the session is pinned to the top of the sidebar's
  /// "Pinned" section.
  bool get isPinned => pinnedAt != null;

  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? archivedAt;

  /// Non-null when the session is pinned to the top of the sidebar.
  /// Pinned sessions render in a dedicated "Pinned" section and are
  /// skipped by the auto-archive sweep, so they never age out.
  DateTime? pinnedAt;

  /// The rendered system prompt — the joined content of all four
  /// layers, ready to be sent as a single `role: 'system'` message.
  /// `null` for legacy sessions or for sessions whose system prompt
  /// has not yet been built. Set on first turn of a new session,
  /// replaced on model switch.
  String? systemPrompt;

  /// Per-session subagent-mode switches. `null` = never set in this
  /// session → the global default from `config.toml [subagent]`
  /// applies. Once the user flips a switch in this session, the
  /// session's value is authoritative and persists across restarts.
  bool? subagentWorkersOn;
  bool? subagentExpertsOn;

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
    this.pinnedAt,
    this.systemPrompt,
    this.subagentWorkersOn,
    this.subagentExpertsOn,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  String get displayId => '#$id';

  /// True when the session has no user- or LLM-assigned title.
  /// An empty title IS the "untitled" state: creation paths
  /// persist `''` and the display layer renders a locale-aware
  /// placeholder ("New Session" / "新会话") instead of storing a
  /// literal. Never compare `title` against a placeholder
  /// string — a user might legitimately rename a session to
  /// exactly that text.
  bool get isUntitled => title.isEmpty;

  /// The title to render, substituting [placeholder] when
  /// [isUntitled]. Placeholder text is locale-aware and must
  /// come from the caller (UI strings catalog), because the
  /// model layer has no locale of its own.
  String displayTitle(String placeholder) =>
      title.isEmpty ? placeholder : title;

  @override
  String toString() {
    return 'Session($displayId: $title, status: $status)';
  }
}

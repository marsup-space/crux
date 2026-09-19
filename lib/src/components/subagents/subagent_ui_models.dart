// Presentation-only types for the first Subagent UI. These deliberately mirror
// only information the UI is allowed to show. The runtime/database layer can
// adapt richer records without making terminal components depend on persistence.
import '../../models/subagent.dart';

/// UI-only projection of the runtime's public Worker status.
///
/// Hosts map [WorkerPublicStatus] to this value at the presentation boundary,
/// keeping these widgets usable without a runtime or persistence dependency.
///
/// [queued] means the Worker holds an Assignment that has not yet been granted a
/// model slot. It is in flight, so it must not be rendered as idle — but it is
/// not running either, and reporting "busy" for both is what made a pool waiting
/// on a slot look like a pool that had hung.
enum SubagentUiStatus { ready, queued, busy }

extension SubagentUiRoleLabel on SubagentRole {
  String get label => switch (this) {
    SubagentRole.advisor => 'Advisor',
    SubagentRole.worker => 'Worker',
  };
}

extension SubagentUiStatusLabel on SubagentUiStatus {
  String get label => switch (this) {
    SubagentUiStatus.ready => 'ready',
    SubagentUiStatus.queued => 'waiting for model slot',
    SubagentUiStatus.busy => 'busy',
  };

  /// Sort rank: higher is more active, so callers never depend on the enum's
  /// declaration order.
  int get activityRank => switch (this) {
    SubagentUiStatus.ready => 0,
    SubagentUiStatus.queued => 1,
    SubagentUiStatus.busy => 2,
  };

  /// True while the Worker holds an Assignment that has not reached a terminal
  /// state — whether it is running or still waiting for a slot.
  bool get isInFlight => this != SubagentUiStatus.ready;
}

/// The Worker committed-context estimate and the active model's context window.
///
/// [usedTokens] is estimated from precisely the committed context string the
/// Worker executor supplies to its next run; it is never a persisted character
/// count or the cumulative token total of prior runs.
class SubagentContextUsage {
  final int usedTokens;
  final int capacityTokens;

  const SubagentContextUsage({
    required this.usedTokens,
    required this.capacityTokens,
  }) : assert(usedTokens >= 0),
       assert(capacityTokens > 0);

  int get percent => (usedTokens * 100 / capacityTokens).round();
}

/// A stable, committed snapshot suitable for the Home pool and chat toolbar.
class SubagentUiEntry {
  final String id;
  final String name;
  final SubagentRole role;
  final String domain;
  final SubagentUiStatus status;
  final String model;
  final String assignmentSummary;
  final DateTime lastActive;

  /// The current Assignment's recorded intent — the commander's stated
  /// purpose at dispatch time, never the task text. Null when the assignment
  /// predates intent recording (pre-v38 rows) or the Worker has never been
  /// dispatched; the tooltip hides the line rather than inventing one.
  final String? assignmentIntent;

  /// Null when the active model's context-window metadata is unavailable, or
  /// when this Worker has no live Assignment. The UI must show unavailable
  /// rather than derive a value from durable transcript character counts.
  final SubagentContextUsage? contextUsage;

  /// The newest immutable report body. It must never contain a streaming
  /// partial response; callers provide only a committed record.
  final String? latestReport;
  final List<String> committedTranscript;
  final List<String> checkpoints;
  final List<String> forkLineage;

  /// A destroyed one-shot Fork remains inspectable as a minimal tombstone.
  final bool isTombstone;
  final String? injectedReportTarget;

  const SubagentUiEntry({
    required this.id,
    required this.name,
    required this.role,
    this.domain = 'general',
    required this.status,
    required this.model,
    required this.assignmentSummary,
    required this.lastActive,
    this.assignmentIntent,
    this.contextUsage,
    this.latestReport,
    this.committedTranscript = const [],
    this.checkpoints = const [],
    this.forkLineage = const [],
    this.isTombstone = false,
    this.injectedReportTarget,
  });
}

import '../services/plan_mode_controller.dart';
import 'tool_def.dart';

/// `ask_plan_mode` — the agent proposes entering / exiting plan mode,
/// or approving / unapproving the active plan.
///
/// The tool does NOT flip plan mode itself: plan mode and the approved
/// gate are UI/user decisions. Instead it returns guidance telling the
/// agent to ask the user (via the `ask://` quick-reply pattern or plain
/// text) to confirm with `/plan` (or `/plan approve` /
/// `/plan unapprove`). This mirrors how the shell high-risk layer
/// surfaces a confirmation rather than acting unilaterally (design doc
/// §5 P6).
///
/// Schema: `{action: 'enter'|'exit'|'approve'|'unapprove', plan_name?: string}`.
class AskPlanModeTool extends ToolDef {
  /// The per-session plan-mode controller. Null in tests / legacy
  /// harnesses; the tool then reports that plan mode is unavailable.
  final PlanModeController? planModeController;

  AskPlanModeTool({this.planModeController});

  @override
  String get name => 'ask_plan_mode';

  @override
  String get description =>
      'Ask the user to enter or exit plan mode (a two-pane planning '
      'surface: a live plan document on the left, the conversation on '
      'the right), or to approve / unapprove the active plan. Call this '
      'when you want to switch into a planning workflow, when the user '
      'has signed off on the plan and you are ready to implement it, '
      'when you need to step back to plan-only editing, or when the '
      'plan is done and you are ready to exit. This does NOT change '
      'mode by itself — it asks the user to confirm with /plan.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['enter', 'exit', 'approve', 'unapprove'],
        'description':
            "'enter' to propose entering plan mode, 'exit' to propose "
            "leaving it, 'approve' to propose approving the plan (lift the "
            "edit guards so the plan can be implemented), 'unapprove' to "
            "propose returning to plan-only editing.",
      },
      'plan_name': {
        'type': 'string',
        'description':
            'Optional plan document name (without .md) for action=enter. '
            'Defaults to PLAN.md.',
      },
    },
    'required': ['action'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action'] as String?;
    const actions = {'enter', 'exit', 'approve', 'unapprove'};
    if (action == null || !actions.contains(action)) {
      return ToolResult.error(
        "Missing or invalid 'action': expected one of "
        "'enter', 'exit', 'approve', 'unapprove'",
      );
    }

    final controller = planModeController;
    if (controller == null) {
      return ToolResult(
        title: 'ask_plan_mode',
        output: 'Plan mode is unavailable in this session.',
      );
    }

    final alreadyActive = controller.active;
    final planName = args['plan_name'] as String?;
    final planPath = planName != null && planName.isNotEmpty
        ? '${ctx.workingDirectory}/${planName.endsWith('.md') ? planName : '$planName.md'}'
        : '${ctx.workingDirectory}/PLAN.md';

    if (action == 'enter') {
      if (alreadyActive) {
        return ToolResult(
          title: 'ask_plan_mode',
          output:
              'Plan mode is already active on ${controller.planDocPath}. '
              'Propose changes to the plan doc with edit.',
        );
      }
      return ToolResult(
        title: 'ask_plan_mode',
        output:
            'You proposed entering plan mode on $planPath. Plan mode is a '
            'user decision — ask the user to confirm, e.g.:\n\n'
            'ask://Enter plan mode{/plan}\n'
            'ask://Stay in chat{no}\n\n'
            'Once the user confirms with /plan, the plan pane opens and '
            'you may edit only the plan doc.',
      );
    }

    if (action == 'exit') {
      if (!alreadyActive) {
        return ToolResult(
          title: 'ask_plan_mode',
          output: 'Plan mode is not active. Nothing to exit.',
        );
      }
      return ToolResult(
        title: 'ask_plan_mode',
        output:
            'You proposed leaving plan mode. Plan mode is a user decision — '
            'ask the user to confirm, e.g.:\n\n'
            'ask://Exit plan mode{/plan}\n'
            'ask://Keep planning{no}\n\n'
            'Once the user confirms with /plan, the pane collapses and '
            'normal editing resumes.',
      );
    }

    // approve / unapprove — require an active plan.
    if (!alreadyActive) {
      return ToolResult(
        title: 'ask_plan_mode',
        output: 'Plan mode is not active. Nothing to $action.',
      );
    }

    if (action == 'approve') {
      if (controller.approved) {
        return ToolResult(
          title: 'ask_plan_mode',
          output:
              'The plan is already approved — the codebase is editable. '
              'Implement the plan.',
        );
      }
      return ToolResult(
        title: 'ask_plan_mode',
        output:
            'You proposed approving the plan. Approval is a user decision '
            '— ask the user to confirm, e.g.:\n\n'
            'ask://Approve plan{/plan approve}\n'
            'ask://Keep planning{no}\n\n'
            'Once the user confirms with /plan approve, the plan doc stays '
            'visible and edit/write/shell operate on the whole codebase to '
            'implement the plan.',
      );
    }

    // action == 'unapprove'
    if (!controller.approved) {
      return ToolResult(
        title: 'ask_plan_mode',
        output:
            'The plan is not approved — already in plan-only editing mode.',
      );
    }
    return ToolResult(
      title: 'ask_plan_mode',
      output:
          'You proposed stepping back to plan-only editing. This is a user '
          'decision — ask the user to confirm, e.g.:\n\n'
          'ask://Back to plan-only{/plan unapprove}\n'
          'ask://Keep implementing{no}\n\n'
          'Once the user confirms with /plan unapprove, the plan-mode guards '
          're-arm and only the plan doc is editable again.',
    );
  }
}

import '../components/ui/toast.dart';
import '../services/plan_mode_controller.dart';
import 'command_executor.dart';

/// `/plan` — enter or leave plan mode.
///
///   `/plan`          → enter with the default `<projectPath>/PLAN.md`,
///                      or exit when already active (toggle).
///   `/plan <name>`   → enter with `<projectPath>/<name>.md`.
///
/// Creates the plan file with a skeleton (`# Plan\n\n`) when absent.
/// Strings → `cmd.plan.*`.
///
/// Autocomplete (`input_overlay.dart`, `/plan` + param 0) only lists
/// plans that either carry "plan" in the file name (case-insensitive)
/// or have version history under `.crux/plans/` — see
/// `listKnownPlanNames`. The command itself still accepts any name;
/// an unlisted one simply creates the doc on enter.
///
/// `availableDuringResponse: true` in the registry because entering /
/// leaving plan mode only flips pane state — it never touches the
/// in-flight stream (the plan-mode guards take effect on the *next*
/// tool call).
Future<void> executePlan(List<String> parts, CommandContext ctx) async {
  final controller = ctx.planModeController;
  if (controller == null) {
    ctx.showToast(ctx.strings.t('cmd.plan.unavailable'), mode: ToastMode.error);
    return;
  }

  // `/plan` while active → exit (toggle).
  if (controller.active && parts.length <= 1) {
    controller.exit();
    ctx.showToast(ctx.strings.t('cmd.plan.exited'), mode: ToastMode.status);
    ctx.refresh();
    return;
  }

  // `/plan approve` / `/plan unapprove` — flip the approved gate
  // without leaving plan mode (the pane stays visible).
  final sub = parts.length > 1 ? parts[1].toLowerCase() : null;
  if (sub == 'approve' || sub == 'unapprove') {
    if (!controller.active) {
      ctx.showToast(
        ctx.strings.t('cmd.plan.unavailable'),
        mode: ToastMode.error,
      );
      return;
    }
    if (sub == 'approve') {
      controller.approve();
      ctx.showToast(ctx.strings.t('cmd.plan.approved'), mode: ToastMode.status);
    } else {
      controller.unapprove();
      ctx.showToast(
        ctx.strings.t('cmd.plan.unapproved'),
        mode: ToastMode.status,
      );
    }
    ctx.refresh();
    return;
  }

  final name = parts.length > 1 ? parts.sublist(1).join(' ') : null;
  controller.enter(ctx.projectPath, planName: name);
  ctx.showToast(
    ctx.strings.t('cmd.plan.entered', {
      'path': controller.planDocPath ?? kDefaultPlanDocName,
    }),
    mode: ToastMode.status,
  );
  ctx.refresh();
}

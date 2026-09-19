import '../components/ui/toast.dart';
import '../models/subagent.dart';
import 'command_executor.dart';

/// The `/subagent` command — toggle the two independent subagent-mode
/// switches.
///
/// Usage:
///   /subagent                  → show current switch states
///   /subagent workers on|off   → toggle worker dispatch
///   /subagent experts on|off   → toggle expert consultation
///
/// Mirrors `cmd_language.dart`: feedback strings are looked up AFTER the
/// switch so the toast renders in the active UI language, and a config
/// write failure downgrades to an error toast without reverting state.
Future<void> executeSubagent(List<String> parts, CommandContext ctx) async {
  final controller = ctx.subagentController;
  if (controller == null) {
    ctx.showToast(
      ctx.strings.t('subagent.cmd.unavailable'),
      mode: ToastMode.error,
    );
    return;
  }

  final strings = ctx.strings;
  if (parts.length < 3) {
    // No args (or incomplete): report both switch states.
    final workers = controller.workersOn
        ? strings.t('subagent.cmd.workersOn')
        : strings.t('subagent.cmd.workersOff');
    final experts = controller.expertsOn
        ? strings.t('subagent.cmd.expertsOn')
        : strings.t('subagent.cmd.expertsOff');
    ctx.showToast('$workers\n$experts');
    return;
  }

  final roleArg = parts[1].trim().toLowerCase();
  final stateArg = parts[2].trim().toLowerCase();
  final SubagentRole? role = switch (roleArg) {
    'worker' || 'workers' => SubagentRole.worker,
    'expert' || 'experts' => SubagentRole.expert,
    _ => null,
  };
  if (role == null || (stateArg != 'on' && stateArg != 'off')) {
    ctx.showToast(
      '${strings.t('subagent.cmd.unavailable')}\n'
      'Usage: /subagent <workers|experts> <on|off>',
      mode: ToastMode.error,
    );
    return;
  }

  final result = await controller.setToggle(role, stateArg == 'on');
  final label = role == SubagentRole.worker
      ? (stateArg == 'on'
            ? strings.t('subagent.cmd.workersOn')
            : strings.t('subagent.cmd.workersOff'))
      : (stateArg == 'on'
            ? strings.t('subagent.cmd.expertsOn')
            : strings.t('subagent.cmd.expertsOff'));
  if (!result.persisted) {
    ctx.showToast(
      strings.t('subagent.cmd.persistFailed'),
      mode: ToastMode.error,
    );
    return;
  }
  ctx.showToast(label, mode: ToastMode.status);
}

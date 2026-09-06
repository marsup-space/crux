import '../components/ui/toast.dart';
import 'command_executor.dart';

/// `/setup` — reopen the launch setup experience with current values intact.
Future<void> executeSetup(CommandContext ctx) async {
  if (ctx.showSetup == null) {
    ctx.showToast('Setup is unavailable.', mode: ToastMode.error);
    return;
  }
  ctx.showSetup!();
}

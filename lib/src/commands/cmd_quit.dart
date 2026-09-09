import '../components/ui/toast.dart';
import '../models/session.dart';
import 'command_executor.dart';

Future<void> executeQuit(CommandContext ctx) async {
  final anyRunning = ctx.sessions.any((s) => s.status == SessionStatus.running);
  if (anyRunning) {
    ctx.showToast(ctx.strings.t('toast.quitRunning'), mode: ToastMode.error);
    return;
  }
  if (ctx.quitApp == null) {
    ctx.showToast(
      ctx.strings.t('toast.quitUnavailable'),
      mode: ToastMode.error,
    );
    return;
  }
  ctx.quitApp!();
}

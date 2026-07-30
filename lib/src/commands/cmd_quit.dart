import '../components/ui/toast.dart';
import '../models/session.dart';
import 'command_executor.dart';

Future<void> executeQuit(CommandContext ctx) async {
  final anyRunning = ctx.sessions.any((s) => s.status == SessionStatus.running);
  if (anyRunning) {
    ctx.showToast(
      'A session is running — ESC×2 interrupts the response, Ctrl+C×2 exits',
      mode: ToastMode.error,
    );
    return;
  }
  if (ctx.quitApp == null) {
    ctx.showToast('Quit unavailable (no TUI bound)', mode: ToastMode.error);
    return;
  }
  ctx.quitApp!();
}

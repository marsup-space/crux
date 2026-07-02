import '../components/ui/toast.dart';
import '../models/session.dart';
import 'command_executor.dart';
Future<void> executeQuit(CommandContext ctx) async {
  final anyRunning = ctx.sessions.any((s) => s.status == SessionStatus.running);
  if (anyRunning) {
    ctx.showToast(
      'A session is running — press Ctrl+C×2 to force quit',
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

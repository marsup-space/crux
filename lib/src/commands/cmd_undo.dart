import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeUndo(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast('No active session', mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast('Cannot undo while AI is responding', mode: ToastMode.error);
    return;
  }
  final lastUser = await ctx.findLastUserMessage();
  if (lastUser == null) {
    ctx.showToast(
      'Nothing to undo — no user message yet',
      mode: ToastMode.info,
    );
    return;
  }
  await ctx.deleteMessagesFrom(lastUser.id);
  ctx.clearBtwTurns(sessionId);
  ctx.setInputText?.call(lastUser.content);
  ctx.showToast(
    'Undone — edit the prompt and press Enter to resend',
    mode: ToastMode.status,
  );
}

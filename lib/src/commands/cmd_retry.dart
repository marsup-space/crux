import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeRetry(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast('No active session', mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast('Cannot retry while AI is responding');
    return;
  }
  final lastUser = await ctx.findLastUserMessage();
  if (lastUser == null) {
    ctx.showToast('Nothing to retry — no user message yet');
    return;
  }
  await ctx.deleteMessagesFrom(lastUser.id);
  ctx.clearBtwTurns(sessionId);
  await ctx.sendTurn(text: lastUser.content);
}

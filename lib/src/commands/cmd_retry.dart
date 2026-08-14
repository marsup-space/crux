import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeRetry(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast(ctx.strings.t('toast.retryResponding'));
    return;
  }
  final lastUser = await ctx.findLastUserMessage();
  if (lastUser == null) {
    ctx.showToast(ctx.strings.t('toast.nothingRetry'));
    return;
  }
  await ctx.deleteMessagesFrom(lastUser.id);
  ctx.clearBtwTurns(sessionId);
  await ctx.sendTurn(text: lastUser.content);
}

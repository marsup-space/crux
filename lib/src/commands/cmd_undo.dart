import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeUndo(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast(ctx.strings.t('toast.undoResponding'), mode: ToastMode.error);
    return;
  }
  final lastUser = await ctx.findLastUserMessage();
  if (lastUser == null) {
    ctx.showToast(
      ctx.strings.t('toast.nothingUndo'),
      mode: ToastMode.info,
    );
    return;
  }
  await ctx.deleteMessagesFrom(lastUser.id);
  ctx.clearBtwTurns(sessionId);
  ctx.setInputText?.call(lastUser.content);
  ctx.showToast(
    ctx.strings.t('toast.undone'),
    mode: ToastMode.status,
  );
}

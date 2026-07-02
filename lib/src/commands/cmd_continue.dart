import '../components/ui/toast.dart';
import 'command_executor.dart';
Future<void> executeContinue(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast('No active session', mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast('AI is already responding');
    return;
  }
  if (ctx.currentMessages.isEmpty) {
    ctx.showToast('Nothing to continue — session is empty');
    return;
  }
  final lastRole = ctx.currentMessages.last.role;
  switch (lastRole) {
    case 'tool':
    case 'user':
      await ctx.sendTurn();
    case 'ai':
    case 'tool_call':
      await ctx.sendTurn(text: '请继续。');
    default:
      await ctx.sendTurn(text: '请继续。');
  }
}

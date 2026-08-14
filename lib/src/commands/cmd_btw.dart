import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeBtw(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final rt = ctx.runtime(sessionId);
  if (rt.isResponding) {
    ctx.showToast(ctx.strings.t('toast.responding'));
    return;
  }
  if (parts.length < 2 || parts[1].trim().isEmpty) {
    ctx.showToast(ctx.strings.t('toast.btwUsage'));
    return;
  }
  final prompt = parts.skip(1).join(' ').trim();
  if (prompt.isEmpty) {
    ctx.showToast(ctx.strings.t('toast.btwUsage'));
    return;
  }
  await ctx.sendBtwTurn(prompt);
}

import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeRename(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast('No active session', mode: ToastMode.error);
    return;
  }
  final newTitle = parts.skip(1).join(' ').trim();
  if (newTitle.isEmpty) {
    ctx.showToast('Usage: /rename <new title>');
    return;
  }
  if (newTitle == ctx.currentSession.title) {
    ctx.showToast('Title unchanged');
    return;
  }
  final oldTitle = ctx.currentSession.title;
  await ctx.store.update(ctx.currentSessionId!, title: newTitle);
  ctx.currentSession.title = newTitle;
  ctx.refresh();
  ctx.showToast('Renamed "$oldTitle" → "$newTitle"', mode: ToastMode.status);
}

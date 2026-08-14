import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeRename(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final newTitle = parts.skip(1).join(' ').trim();
  if (newTitle.isEmpty) {
    ctx.showToast(ctx.strings.t('toast.renameUsage'));
    return;
  }
  if (newTitle == ctx.currentSession.title) {
    ctx.showToast(ctx.strings.t('toast.titleUnchanged'));
    return;
  }
  final oldTitle = ctx.currentSession.title;
  await ctx.store.update(ctx.currentSessionId!, title: newTitle);
  ctx.currentSession.title = newTitle;
  ctx.refresh();
  ctx.showToast(
    ctx.strings.t('toast.renamed', {'old': oldTitle, 'new': newTitle}),
    mode: ToastMode.status,
  );
}

import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeArchive(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast('No active session', mode: ToastMode.error);
    return;
  }
  final sessionId = ctx.currentSessionId!;
  final session = ctx.sessions.where((s) => s.id == sessionId).firstOrNull;
  final title = session?.title ?? '#$sessionId';
  await ctx.store.archiveSession(sessionId);
  await ctx.initSessions();
  ctx.showToast('Archived "$title"', mode: ToastMode.status);
}

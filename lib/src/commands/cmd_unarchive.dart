import '../components/ui/toast.dart';
import 'command_executor.dart';
Future<void> executeUnarchive(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final idStr = parts[1].replaceFirst('#', '');
    final id = int.tryParse(idStr);
    if (id != null) {
      final session = await ctx.store.getById(id);
      if (session == null) {
        ctx.showToast('Session #$id not found', mode: ToastMode.error);
        return;
      }
      if (session.archivedAt == null) {
        ctx.showToast('Session #$id is not archived');
        return;
      }
      await ctx.store.unarchiveSession(id);
      await ctx.initSessions();
      ctx.showToast('Unarchived "${session.title}"', mode: ToastMode.status);
    } else {
      ctx.showToast('Usage: /unarchive #<id>');
    }
  } else {
    final archived = await ctx.store.list(
      projectPath: ctx.projectPath,
      includeArchived: true,
      limit: 100,
    );
    final onlyArchived = archived.where((s) => s.archivedAt != null).toList();
    if (onlyArchived.isEmpty) {
      ctx.showToast('No archived sessions');
      return;
    }
    final lines = <String>['Archived sessions:'];
    for (final s in onlyArchived) {
      lines.add('  #${s.id} ${s.title}');
    }
    ctx.showToast(lines.join('\n'));
  }
}

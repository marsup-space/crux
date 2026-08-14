import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeUnarchive(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final idStr = parts[1].replaceFirst('#', '');
    final id = int.tryParse(idStr);
    if (id != null) {
      final session = await ctx.store.getById(id);
      if (session == null) {
        ctx.showToast(ctx.strings.t('toast.sessionNotFound', {'id': '$id'}), mode: ToastMode.error);
        return;
      }
      if (session.archivedAt == null) {
        ctx.showToast(ctx.strings.t('toast.notArchived', {'id': '$id'}));
        return;
      }
      await ctx.store.unarchiveSession(id);
      await ctx.initSessions();
      ctx.showToast(ctx.strings.t('toast.unarchived', {'title': session.title}), mode: ToastMode.status);
    } else {
      ctx.showToast(ctx.strings.t('toast.unarchiveUsage'));
    }
  } else {
    final archived = await ctx.store.list(
      projectPath: ctx.projectPath,
      includeArchived: true,
      limit: 100,
    );
    final onlyArchived = archived.where((s) => s.archivedAt != null).toList();
    if (onlyArchived.isEmpty) {
      ctx.showToast(ctx.strings.t('toast.noArchived'));
      return;
    }
    final lines = <String>[ctx.strings.t('toast.archivedList')];
    for (final s in onlyArchived) {
      lines.add('  #${s.id} ${s.title}');
    }
    ctx.showToast(lines.join('\n'));
  }
}

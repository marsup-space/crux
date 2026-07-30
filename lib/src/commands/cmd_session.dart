import 'command_executor.dart';

Future<void> executeSession(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final idStr = parts[1].replaceFirst('#', '');
    final id = int.tryParse(idStr);
    if (id != null) {
      await ctx.switchSession(id);
    } else {
      ctx.showToast('Usage: /session #<id>');
    }
  } else {
    ctx.showToast('Usage: /session #<id>');
  }
}

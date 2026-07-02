import '../components/ui/toast.dart';
import 'command_executor.dart';
Future<void> executeTheme(List<String> parts, CommandContext ctx) async {
  final controller = ctx.themeController;
  if (controller == null) {
    ctx.showToast('Theme service is unavailable', mode: ToastMode.error);
    return;
  }
  final id = parts.length > 1 ? parts[1].trim() : '';
  if (id.isEmpty) {
    ctx.showToast('Current theme: ${controller.activeId}. Usage: /theme <name>');
    return;
  }
  final result = await controller.switchTheme(id);
  if (!result.found) {
    ctx.showToast(
      'Unknown theme "$id". Available: ${controller.availableIds.join(", ")}',
      mode: ToastMode.error,
    );
    return;
  }
  if (!result.persisted) {
    ctx.showToast(
      'Theme switched to $id, but config could not be saved',
      mode: ToastMode.error,
    );
    return;
  }
  ctx.showToast('Theme switched to $id', mode: ToastMode.status);
}

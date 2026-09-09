import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeTheme(List<String> parts, CommandContext ctx) async {
  final controller = ctx.themeController;
  if (controller == null) {
    ctx.showToast(
      ctx.strings.t('toast.themeUnavailable'),
      mode: ToastMode.error,
    );
    return;
  }
  final id = parts.length > 1 ? parts[1].trim() : '';
  if (id.isEmpty) {
    ctx.showToast(
      ctx.strings.t('toast.themeCurrent', {'id': controller.activeId}),
    );
    return;
  }
  final result = await controller.switchTheme(id);
  if (!result.found) {
    ctx.showToast(
      ctx.strings.t('toast.themeUnknown', {
        'id': id,
        'list': controller.availableIds.join(', '),
      }),
      mode: ToastMode.error,
    );
    return;
  }
  if (!result.persisted) {
    ctx.showToast(
      ctx.strings.t('toast.themePersistFailed', {'id': id}),
      mode: ToastMode.error,
    );
    return;
  }
  ctx.showToast(
    ctx.strings.t('toast.themeSwitched', {'id': id}),
    mode: ToastMode.status,
  );
}

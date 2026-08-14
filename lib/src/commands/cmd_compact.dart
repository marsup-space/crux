import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeCompact(CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final compact = ctx.compactSession;
  if (compact == null) {
    ctx.showToast(ctx.strings.t('toast.compactUnavailable'), mode: ToastMode.error);
    return;
  }
  await compact();
}

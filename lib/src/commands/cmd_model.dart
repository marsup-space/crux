import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeModel(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final modelKey = parts[1];
    if (ctx.providerServiceReady &&
        ctx.providerService.modelByCompositeKey(modelKey) == null) {
      ctx.showToast(ctx.strings.t('toast.unknownModel', {'model': modelKey}), mode: ToastMode.error);
    } else {
      if (ctx.currentSessionId != null) {
        await ctx.store.update(ctx.currentSessionId!, model: modelKey);
        ctx.currentSession.model = modelKey;
      }
      ctx.refresh();
      ctx.showToast(ctx.strings.t('toast.modelSwitched', {'model': modelKey}), mode: ToastMode.status);
      ctx.providerService.setLastUsedModel(modelKey);
    }
  } else {
    ctx.showToast(ctx.strings.t('toast.modelUsage'));
  }
}

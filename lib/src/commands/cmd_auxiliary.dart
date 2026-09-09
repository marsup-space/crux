import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeAuxiliary(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final modelKey = parts[1];
    if (modelKey == 'none') {
      await ctx.providerService.setAuxiliaryModel('none');
      ctx.resolveAuxiliaryModel();
      ctx.showToast(ctx.strings.t('toast.auxDisabled'), mode: ToastMode.status);
    } else if (ctx.providerServiceReady &&
        ctx.providerService.modelByCompositeKey(modelKey) == null) {
      ctx.showToast(
        ctx.strings.t('toast.unknownModel', {'model': modelKey}),
        mode: ToastMode.error,
      );
    } else {
      await ctx.providerService.setAuxiliaryModel(modelKey);
      ctx.resolveAuxiliaryModel();
      // Toast the human-readable TOML `name` — same rationale as
      // /model's toast (OpenRouter composite keys are too noisy).
      final display = ctx.providerServiceReady
          ? ctx.providerService.displayLabelFor(modelKey)
          : modelKey;
      ctx.showToast(
        ctx.strings.t('toast.auxSet', {'model': display}),
        mode: ToastMode.status,
      );
    }
  } else {
    ctx.showToast(ctx.strings.t('toast.auxUsage'));
  }
}

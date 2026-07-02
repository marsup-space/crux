import '../components/ui/toast.dart';
import 'command_executor.dart';
Future<void> executeAuxiliary(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final modelKey = parts[1];
    if (modelKey == 'none') {
      await ctx.providerService.setAuxiliaryModel('none');
      ctx.resolveAuxiliaryModel();
      ctx.showToast('Auxiliary model disabled', mode: ToastMode.status);
    } else if (ctx.providerServiceReady &&
        ctx.providerService.modelByCompositeKey(modelKey) == null) {
      ctx.showToast('Unknown model: $modelKey', mode: ToastMode.error);
    } else {
      await ctx.providerService.setAuxiliaryModel(modelKey);
      ctx.resolveAuxiliaryModel();
      ctx.showToast('Auxiliary model set to $modelKey', mode: ToastMode.status);
    }
  } else {
    ctx.showToast('Usage: /auxiliary <name>');
  }
}

import '../components/ui/toast.dart';
import '../utils/terminal_symbols.dart';
import 'command_executor.dart';

Future<void> executeProvider(List<String> parts, CommandContext ctx) async {
  final name = parts.length > 1 ? parts[1].trim() : '';
  final arg = parts.length > 2 ? parts[2].trim() : '';
  if (name.isEmpty) {
    final names = ctx.providerService.providerNames();
    ctx.showToast(
      ctx.strings.t('toast.providerList', {'names': names.join(', ')}),
    );
    return;
  }
  final provider = ctx.providerService.providerByName(name);
  if (provider == null) {
    final names = ctx.providerService.providerNames();
    ctx.showToast(
      ctx.strings.t('toast.providerNotFound', {
        'name': name,
        'names': names.join(', '),
      }),
      mode: ToastMode.error,
    );
    return;
  }
  if (arg.isEmpty) {
    final hasKey = ctx.providerService.getApiKey(name) != null;
    final models = provider.models.map((m) => m.name).join(', ');
    ctx.showToast(
      ctx.strings.t('toast.providerStatus', {
        'name': name,
        'type': provider.type,
        'endpoint': provider.endpointUrl,
        'key': ctx.strings.t(hasKey ? 'toast.keySet' : 'toast.keyMissing'),
        'models': models,
      }),
    );
    return;
  }
  if (arg == 'remove' || arg == '--remove' || arg == 'rm') {
    await ctx.providerService.removeApiKey(name);
    ctx.showToast(
      '${terminalSymbol('✓', '+')} ${ctx.strings.t('toast.removedKey', {'name': name})}',
      mode: ToastMode.status,
    );
    return;
  }
  await ctx.providerService.setApiKey(name, arg);
  ctx.showToast(
    '${terminalSymbol('✓', '+')} ${ctx.strings.t('toast.savedKey', {'name': name})}',
    mode: ToastMode.status,
  );
}

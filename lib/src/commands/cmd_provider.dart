import '../components/ui/toast.dart';
import '../utils/terminal_symbols.dart';
import 'command_executor.dart';

Future<void> executeProvider(List<String> parts, CommandContext ctx) async {
  final name = parts.length > 1 ? parts[1].trim() : '';
  final arg = parts.length > 2 ? parts[2].trim() : '';
  if (name.isEmpty) {
    final names = ctx.providerService.providerNames();
    ctx.showToast(
      'Providers: ${names.join(", ")}. Usage: /provider <name> [<key>|remove]',
    );
    return;
  }
  final provider = ctx.providerService.providerByName(name);
  if (provider == null) {
    final names = ctx.providerService.providerNames();
    ctx.showToast(
      'Provider "$name" not found. Available: ${names.join(", ")}. '
      'To add it, copy ~/.config/crux/providers/example.provider.toml '
      'to ~/.config/crux/providers/$name.toml and edit it.',
      mode: ToastMode.error,
    );
    return;
  }
  if (arg.isEmpty) {
    final hasKey = ctx.providerService.getApiKey(name) != null;
    final models = provider.models.map((m) => m.name).join(', ');
    ctx.showToast(
      '$name  [${provider.type}]  endpoint=${provider.endpointUrl}  '
      'key=${hasKey ? "set" : "missing"}  models=$models',
    );
    return;
  }
  if (arg == 'remove' || arg == '--remove' || arg == 'rm') {
    await ctx.providerService.removeApiKey(name);
    ctx.showToast(
      '${terminalSymbol('✓', '+')} Removed API key for $name',
      mode: ToastMode.status,
    );
    return;
  }
  await ctx.providerService.setApiKey(name, arg);
  ctx.showToast(
    '${terminalSymbol('✓', '+')} Saved API key for $name',
    mode: ToastMode.status,
  );
}

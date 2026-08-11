import '../components/ui/toast.dart';
import '../services/web_service_provider.dart';
import '../utils/terminal_symbols.dart';
import 'command_executor.dart';

Future<void> executeWebProvider(List<String> parts, CommandContext ctx) async {
  final registry = ctx.webProviderRegistry;
  if (parts.length == 1) {
    final providers = registry.allProviders;
    if (providers.isEmpty) {
      ctx.showToast('No web providers registered.', mode: ToastMode.error);
      return;
    }
    ctx.showToast(providers.map(_webProviderStatusLine).join('\n'));
    return;
  }
  final providerId = parts[1].trim();
  final provider = registry.getProvider(providerId);
  if (provider == null) {
    final known = registry.allProviders.map((p) => p.id).join(', ');
    ctx.showToast(
      'Unknown web provider "$providerId".'
      '${known.isEmpty ? '' : ' Known: $known.'}'
      ' Usage: /web-provider <name> <key>|remove',
      mode: ToastMode.error,
    );
    return;
  }
  if (parts.length == 2) {
    ctx.showToast(_webProviderStatusLine(provider));
    return;
  }
  final action = parts[2].trim();
  // Convenience: accept the key bare, without the `key` sub-action —
  // `/web-provider tinyfish sk-…` — mirroring `/provider <name> <key>`.
  // Setting a key is the overwhelming majority of uses; the extra
  // token only existed to leave room for sub-actions and was a
  // recurring footgun. `key`, `remove`/`--remove`/`rm` keep working.
  final actionIsRemoval =
      action == 'remove' || action == '--remove' || action == 'rm';
  final valueArg = action == 'key'
      ? (parts.length > 3 ? parts[3].trim() : '')
      : actionIsRemoval
      ? 'remove'
      : action;
  if (valueArg == 'remove' || valueArg == '--remove' || valueArg == 'rm') {
    try {
      await registry.removeApiKey(providerId);
      ctx.showToast(
        '${terminalSymbol('✓', '+')} Removed ${provider.displayName} API key.',
        mode: ToastMode.status,
      );
    } on ArgumentError catch (e) {
      ctx.showToast(e.message.toString(), mode: ToastMode.error);
    }
    return;
  }
  if (valueArg.isEmpty) {
    ctx.showToast(
      'Missing key value. Usage: /web-provider $providerId key <value>',
      mode: ToastMode.error,
    );
    return;
  }
  try {
    await registry.setApiKey(providerId, valueArg);
    ctx.showToast(
      '${terminalSymbol('✓', '+')} Saved ${provider.displayName} API key.',
      mode: ToastMode.status,
    );
  } on ArgumentError catch (e) {
    ctx.showToast(e.message.toString(), mode: ToastMode.error);
  }
}

String _webProviderStatusLine(WebServiceProvider p) {
  final caps = <String>[
    if (p.supportsSearch) 'search',
    if (p.supportsFetch) 'fetch',
  ].join('+');
  return '${p.id}  [${p.displayName}]  capabilities=$caps  key=${p.isConfigured ? "set" : "missing"}';
}

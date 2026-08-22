import '../components/ui/toast.dart';
import '../services/openrouter_stealth_sync.dart';
import '../utils/terminal_symbols.dart';
import 'command_executor.dart';

/// Holds the pending sync plan between the `sync` preview and the
/// `sync confirm` apply. Keyed by provider name so a second preview
/// replaces the first. Not persisted — a restart clears it, which is
/// the desired "preview expires" behavior.
final Map<String, _PendingSync> _pendingSyncs = {};

class _PendingSync {
  _PendingSync(this.plan, this.endpointUrl);
  final StealthSyncPlan plan;
  final String endpointUrl;
}

/// `/provider openrouter-free sync` — preview the stealth-model diff
/// against OpenRouter's live catalog; `/provider openrouter-free sync
/// confirm` — apply it. Only the `openrouter-free` provider is
/// syncable; other names get a helpful error.
Future<void> executeProviderSync(
  String name,
  bool confirm,
  CommandContext ctx,
) async {
  if (name != OpenRouterStealthSync.providerName) {
    ctx.showToast(
      ctx.strings.t('toast.providerSyncUnsupported', {'name': name}),
      mode: ToastMode.error,
    );
    return;
  }
  final provider = ctx.providerService.providerByName(name);
  if (provider == null) {
    ctx.showToast(
      ctx.strings.t('toast.providerNotFound', {
        'name': name,
        'names': ctx.providerService.providerNames().join(', '),
      }),
      mode: ToastMode.error,
    );
    return;
  }

  final sync = OpenRouterStealthSync();

  if (!confirm) {
    // Preview: fetch + diff, stash the plan, show the lines.
    try {
      final plan = await sync.plan(
        endpointUrl: provider.endpointUrl,
        current: provider,
      );
      _pendingSyncs[name] = _PendingSync(plan, provider.endpointUrl);
      final lines = plan.previewLines().join('\n');
      ctx.showToast(
        ctx.strings.t('toast.providerSyncPreview', {'diff': lines}),
      );
    } catch (e) {
      ctx.showToast(
        ctx.strings.t('toast.providerSyncError', {'error': '$e'}),
        mode: ToastMode.error,
      );
    }
    return;
  }

  // Confirm: apply the stashed plan.
  final pending = _pendingSyncs.remove(name);
  if (pending == null) {
    ctx.showToast(
      ctx.strings.t('toast.providerSyncNoPending'),
      mode: ToastMode.error,
    );
    return;
  }
  try {
    final file = await sync.write(
      current: provider,
      syncPlan: pending.plan,
      userProvidersDir: ctx.providerService.providersDir,
    );
    await ctx.providerService.reload();
    ctx.refresh();
    ctx.showToast(
      '${terminalSymbol('✓', '+')} '
      '${ctx.strings.t('toast.providerSyncApplied', {
        'added': '${pending.plan.added.length}',
        'removed': '${pending.plan.removed.length}',
        'path': file.path,
      })}',
      mode: ToastMode.status,
    );
  } catch (e) {
    ctx.showToast(
      ctx.strings.t('toast.providerSyncError', {'error': '$e'}),
      mode: ToastMode.error,
    );
  }
}


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
  if (arg == 'sync' || arg == 'confirm') {
    await executeProviderSync(name, arg == 'confirm', ctx);
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

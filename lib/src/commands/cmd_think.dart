import '../components/ui/toast.dart';
import 'command_executor.dart';

Future<void> executeThink(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) return;
  final rt = ctx.runtime(ctx.currentSessionId!);
  final effort = parts.length > 1 ? parts[1] : '';
  final modelKey = ctx.currentSession.model;
  final slashIdx = modelKey.indexOf('/');
  final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
  final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
  final provider = ctx.providerServiceReady
      ? ctx.providerService.providerByName(providerName)
      : null;
  final modelConfig = provider?.modelById(modelId);
  final llm = ctx.providerServiceReady
      ? ctx.providerService.llmProviderByName(providerName)
      : null;
  final presets =
      llm?.reasoningPresetsFor(
        modelId,
        providerLabels: provider?.reasoningLabels ?? const {},
        modelLabels: modelConfig?.reasoningLabels ?? const {},
      ) ??
      const [];
  String resolveInput(String input) {
    for (final p in presets) {
      if (p.displayLabel == input) return p.internalValue;
    }
    return input;
  }

  String displayEffort(String internal) {
    for (final p in presets) {
      if (p.internalValue == internal) return p.displayLabel;
    }
    return internal;
  }

  final internalEffort = resolveInput(effort);
  switch (internalEffort) {
    case 'off':
      rt.thinkingMode = 'disabled';
      rt.reasoningEffort = null;
      ctx.persistThinkingLevel(rt);
      ctx.showToast('Thinking mode: off', mode: ToastMode.status);
    case 'low':
      rt.thinkingMode = 'enabled';
      rt.reasoningEffort = 'low';
      ctx.persistThinkingLevel(rt);
      ctx.showToast('Thinking mode: low', mode: ToastMode.status);
    case 'normal':
      rt.thinkingMode = 'enabled';
      rt.reasoningEffort = 'normal';
      ctx.persistThinkingLevel(rt);
      ctx.showToast(
        'Thinking mode: ${displayEffort('normal')}',
        mode: ToastMode.status,
      );
    case 'high':
      rt.thinkingMode = 'enabled';
      rt.reasoningEffort = 'high';
      ctx.persistThinkingLevel(rt);
      ctx.showToast('Thinking mode: high', mode: ToastMode.status);
    case 'max':
      rt.thinkingMode = 'enabled';
      rt.reasoningEffort = 'max';
      ctx.persistThinkingLevel(rt);
      ctx.showToast('Thinking mode: max', mode: ToastMode.status);
    default:
      final current = rt.thinkingMode == 'disabled'
          ? 'off'
          : displayEffort(rt.reasoningEffort ?? 'normal');
      final levelLabels = presets.map((p) => p.displayLabel).toList();
      final levels = levelLabels.isNotEmpty
          ? '<${levelLabels.join('|')}>'
          : '<off|low|normal|high|max>';
      ctx.showToast('Usage: /think $levels (current: $current)');
  }
}

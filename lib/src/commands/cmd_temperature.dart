import '../components/ui/toast.dart';
import '../utils/sampling.dart';
import 'command_executor.dart';

/// Resolve the model's TOML-configured default temperature for the
/// active session, mirroring how `cmd_think.dart` and `cmd_model.dart`
/// look up the live `ModelConfig`. Returns `null` when the provider
/// service isn't ready, the session has no model key, or the model
/// isn't registered — the caller falls back to a generic message in
/// those edge cases rather than claiming a value we can't verify.
double? _resolveModelDefaultTemperature(CommandContext ctx) {
  if (!ctx.providerServiceReady) return null;
  final modelKey = ctx.currentSession.model;
  if (modelKey.isEmpty) return null;
  return ctx.providerService.modelByCompositeKey(modelKey)?.temperature;
}

Future<void> executeTemperature(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) return;
  final rt = ctx.runtime(ctx.currentSessionId!);

  // `/temperature` with no argument — just report the current value.
  // Shows the actual TOML-configured default from `ModelConfig`
  // when the provider service can resolve the session's model, so
  // users see "0" or whatever the model was loaded with — not just
  // an abstract "model default". When the model can't be resolved
  // (providers not loaded yet, unknown model id, etc.) we fall back
  // to the generic message rather than guessing.
  if (parts.length <= 1 || parts[1].isEmpty) {
    final current = rt.temperatureOverride;
    final modelDefault = _resolveModelDefaultTemperature(ctx);
    // Explicit `mode: ToastMode.info` — this is purely informational
    // state, not an error or a status change. Without the explicit
    // mode the toast helper auto-detects by keyword, which today
    // happens to land on `info` for these messages but is brittle
    // (any future wording tweak that picks up a `wrong`/`missing`/
    // `ready`/`done` keyword would flip it to error/status).
    if (current == null) {
      ctx.showToast(
        modelDefault != null
            ? 'Temperature: model default '
                '${formatSamplingValue(modelDefault)} '
                '(no override set)'
            : 'Temperature: model default (no override set)',
        mode: ToastMode.info,
      );
    } else {
      // With an override in effect, surface the model default too so
      // users can see what they're overriding from.
      final suffix = modelDefault != null
          ? ' (override; default '
              '${formatSamplingValue(modelDefault)})'
          : ' (override)';
      ctx.showToast(
        'Temperature: ${formatSamplingValue(current)}$suffix',
        mode: ToastMode.info,
      );
    }
    return;
  }

  final raw = parts[1];
  final parsed = double.tryParse(raw);
  if (parsed == null || parsed.isNaN || parsed.isInfinite) {
    ctx.showToast(
      'Invalid temperature: "$raw". Usage: /temperature <0.0–1.0>',
      mode: ToastMode.error,
    );
    return;
  }

  // Clamp to the user-facing range. We deliberately do NOT silently
  // fall back to the model default for out-of-range values — the
  // caller typed something, and a successful toast that says
  // "clamped from 1.5 → 1.0" tells them what happened.
  final clamped = parsed.clamp(kMinTemperature, kMaxTemperature);
  final wasClamped = clamped != parsed;

  rt.temperatureOverride = clamped;

  // Persist FIRST, then show the toast. The `await` yields to the
  // event loop, which lets pending setState calls from
  // `_sendMessage`'s `textController.clear()` (and the resulting
  // `_onTextChanged` → overlay state changes) be processed before
  // the toast is shown. If the toast fires synchronously before
  // those setStates are processed, the toast's own setState can be
  // lost — the pending rebuilds from the text-clear path end up
  // overwriting the toast's dirty flag before the frame renders.
  // Awaiting first ensures the text-clear rebuilds complete, so
  // the toast's setState lands on a stable tree and renders.
  await ctx.persistTemperature(rt);

  if (wasClamped) {
    ctx.showToast(
      'Temperature set to ${formatSamplingValue(clamped)} '
      '(clamped from ${formatSamplingValue(parsed)}; range 0.0–1.0)',
      mode: ToastMode.info,
    );
  } else {
    ctx.showToast(
      'Temperature set to ${formatSamplingValue(clamped)} '
      '(override; will apply for the session)',
      mode: ToastMode.info,
    );
  }
}

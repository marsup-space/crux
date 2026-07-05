import '../components/ui/toast.dart';
import 'command_executor.dart';

/// User-visible clamp range. Accepted LLM temperature range varies
/// per provider:
///
///   - OpenAI / OpenAI-compatible: `0.0–2.0`
///   - Anthropic / MiniMax (Anthropic-shaped): `0.0–1.0` only;
///     anything higher is a server-side 400.
///
/// We deliberately clamp at `1.0` here so the same user input
/// behaves identically regardless of which provider the active
/// session happens to use — letting the cap differ per provider
/// would mean `/temperature 1.5` works for some users and silently
/// fails for others. 0 is fully deterministic, 1 is maximum
/// creativity. Anything outside the range gets clamped and we tell
/// the user.
const double kMinTemperature = 0.0;
const double kMaxTemperature = 1.0;

/// Format a temperature for display. Toasts are short so we use up
/// to two decimals — more than enough resolution for the user to
/// notice 0.0 vs 0.7 vs 1.0.
String _formatTemperature(double value) {
  // Trims trailing zero(s) so `0.70` shows as `0.7`, while keeping
  // `0.00` as `0`. Whole numbers render without a decimal point.
  final s = value.toStringAsFixed(2);
  if (s.contains('.')) {
    var trimmed = s.replaceFirst(RegExp(r'0+$'), '');
    if (trimmed.endsWith('.')) trimmed = '${trimmed}0';
    return trimmed;
  }
  return s;
}

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
                '${_formatTemperature(modelDefault)} '
                '(no override set)'
            : 'Temperature: model default (no override set)',
        mode: ToastMode.info,
      );
    } else {
      // With an override in effect, surface the model default too so
      // users can see what they're overriding from.
      final suffix = modelDefault != null
          ? ' (override; default '
              '${_formatTemperature(modelDefault)})'
          : ' (override)';
      ctx.showToast(
        'Temperature: ${_formatTemperature(current)}$suffix',
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
  await ctx.persistTemperature(rt);

  if (wasClamped) {
    // `mode: ToastMode.info` so the confirmation reads on screen —
    // the default `status` duration of 2s is shorter than the time
    // it takes to look at the bottom of the panel for a message
    // this long. `info` defaults to 3s, which gives enough time to
    // catch the new value without dragging the toast forever.
    ctx.showToast(
      'Temperature set to ${_formatTemperature(clamped)} '
      '(clamped from ${_formatTemperature(parsed)}; range 0.0–1.0)',
      mode: ToastMode.info,
    );
  } else {
    ctx.showToast(
      'Temperature set to ${_formatTemperature(clamped)} '
      '(override; will apply for the session)',
      mode: ToastMode.info,
    );
  }
}

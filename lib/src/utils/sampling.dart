/// Sampling-knob helpers shared across the LLM call chain.
///
/// Three callers currently share these:
///
///   * `chat_turn_executor.dart` — derives `top_p` from the effective
///     temperature on every stream request.
///   * `cmd_temperature.dart` — formats the toast strings after the
///     user sets or queries an override.
///   * `chat_toolbar.dart` — renders the small "T:0.5" chip beside
///     the image modality badge when an override is in effect.
///
/// Keeping the formula and the formatter in one place avoids
/// drift between the wire-level sampling config and the on-screen
/// display.
library;

/// User-visible clamp range. Accepted LLM temperature range varies
/// per provider:
///
///   - OpenAI / OpenAI-compatible: `0.0–2.0`.
///   - Anthropic / MiniMax (Anthropic-compatible wire): `0.0–1.0`
///     only; anything higher is a server-side 400.
///
/// We deliberately clamp at `1.0` so the same user input behaves
/// identically regardless of which provider the active session
/// uses. 0 is fully deterministic, 1 is maximum creativity. Anything
/// outside the range gets clamped and we tell the user.
const double kMinTemperature = 0.0;
const double kMaxTemperature = 1.0;

/// Temperature ↔ top_p mapping. A temperature of `0.0` maps to
/// `top_p = 1.0`, and `1.0` maps to `top_p = 0.85`, linearly
/// interpolated. Both endpoints clamp the input to `[0.0, 1.0]`
/// before the linear step so an out-of-range TOML default (e.g.
/// a `0.0–2.0` OpenAI model configured at `1.5`) still produces a
/// valid `top_p` inside the API's `[0.0, 1.0]` window.
///
/// Rationale: as temperature rises, the wider distribution benefits
/// from a narrower nucleus so the model doesn't pick truly
/// low-probability tokens. The OpenAI / Anthropic APIs both accept
/// `top_p` in `[0.0, 1.0]` — verified for OpenAI (Chat
/// Completions) and Anthropic (Messages). OpenAI explicitly
/// recommends altering only one of temperature / top_p from the
/// default; pairing them via this helper keeps the relationship
/// coherent.
double topPForTemperature(double temperature) {
  final t = temperature.clamp(kMinTemperature, kMaxTemperature);
  // 1.0 - 0.15 * t is in [0.85, 1.0] for t in [0.0, 1.0]; the
  // outer clamp is defensive in case a future caller passes a
  // non-finite / unsanitized double and the math produces a value
  // outside [0.0, 1.0] (e.g. via floating-point edge cases).
  return (1.0 - 0.15 * t).clamp(kMinTemperature, kMaxTemperature);
}

/// Format a sampling value (temperature or derived top_p) for
/// display. Two-decimal precision with trailing zeros trimmed so
/// `0.70` shows as `0.7`, while keeping `0.00` as `0`. Whole
/// numbers render without a decimal point — `1.00` becomes `1`,
/// not `1.0`.
///
/// This is a pure format — it does NOT clamp `value` to
/// `[kMinTemperature, kMaxTemperature]`. The caller decides what
/// range to display: the `/temperature` clamp toast wants to show
/// the user's original input verbatim ("clamped from 1.5"), while
/// the toolbar chip wants a value that's already inside the API
/// range. Clamping at formatter level would silently rewrite the
/// "clamped from" message, hiding what the user originally typed.
String formatSamplingValue(double value) {
  var s = value.toStringAsFixed(2);
  if (!s.contains('.')) return s;
  // Strip trailing zeros after the decimal point. The regex is
  // greedy (`0+$`) so `0.30` → `0.3`, `0.50` → `0.5`, and
  // `0.05` (which has no trailing zeros) is preserved verbatim.
  s = s.replaceFirst(RegExp(r'0+$'), '');
  // Drop a dangling decimal point so whole-number values don't
  // render as `1.0` or `0.0`. Anything more compact than that
  // is just noise for a 2-decimal display.
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

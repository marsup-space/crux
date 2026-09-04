/// Terminal background-brightness detection, used to pick the default
/// light/dark theme when the user has not configured one explicitly.
///
/// Detection is intentionally heuristic and non-blocking: it only
/// inspects environment variables that are already set when the
/// process starts. We deliberately do NOT attempt OSC 10/11
/// escape-sequence round-trips at startup — those require writing to
/// the terminal and awaiting a reply, which is fragile and can stall
/// boot on terminals that don't answer.
library;

/// The detected brightness of the terminal's background.
enum TerminalBrightness { dark, light, unknown }

/// Bundled theme ids used as runtime defaults. Never written back to
/// the user's config — the default adapts each launch as the user
/// switches their terminal between light and dark profiles.
const kDefaultDarkThemeId = 'dracula';
const kDefaultLightThemeId = 'cobalt-bloom';

/// Detects the terminal background brightness from [environment]
/// (defaults to the real process environment at the call site).
///
/// Strategy, in order:
///
/// 1. `COLORFGBG` — set by many terminals (konsole, rxvt, some VTE
///    setups) as `fg;bg` and occasionally `fg;bg;extra`. The second
///    field is the background's ANSI color index:
///    - 0–6 or 8  → dark (black..cyan, plus bright-black gray)
///    - 7, 9–14, or 15 → light (white / bright variants)
///    Anything unparseable or out of range is inconclusive.
/// 2. `ITERM_PROFILE` — iTerm2 exports the profile name; many users
///    name their profiles after their brightness ("Solarized Light",
///    "dark", …). A case-insensitive "light"/"dark" substring is used
///    only when `COLORFGBG` gave no answer.
///
/// Returns [TerminalBrightness.unknown] when nothing conclusive is
/// found; callers should fall back to the dark default (historical
/// behavior).
TerminalBrightness detectTerminalBrightness(Map<String, String> environment) {
  final fromColorFgBg = _brightnessFromColorFgBg(environment['COLORFGBG']);
  if (fromColorFgBg != TerminalBrightness.unknown) return fromColorFgBg;
  return _brightnessFromItermProfile(environment['ITERM_PROFILE']);
}

/// Picks the default theme id for [environment]: the bundled light
/// theme when the terminal background looks light, the bundled dark
/// theme otherwise (including when detection is inconclusive — that
/// preserves the historical default).
///
/// This is only consulted when the user has NOT configured a theme in
/// `config.toml`; an explicit `ui.theme` always wins and this function
/// is never called for that user.
String defaultThemeIdForEnvironment(Map<String, String> environment) {
  return detectTerminalBrightness(environment) == TerminalBrightness.light
      ? kDefaultLightThemeId
      : kDefaultDarkThemeId;
}

/// Parses the `COLORFGBG` value (`fg;bg`, sometimes `fg;bg;extra`) and
/// maps the background index to a brightness.
TerminalBrightness _brightnessFromColorFgBg(String? colorFgBg) {
  if (colorFgBg == null) return TerminalBrightness.unknown;
  final parts = colorFgBg.split(';');
  if (parts.length < 2) return TerminalBrightness.unknown;
  final bg = int.tryParse(parts[1].trim());
  if (bg == null) return TerminalBrightness.unknown;
  if (bg >= 0 && bg <= 6) return TerminalBrightness.dark;
  if (bg == 8) return TerminalBrightness.dark;
  if (bg == 7 || bg == 15) return TerminalBrightness.light;
  if (bg >= 9 && bg <= 14) return TerminalBrightness.light;
  return TerminalBrightness.unknown;
}

/// Falls back to the iTerm2 profile name when it contains an obvious
/// brightness hint.
TerminalBrightness _brightnessFromItermProfile(String? profile) {
  if (profile == null) return TerminalBrightness.unknown;
  final lower = profile.toLowerCase();
  if (lower.contains('light')) return TerminalBrightness.light;
  if (lower.contains('dark')) return TerminalBrightness.dark;
  return TerminalBrightness.unknown;
}

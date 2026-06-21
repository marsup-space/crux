import 'package:nocterm/nocterm.dart';

import '../tools/shell_guard.dart' show ShellGuardSeverity;
import 'system_hint_bubble.dart';

/// Small inline bubble rendered when the shell-tool fallback guard
/// flagged a `bash`/`cmd`/`powershell` call as a bash+cat/sed/rg
/// fallback. Shown right after the matching `tool_call` bubble in
/// the chat history so the user can see at a glance which calls
/// wasted effort on shell-native operations that should have used
/// `read` / `grep` / `glob` / `code_search`.
///
/// Distinct from the *in-context* reminder that the shell tool
/// injects into the LLM's next turn (see `lib/src/tools/shell_guard.dart`).
/// That one lives only inside the wire-format request and is never
/// shown to the user; this one is a persisted, rendered UI affordance.
///
/// Three severity tiers, each with its own glyph + colour so the
/// bubble escalates visually as the streak grows:
///
///   * **mild** (1st violation) — info colour, ✦ glyph. "use `read` instead"
///   * **firm** (2nd violation) — warning colour, ✦ glyph. "switch to `read`"
///   * **reject** (3rd+ violation) — error colour, ✦ glyph. "blocked — use `read`"
///
/// Inherits the shared glyph + body + colour layout from
/// [SystemHintBubble]; this class supplies the data, the
/// severity-driven colour picker, and the data-validity guard.
class ShellGuardBubble extends SystemHintBubble {
  /// Canonical label produced by
  /// `renderShellGuardBubbleLabel(verdict)` and persisted to the
  /// DB by the chat service. Drives the rendered body verbatim.
  final String label;

  /// Severity tier — drives the bubble's colour bucket. The
  /// persisted `parallelCount` column (the multi-purpose
  /// telemetry-int used by all system-role bubbles) carries the
  /// post-call streak value (1, 2, 3, …), which the renderer
  /// could also pick the ordinal from — but the label string is
  /// the source of truth so renames don't drift between the
  /// in-context reminder and the bubble.
  final ShellGuardSeverity severity;

  /// Post-call streak value (1, 2, 3, …). Used purely for the
  /// defensive `build` guard below — the label already encodes
  /// the ordinal text.
  final int streakAfter;

  const ShellGuardBubble({
    super.key,
    required this.label,
    required this.severity,
    required this.streakAfter,
  });

  @override
  SystemHintKind get kind {
    // Three buckets, three colours:
    //   * mild  → info (neutral heads-up)
    //   * firm  → warning (yellow, drift detected)
    //   * reject → error (red, call was blocked)
    // `none` is also handled (defensive fallback to info) so
    // the getter always returns a non-null SystemHintKind even
    // if the chat service mis-persists a row.
    switch (severity) {
      case ShellGuardSeverity.mild:
        return SystemHintKind.info;
      case ShellGuardSeverity.firm:
        return SystemHintKind.warning;
      case ShellGuardSeverity.reject:
        return SystemHintKind.error;
      case ShellGuardSeverity.none:
        return SystemHintKind.info;
    }
  }

  @override
  String get body => label;

  @override
  Component build(BuildContext context) {
    // Defensive: a bubble with streak < 1 is a misconfiguration
    // at the call site (the chat service only persists this
    // bubble for a real violation, and the counter is incremented
    // before the persist call). Render nothing rather than throw
    // inside a build pass.
    if (streakAfter < 1) return const SizedBox.shrink();
    if (label.isEmpty) return const SizedBox.shrink();
    return super.build(context);
  }
}
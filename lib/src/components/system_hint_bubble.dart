import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';

/// Semantic categories for system-hint bubbles. Drives the colour
/// the bubble renders in — picked by subclass via the [SystemHintBubble.kind]
/// getter, resolved to a concrete [Color] against the active theme
/// inside the base class so subclasses never touch theme colours
/// directly.
///
/// The four values map to the four most common feedback signals a
/// chat-history bubble might want to convey:
///
///   * [success] — positive; "the agent did the right thing and you
///     saved resources" (green). General-purpose bucket for any
///     positive-feedback signal — currently used for parallel-call
///     praise, but named for the broader concept so future bubbles
///     (cache hits, prompt-cache reuse, low-cost completions) can
///     share it without renaming.
///   * [info]    — neutral; a heads-up that's neither good nor bad
///     (the theme's `info` accent, typically orange).
///   * [warning] — corrective; "drift detected, consider doing X"
///     (yellow).
///   * [error]   — failure; "something went wrong" (red).
///
/// Adding a new visual flavour to existing bubbles, or a new bubble
/// type entirely, doesn't require touching the base class — pick
/// the enum value that fits, override [SystemHintBubble.kind], and
/// the colour follows.
enum SystemHintKind { success, info, warning, error }

/// Base class for the small inline "system hint" bubbles rendered
/// in the chat history under the matching `tool_call` row.
///
/// These bubbles are persisted with non-content system roles (e.g.
/// `parallel_praise`, `single_call_reminder`) and exist purely to
/// give the user a glance-able affordance for things Crux did on
/// their behalf — saved round trips on praise rounds, drift
/// detection on reminder rounds, future signals as they're added.
/// They never carry LLM-visible content; the in-context hint lives
/// separately in the wire format.
///
/// All current and future system-hint bubbles share the same visual
/// shape: a single-line glyph + body row, padded to align with the
/// rest of the chat history, coloured by signal. The base class
/// owns that layout so subclasses only have to provide three things:
///
///   * [kind] — the [SystemHintKind] enum value, which the base
///     class resolves to a theme colour.
///   * [body] — the body text after the glyph.
///   * (optional) [glyph] — defaults to `' ⚡ '`; override only
///     when a different visual is needed.
///
/// Subclasses override [build] when they need a data-validity guard
/// (e.g. "render nothing if the count is below the gate threshold")
/// and call `super.build(context)` to produce the actual layout.
///
/// See also:
///   * `parallel_praise_bubble.dart` — positive signal (saved
///     round trips on a batched round).
///   * `single_call_reminder_bubble.dart` — corrective signal
///     (drift toward one-call-per-round serialisation).
abstract class SystemHintBubble extends StatelessComponent {
  const SystemHintBubble({super.key});

  /// The semantic category of this hint. Drives the colour.
  ///
  /// Subclasses MUST override. The base class never provides a
  /// default — leaving it abstract forces every subclass to make a
  /// deliberate choice, and means "I forgot to set the kind" is a
  /// compile-time error rather than a silent visual surprise.
  SystemHintKind get kind;

  /// The body text after the glyph.
  ///
  /// Subclasses MUST override. Most compute this from a data field
  /// (e.g. `successfulCount`, `consecutiveCount`); see the existing
  /// subclasses for the pattern.
  String get body;

  /// The glyph rendered at the start of the bubble. The leading
  /// and trailing spaces are part of the visual contract — they
  /// pad the glyph to match the bubble's column alignment in the
  /// chat history.
  ///
  /// Defaults to the lightning bolt `' ⚡ '`, which most bubbles
  /// want. Override only when a different visual fits better
  /// (e.g. a future cache-hit bubble might want a different icon).
  String get glyph => ' ⚡ ';

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final color = _resolveColor(theme, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            glyph,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: Text(body, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }

  /// Map a [SystemHintKind] to the corresponding theme colour.
  ///
  /// Kept private so adding a new enum value is a single-file
  /// change — every colour-to-bucket mapping lives in this
  /// function and nowhere else.
  static Color _resolveColor(CruxThemeData theme, SystemHintKind kind) {
    switch (kind) {
      case SystemHintKind.success:
        return theme.successColor;
      case SystemHintKind.info:
        return theme.info;
      case SystemHintKind.warning:
        return theme.warningColor;
      case SystemHintKind.error:
        return theme.errorColor;
    }
  }
}
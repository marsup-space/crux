import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../services/llm_error.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';
import 'system_hint_bubble.dart';

/// Persisted error bubble rendered at the end of a chat when the
/// last LLM turn failed. Shows [LlmError.toUserMessage] as the body
/// and — when [error.canContinue] AND [onRetry] is wired — a
/// clickable `▶ continue` affordance below the body.
///
/// Two render modes:
///
///   - **Can-continue + callback**: body message, then a separator
///     line, then the affordance. The affordance is a
///     [GestureDetector] wrapping a styled `Text`, so it picks up
///     click detection directly from nocterm without routing through
///     the chat input pipeline (which would interpret `/continue` as
///     a literal user message instead of a command).
///
///   - **Cannot continue or no callback**: body message only. The
///     user can still see the failure but isn't offered a button that
///     would obviously fail (e.g. retrying an auth error won't
///     conjure a valid API key).
///
/// The bubble inherits the standard [SystemHintBubble] glyph + colour
/// layout (`SystemHintKind.error`) so it visually aligns with the
/// other inline system-hint bubbles (`parallel_praise`,
/// `single_call_reminder`, etc.) without a custom paint path.
class ErrorBubble extends SystemHintBubble {
  /// Structured error — drives the body text, the can-continue
  /// check, and (for future detail-view affordances) the
  /// debugging fields.
  final LlmError error;

  /// Invoked when the user clicks the retry affordance. `null`
  /// disables the affordance entirely (the body still renders).
  ///
  /// The chat panel wires this to the `/continue` command flow —
  /// see `ChatHistory` and `ChatPanel` for the exact wiring.
  final VoidCallback? onRetry;

  /// Localized strings for the affordance label. Defaults to the
  /// English fallback so tests / previews without a locale still
  /// render.
  final Strings strings;

  const ErrorBubble({
    super.key,
    required this.error,
    this.onRetry,
    this.strings = kEnglishStrings,
  });

  @override
  SystemHintKind get kind => SystemHintKind.error;

  @override
  String get body => error.toUserMessage();

  @override
  Component build(BuildContext context) {
    // Defer to the standard system-hint layout for the body row.
    // The continue affordance — only when applicable — is added as a
    // second row below the body. Putting it in the same `Row`
    // would require escaping the body's `Text` widget; using a
    // second row keeps the alignment clean and makes the
    // affordance visually separable from the failure description.
    //
    // Gate on `canContinue`, not `isRetriable`: transient failures
    // AND non-failure stops (step limit reached, …) are both things
    // the user resumes with one click. Hard failures (auth, billing,
    // content policy) stay button-less — resuming cannot succeed.
    final showRetry = error.canContinue && onRetry != null;
    if (!showRetry) return super.build(context);

    final theme = CruxTheme.of(context);
    final color = theme.errorColor;
    final symbol = terminalSymbol('▶', '>');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Standard system-hint row: glyph + body in the error
          // colour.
          super.build(context),
          // Separator + continue affordance. We re-render the glyph
          // slot so the affordance column aligns with the body
          // column above (the column gutter inside `super.build`
          // is `glyph.length + 1`; matching that here keeps the
          // affordance from drifting left under the glyph column).
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(glyph, style: TextStyle(color: color)),
                Expanded(
                  child: GestureDetector(
                    onTap: onRetry,
                    child: Text(
                      '$symbol ${strings.t('error.continue')}',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

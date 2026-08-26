import 'package:nocterm/nocterm.dart';
import '../i18n/strings.dart';
import '../theme/crux_theme.dart';

/// What the user picked in one group of the `ask` form, for display
/// in [AskAnswerBubble].
class AskAnswerSelection {
  /// Group heading as the agent declared it, e.g. `modules`.
  final String group;

  /// The picked option labels (multi-select keeps pick order). Empty
  /// means the group was submitted with no selection.
  final List<String> labels;

  /// True when the source group was a checkbox (multi-select) group —
  /// the bubble renders `☑` markers instead of `◉`.
  final bool multi;

  const AskAnswerSelection({
    required this.group,
    required this.labels,
    this.multi = false,
  });
}

/// The display-friendly summary of a submitted `ask` form answer.
///
/// Produced by [AskForm] on submit and passed to the chat panel so the
/// answer can render as a dedicated bubble ([AskAnswerBubble]) instead
/// of the raw serialized prose the agent receives. Labels are what the
/// user saw on screen, so the bubble reads as a recap of their picks
/// rather than the wire format.
class AskAnswerView {
  final String prompt;
  final List<AskAnswerSelection> selections;

  /// The free-text note, already trimmed. Empty when the user left
  /// the note field blank.
  final String note;

  const AskAnswerView({
    required this.prompt,
    required this.selections,
    required this.note,
  });
}

/// Chat-log bubble for a submitted `ask` form answer. Rendered in
/// place of the normal user message in BOTH display modes:
///
///  * verbose — chat_history swaps the row's `MessageBubble` for this
///    bubble (keyed by the user message id, see
///    `SessionController.askAnswerViews`).
///  * vibe — the segment walker's user line swaps to this bubble for
///    the anchored user message, so the picks recap renders instead of
///    the raw `[group] value` prose line.
///
/// The raw serialized prose is still what goes to the agent as the
/// tool result (and what lands in the message store); this bubble is
/// purely the user-facing recap. Layout echoes the form itself — `Ask`
/// chip + prompt header, one section per group with the picked
/// options, and the note when present — but read-only, with
/// `☑`/`◉` markers showing what was picked.
class AskAnswerBubble extends StatelessComponent {
  final AskAnswerView answer;

  /// Locale-aware chrome strings. Defaulted to English.
  final Strings strings;

  const AskAnswerBubble({
    super.key,
    required this.answer,
    this.strings = kEnglishStrings,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final rows = <Component>[];

    // Header: `Ask` chip + prompt, mirroring the form's header so the
    // bubble reads as "this is the form you just answered".
    rows.add(
      Row(
        children: [
          Text(
            strings.t('ask.chip'),
            style: TextStyle(
              color: theme.buttonTextFocused,
              fontWeight: FontWeight.bold,
              backgroundColor: theme.buttonBackground,
            ),
          ),
          if (answer.prompt.isNotEmpty)
            Expanded(
              child: Text(
                ' ${answer.prompt}',
                style: TextStyle(color: theme.hintText),
              ),
            ),
        ],
      ),
    );

    // One section per group: heading, then the picked options with
    // the same markers the form uses (☑ multi / ◉ single). Groups
    // submitted with no selection show a muted "(none)" line so the
    // recap is explicit — never silently empty.
    for (final sel in answer.selections) {
      rows.add(
        Text(
          ' ${sel.group}:',
          style: TextStyle(color: theme.mdH2, fontWeight: FontWeight.bold),
        ),
      );
      if (sel.labels.isEmpty) {
        rows.add(Text('   (none)', style: TextStyle(color: theme.hintText)));
      } else {
        final marker = sel.multi ? '☑' : '◉';
        for (final label in sel.labels) {
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(' $marker ', style: TextStyle(color: theme.userPrefix)),
                Expanded(
                  child: Text(label, style: TextStyle(color: theme.foreground)),
                ),
              ],
            ),
          );
        }
      }
    }

    if (answer.note.isNotEmpty) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(' note: ', style: TextStyle(color: theme.hintText)),
            Expanded(
              child: Text(
                answer.note,
                style: TextStyle(color: theme.textMuted),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Container(
        decoration: BoxDecoration(
          color: theme.surface,
          border: BoxBorder.all(
            color: theme.outline,
            style: BoxBorderStyle.rounded,
          ),
          borderRadius: BorderRadius.circular(1),
        ),
        padding: const EdgeInsets.all(1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

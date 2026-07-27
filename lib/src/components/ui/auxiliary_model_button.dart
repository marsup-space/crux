// Unicode-width measurement (CJK, emoji) is used to truncate the
// button label to the panel width. Lives in nocterm's `lib/src/`;
// not re-exported.
// ignore_for_file: implementation_imports

import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import '../../services/auxiliary_task_tracker.dart';
import '../session_controller.dart';
import '../session_cubit.dart';
import 'glossy_model_button.dart';

/// Icon glyph for the auxiliary-model button — a right chevron.
/// Safe BMP symbol that renders as 1 cell, monochrome, in every
/// Unicode-capable terminal (previously a Nerd Font PUA codepoint,
/// which produced tofu without a Nerd Font and broke width math).
const kIconAuxiliary = '›'; // › — right chevron

/// The auxiliary-model button shared by the chat toolbar (narrow
/// terminals, no side panel) and the extra-info panel (wide
/// terminals).
///
/// Two data sources drive it:
///
///  * The aux model's short name comes from a
///    `BlocSelector<SessionCubit, String>`, so the idle label only
///    rebuilds when that one cubit field changes — every other
///    cubit mutation (session list, message cache, pending images)
///    is dropped at the selector boundary.
///  * Busy state comes from [AuxiliaryTaskTracker], the app-wide
///    registry every auxiliary task (title generation, TLDR,
///    shell risk review, shell monitoring, …) announces itself to.
///    The button listens to it directly, so ANY task — including
///    ones added in the future — animates the button and swaps the
///    label to the task's verb with zero extra wiring.
///
/// While tasks run, the label shows the most recently started
/// task's verb plus the total in-flight count when more than one
/// is running: `summarizing…`, `summarizing… +2`. The glossy sweep
/// animation runs for the whole busy period.
class AuxiliaryModelButton extends StatefulComponent {
  final SessionController sessionController;
  final VoidCallback? onPressed;

  /// When true, the idle label gets an explicit `AUX:` prefix
  /// (`AUX: model-name`) instead of the bare chevron icon
  /// (`› model-name`). The side panel sets this because the
  /// full-width button sits away from the toolbar context that
  /// hints at what the chevron means; the toolbar keeps the
  /// compact form where horizontal space is tight.
  final bool showAuxLabel;

  /// Maximum label width in terminal columns; the label is
  /// truncated with a trailing `~` when it would exceed this.
  /// The side panel passes its own width so the full-width
  /// button never overflows the panel — and the same value is
  /// forwarded as [GlossyModelButton.minWidth], so a label that
  /// SHRINKS (idle `AUX: model-name` → busy `titling…`) keeps
  /// the button at full panel width instead of collapsing to
  /// the shorter text. Null = size to label (the toolbar budgets
  /// width itself and hides the button when it doesn't fit).
  final int? maxWidth;

  const AuxiliaryModelButton({
    super.key,
    required this.sessionController,
    this.onPressed,
    this.showAuxLabel = false,
    this.maxWidth,
  });

  @override
  State<AuxiliaryModelButton> createState() => _AuxiliaryModelButtonState();
}

class _AuxiliaryModelButtonState extends State<AuxiliaryModelButton> {
  AuxiliaryTaskTracker get _tracker => AuxiliaryTaskTracker.instance;

  @override
  void initState() {
    super.initState();
    _tracker.addListener(_onTasksChanged);
  }

  @override
  void dispose() {
    _tracker.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _onTasksChanged() {
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final busy = _tracker.summary;
    return BlocSelector<SessionCubit, SessionCubitState, String>(
      selector: (state) => state.auxiliaryModelShortName,
      builder: (context, shortName) => GlossyModelButton(
        label: _fitLabel(_composeLabel(shortName, busy)),
        isAnimating: busy != null,
        onPressed: component.onPressed,
        minWidth: component.maxWidth,
      ),
    );
  }

  /// The button label. Busy: the most recently started task's verb,
  /// plus ` +N` when other tasks are in flight underneath it
  /// (`titling… +2`). Idle: `AUX: name` with
  /// [AuxiliaryModelButton.showAuxLabel], else `› name`.
  String _composeLabel(
    String shortName,
    ({AuxiliaryTaskKind kind, int count})? busy,
  ) {
    if (busy != null) {
      final extra = busy.count > 1 ? ' +${busy.count - 1}' : '';
      return '${busy.kind.verb}…$extra';
    }
    return component.showAuxLabel
        ? 'AUX: $shortName'
        : '$kIconAuxiliary $shortName';
  }

  /// Truncate [label] to [AuxiliaryModelButton.maxWidth] terminal
  /// columns, measuring by display width (not code units) so wide
  /// glyphs are accounted for. Truncation is marked with a trailing
  /// `~` and splits on grapheme clusters to avoid breaking surrogate
  /// pairs. No-op when maxWidth is null or the label already fits.
  String _fitLabel(String label) {
    final max = component.maxWidth;
    if (max == null || max <= 0) return label;
    if (UnicodeWidth.stringWidth(label) <= max) return label;
    // Reserve 1 col for the trailing '~'.
    final budget = max - 1;
    final chars = label.characters;
    var width = 0;
    var count = 0;
    for (final c in chars) {
      final cw = UnicodeWidth.stringWidth(c);
      if (width + cw > budget) break;
      width += cw;
      count++;
    }
    return '${chars.take(count)}~';
  }
}

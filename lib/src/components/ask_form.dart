import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../tools/ask_tool.dart';
import 'ui/button.dart';

/// Interactive form that replaces the chat input box when the agent
/// has called the `ask` tool. Renders one section per group with its
/// options stacked vertically (checkboxes for multi-select, radios
/// for single-select) so long option labels soft-wrap onto
/// continuation lines instead of overflowing the row, plus a
/// free-text note field, and Submit / Dismiss actions.
///
/// Focus architecture mirrors the wizard overlay's pattern: a single
/// enum tracks which region owns keyboard focus, and each region is
/// wrapped in a [Focusable] whose `focused` flag derives from that
/// enum. Only one region has focus at a time. Tab cycles forward
/// (options → note → submit → dismiss → options), Shift+Tab reverses.
/// Arrow Up/Down move within the option list; Arrow Left/Right step
/// between options with group boundaries clamped (Left past the first
/// option of a group stays put instead of jumping into the previous
/// group). Enter submits from
/// anywhere except when an option is focused (Enter toggles that
/// option). Esc dismisses from anywhere.
///
/// On submit:
///   - Selections are serialized via [serializeAskAnswer].
///   - `onSubmit(prose)` fires; the caller drives the cubit's `complete`.
///
/// On dismiss:
///   - `onDismiss()` fires; the caller drives the cubit's `dismiss`.
class AskForm extends StatefulComponent {
  final PendingAsk pending;
  final void Function(String prose) onSubmit;
  final VoidCallback onDismiss;

  const AskForm({
    super.key,
    required this.pending,
    required this.onSubmit,
    required this.onDismiss,
  });

  @override
  State<AskForm> createState() => _AskFormState();
}

/// Which region of the form owns keyboard focus.
enum _AskFocusRegion { options, note, submit, dismiss }

class _AskFormState extends State<AskForm> {
  /// Selections keyed by group name. For single-select groups the
  /// list holds at most one option; for multi-select it holds the
  /// picked options in the order they were chosen.
  final Map<String, List<AskOption>> _selections = {};

  final TextEditingController _noteController = TextEditingController();

  _AskFocusRegion _focusRegion = _AskFocusRegion.options;

  /// Flat index into the option grid — group-major, option-minor.
  /// `-1` means "no option focused" (valid when region is note/
  /// submit/dismiss).
  int _focusedOptionIndex = 0;

  late final List<({AskGroup group, AskOption option})> _flatOptions;

  @override
  void initState() {
    super.initState();
    _flatOptions = [
      for (final g in component.pending.spec.groups)
        for (final o in g.options) (group: g, option: o),
    ];
    // Default selection: first option of every single-select group.
    // Multi-select groups start empty (the user must opt in).
    for (final g in component.pending.spec.groups) {
      if (!g.multi && g.options.isNotEmpty) {
        _selections[g.name] = [g.options.first];
      }
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool _isPicked(AskGroup group, AskOption option) {
    final picks = _selections[group.name];
    return picks != null && picks.any((o) => o.value == option.value);
  }

  void _toggle(AskGroup group, AskOption option) {
    final picks = _selections[group.name] ?? <AskOption>[];
    if (group.multi) {
      final exists = picks.any((o) => o.value == option.value);
      if (exists) {
        _selections[group.name] =
            picks.where((o) => o.value != option.value).toList();
      } else {
        _selections[group.name] = [...picks, option];
      }
    } else {
      // Single-select: replacing, not appending.
      _selections[group.name] = [option];
    }
    setState(() {});
  }

  void _moveOption(int delta) {
    if (_flatOptions.isEmpty) return;
    final next = (_focusedOptionIndex + delta) % _flatOptions.length;
    _focusedOptionIndex = next < 0 ? next + _flatOptions.length : next;
    setState(() {});
  }

  /// Arrow Left/Right step one option at a time, but clamp at group
  /// boundaries — the options are rendered one per line grouped by
  /// section, so jumping sideways into a different group feels wrong.
  void _moveOptionHorizontal(int delta) {
    if (_flatOptions.isEmpty) return;
    final next = _focusedOptionIndex + delta;
    if (next < 0 || next >= _flatOptions.length) return;
    if (_flatOptions[next].group.name !=
        _flatOptions[_focusedOptionIndex].group.name) {
      return;
    }
    _focusedOptionIndex = next;
    setState(() {});
  }

  void _cycleRegion(bool forward) {
    final order = const [
      _AskFocusRegion.options,
      _AskFocusRegion.note,
      _AskFocusRegion.submit,
      _AskFocusRegion.dismiss,
    ];
    final idx = order.indexOf(_focusRegion);
    final nextIdx = forward
        ? (idx + 1) % order.length
        : (idx - 1 + order.length) % order.length;
    _focusRegion = order[nextIdx];
    setState(() {});
  }

  void _doSubmit() {
    final prose = serializeAskAnswer(
      component.pending.spec,
      _selections,
      _noteController.text,
    );
    component.onSubmit(prose);
  }

  bool _handleOptionKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKey.tab) {
      _cycleRegion(!event.isShiftPressed);
      return true;
    }
    if (key == LogicalKey.enter || key == LogicalKey.space) {
      if (_flatOptions.isEmpty) {
        _cycleRegion(true);
        return true;
      }
      final entry = _flatOptions[_focusedOptionIndex];
      // Enter on a single-select option submits the whole form (matches
      // "Enter to confirm" muscle memory). Space toggles in place.
      if (key == LogicalKey.enter && !entry.group.multi) {
        _selections[entry.group.name] = [entry.option];
        setState(() {});
        _doSubmit();
        return true;
      }
      _toggle(entry.group, entry.option);
      return true;
    }
    if (key == LogicalKey.arrowUp) {
      _moveOption(-1);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      _moveOption(1);
      return true;
    }
    if (key == LogicalKey.arrowLeft) {
      _moveOptionHorizontal(-1);
      return true;
    }
    if (key == LogicalKey.arrowRight) {
      _moveOptionHorizontal(1);
      return true;
    }
    if (key == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    return false;
  }

  bool _handleNoteKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    if (key == LogicalKey.tab) {
      _cycleRegion(!event.isShiftPressed);
      return true;
    }
    // Enter on the note field submits — matches chat-input muscle memory.
    // Shift+Enter inserts a newline for multi-line notes.
    if (key == LogicalKey.enter) {
      if (event.isShiftPressed) return false; // let TextField handle it
      _doSubmit();
      return true;
    }
    return false;
  }

  bool _handleActionKey(_AskFocusRegion region, KeyboardEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKey.tab) {
      _cycleRegion(!event.isShiftPressed);
      return true;
    }
    if (key == LogicalKey.enter || key == LogicalKey.space) {
      if (region == _AskFocusRegion.submit) {
        _doSubmit();
      } else {
        component.onDismiss();
      }
      return true;
    }
    if (key == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    // Arrow keys bounce back to the option grid.
    if (key == LogicalKey.arrowUp || key == LogicalKey.arrowDown) {
      _focusRegion = _AskFocusRegion.options;
      if (key == LogicalKey.arrowDown) _moveOption(1);
      if (key == LogicalKey.arrowUp) _moveOption(-1);
      setState(() {});
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final spec = component.pending.spec;

    final rows = <Component>[];

    // Header: prompt
    rows.add(
      Row(
        children: [
          Text(
            ' Ask ',
            style: TextStyle(
              color: theme.buttonTextFocused,
              fontWeight: FontWeight.bold,
              backgroundColor: theme.buttonBackground,
            ),
          ),
          if (spec.prompt.isNotEmpty)
            Expanded(
              child: Text(
                ' ${spec.prompt}',
                style: TextStyle(color: theme.foreground),
              ),
            ),
        ],
      ),
    );

    rows.add(Divider(color: theme.outline, height: 1));

    // Option groups region — wrapped in its own Focusable so the
    // terminal's "find focused text field" walk only descends into
    // the note field when the note region is the active focus. This
    // is the root fix for the cursor-blinking-on-options bug: when
    // the options region is focused, the note TextField is NOT under
    // the active Focusable subtree, so nocterm's IME cursor stays
    // hidden.
    rows.add(
      Focusable(
        focused: _focusRegion == _AskFocusRegion.options,
        onKeyEvent: _handleOptionKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in spec.groups) ...[
              Text(
                ' ${group.name}${group.multi ? ' (multi)' : ''}:',
                style: TextStyle(
                  color: theme.mdH2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              ..._buildOptionRows(group, theme),
            ],
          ],
        ),
      ),
    );

    // Note field region — when focused, the TextField's own internal
    // Focusable becomes active (because we pass `focused: true`
    // through) and nocterm shows the IME cursor. When the options
    // region is focused, this region is NOT under the active subtree,
    // so the cursor stays hidden and arrow-key navigation doesn't
    // flash a cursor.
    rows.add(
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Row(
          children: [
            Text(
              ' Notes: ',
              style: TextStyle(color: theme.hintText),
            ),
            Expanded(
              child: _NoteRegion(
                active: _focusRegion == _AskFocusRegion.note,
                controller: _noteController,
                onKeyEvent: _handleNoteKey,
              ),
            ),
          ],
        ),
      ),
    );

    // Action row — Submit and Dismiss grouped on the right, both as
    // proper Button instances so they pick up the theme's button
    // affordance. The Esc hint sits to the left.
    rows.add(
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(' Esc: dismiss ', style: TextStyle(color: theme.hintText)),
            Row(
              children: [
                Text('Tab: switch region  ', style: TextStyle(color: theme.hintText)),
                _ActionButton(
                  label: 'Submit',
                  focused: _focusRegion == _AskFocusRegion.submit,
                  onPressed: _doSubmit,
                  onKeyEvent: (e) =>
                      _handleActionKey(_AskFocusRegion.submit, e),
                  primary: true,
                ),
                const SizedBox(width: 1),
                _ActionButton(
                  label: 'Dismiss',
                  focused: _focusRegion == _AskFocusRegion.dismiss,
                  onPressed: component.onDismiss,
                  onKeyEvent: (e) =>
                      _handleActionKey(_AskFocusRegion.dismiss, e),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Container(
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
    );
  }

  /// One full-width row per option. The option text gets the
  /// remaining width via [Expanded] so nocterm's paragraph layout
  /// soft-wraps long labels onto continuation lines instead of
  /// letting the row overflow horizontally. Continuation lines are
  /// padded to line up under the label start (after the marker).
  List<Component> _buildOptionRows(AskGroup group, CruxThemeData theme) {
    final rows = <Component>[];
    for (final option in group.options) {
      final flatIdx = _flatOptionFlatIndex(group, option);
      final isFocused = _focusRegion == _AskFocusRegion.options &&
          flatIdx == _focusedOptionIndex;
      final isPicked = _isPicked(group, option);
      final marker = group.multi
          ? (isPicked ? '☑' : '☐')
          : (isPicked ? '◉' : '○');

      final cellColor = isFocused
          ? theme.buttonBackgroundFocused
          : (isPicked ? theme.buttonBackgroundHover : theme.buttonBackground);
      final textColor = isFocused
          ? theme.buttonTextFocused
          : (isPicked ? theme.buttonTextHover : theme.buttonText);

      rows.add(
        GestureDetector(
          onTap: () {
            _focusedOptionIndex = flatIdx;
            _focusRegion = _AskFocusRegion.options;
            _toggle(group, option);
          },
          behavior: HitTestBehavior.opaque,
          child: MouseRegion(
            opaque: false,
            onHover: (_) {
              if (_focusedOptionIndex != flatIdx ||
                  _focusRegion != _AskFocusRegion.options) {
                setState(() {
                  _focusedOptionIndex = flatIdx;
                  _focusRegion = _AskFocusRegion.options;
                });
              }
            },
            child: Container(
              decoration: BoxDecoration(color: cellColor),
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$marker ', style: TextStyle(color: textColor)),
                  Expanded(
                    child: Text(
                      option.label,
                      style: TextStyle(color: textColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return rows;
  }

  int _flatOptionFlatIndex(AskGroup group, AskOption option) {
    var idx = 0;
    for (final entry in _flatOptions) {
      if (entry.group.name == group.name && entry.option.value == option.value) {
        return idx;
      }
      idx++;
    }
    return 0;
  }
}

/// Wrapper around the note [TextField] that only mounts its child when
/// active. The point is to keep the TextField's render object OFF the
/// focused subtree when the options or buttons are focused, so
/// nocterm's "find focused render text field" walk
/// ([_findFocusedRenderTextField] in terminal_binding.dart) returns
/// null and the terminal hardware cursor stays hidden.
///
/// When active, we render the TextField with `focused: true`, which
/// propagates to its internal Focusable; nocterm then positions and
/// shows the cursor — keyboard input also lands here. When inactive,
/// we render a static, non-interactive placeholder so the layout
/// stays stable across focus transitions.
class _NoteRegion extends StatefulComponent {
  final bool active;
  final TextEditingController controller;
  final bool Function(KeyboardEvent) onKeyEvent;

  const _NoteRegion({
    required this.active,
    required this.controller,
    required this.onKeyEvent,
  });

  @override
  State<_NoteRegion> createState() => _NoteRegionState();
}

class _NoteRegionState extends State<_NoteRegion> {
  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    // The decoration border swaps to the theme's focus color when
    // active so the user gets a visual signal of where keyboard
    // input is going, mirroring the radio/checkbox focus highlight.
    final borderColor = component.active
        ? theme.buttonTextFocused
        : theme.outline;
    return TextField(
      controller: component.controller,
      focused: component.active,
      maxLines: 2,
      minLines: 1,
      placeholder: '(optional) add extra context for the agent',
      style: TextStyle(color: theme.foreground),
      decoration: InputDecoration(
        border: BoxBorder.all(color: borderColor),
        focusedBorder: BoxBorder.all(color: borderColor),
      ),
      onKeyEvent: component.onKeyEvent,
    );
  }
}

/// A focusable action button. Wraps [Button] in a [Focusable] so the
/// action can be reached via Tab and activated via Enter/Space.
/// `primary: true` swaps to the theme's accent background (Submit vs
/// Dismiss contrast).
class _ActionButton extends StatelessComponent {
  final String label;
  final bool focused;
  final VoidCallback onPressed;
  final bool Function(KeyboardEvent) onKeyEvent;
  final bool primary;

  const _ActionButton({
    required this.label,
    required this.focused,
    required this.onPressed,
    required this.onKeyEvent,
    this.primary = false,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Focusable(
      focused: focused,
      onKeyEvent: onKeyEvent,
      child: Button(
        label: focused ? '▸ $label ◂' : ' $label ',
        onPressed: onPressed,
        focused: focused,
        color: focused
            ? theme.buttonTextFocused
            : (primary ? theme.buttonText : theme.buttonText),
        bgColor: focused
            ? theme.buttonBackgroundFocused
            : theme.buttonBackground,
        hoverColor: theme.buttonTextFocused,
        hoverBgColor: theme.buttonBackgroundHover,
      ),
    );
  }
}

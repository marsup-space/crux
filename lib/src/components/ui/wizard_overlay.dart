import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';
import '../../utils/terminal_symbols.dart';
import 'button.dart';

/// Index constants for footer button focus tracking.
///
/// Used by [WizardStep.footerFocusIndex] to tell the overlay which
/// footer navigation button is currently keyboard-focused.
///
/// - **-1**: No footer button focused (focus is on step content or a TextField).
/// - **0**: Back button focused.
/// - **1**: Next/Confirm button focused.
/// - **2**: Cancel button focused.
///
/// On the first step, the Back button is hidden, so index 0 is
/// invalid — the focus cycle skips it.
class FooterFocus {
  static const int none = -1;
  static const int back = 0;
  static const int next = 1;
  static const int cancel = 2;
}

/// Controls a [WizardOverlay] from outside the widget tree.
///
/// Provides methods for navigation ([next], [back], [cancel]),
/// key event handling for [TextField]s ([handleFieldKeyEvent]),
/// and a way for step content to request an overlay rebuild
/// ([requestRebuild]).
///
/// A controller can be passed to [WizardOverlay.controller] or the
/// overlay will create an internal one automatically.
class WizardController {
  _WizardOverlayState? _state;
  VoidCallback? _markNeedsBuild;

  /// The current step index (0-based).
  int get currentStep => _state?._currentStep ?? 0;

  /// Total number of steps in the wizard.
  int get totalSteps => _state?.component.steps.length ?? 0;

  /// Whether the wizard is on the first step.
  bool get isFirstStep => currentStep == 0;

  /// Whether the wizard is on the last step.
  bool get isLastStep => currentStep == totalSteps - 1 && totalSteps > 0;

  /// Whether the current step passes validation.
  bool get isCurrentStepValid {
    final state = _state;
    if (state == null) return false;
    return state.component.steps[state._currentStep].validate();
  }

  /// Advance to the next step, or call [onComplete] if on the last step.
  ///
  /// Only advances if the current step passes validation.
  void next() {
    final state = _state;
    if (state == null) return;
    final step = state.component.steps[state._currentStep];
    if (!step.validate()) return;
    if (state._currentStep < state.component.steps.length - 1) {
      state._currentStep++;
      state.component.onStepChanged?.call(state._currentStep);
      _markNeedsBuild?.call();
    } else {
      state.component.onComplete();
    }
  }

  /// Go back to the previous step.
  ///
  /// Does nothing if on the first step.
  void back() {
    final state = _state;
    if (state == null) return;
    if (state._currentStep > 0) {
      state._currentStep--;
      state.component.onStepChanged?.call(state._currentStep);
      _markNeedsBuild?.call();
    }
  }

  /// Cancel the wizard, calling the [onCancel] callback.
  void cancel() {
    final state = _state;
    if (state == null) return;
    state.component.onCancel();
  }

  /// Request a rebuild of the wizard overlay.
  ///
  /// Step content should call this when changing focus areas (including
  /// footer button focus) so the overlay can update button highlights
  /// and Focusable `focused` states.
  void requestRebuild() {
    _markNeedsBuild?.call();
  }

  /// Key event handler for [TextField]s inside wizard panels.
  ///
  /// Intercepts the following keys:
  /// - **Enter** → calls [next] (advance / confirm)
  /// - **Escape** → calls [cancel]
  /// - **Ctrl+B** or **Alt+LeftArrow** → calls [back]
  ///
  /// All other keys pass through to the [TextField] for normal
  /// processing (typing, backspace, arrows, etc.).
  ///
  /// **Every** [TextField] inside a wizard panel should set this
  /// (or a step-specific equivalent) as its `onKeyEvent`.
  bool handleFieldKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      cancel();
      return true;
    }
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      back();
      return true;
    }
    return false;
  }

  /// Called by [WizardOverlay] state when it initializes.
  void _attach(_WizardOverlayState state) {
    _state = state;
    _markNeedsBuild = state._markNeedsBuild;
  }

  /// Called by [WizardOverlay] state when it disposes.
  void _detach() {
    _state = null;
    _markNeedsBuild = null;
  }
}

/// A single step within a [WizardOverlay].
///
/// Each step has a title, content builder, validation function,
/// and optional callbacks for key event handling and focus tracking.
///
/// ### Focus management (nocterm focus_demo pattern)
///
/// The wizard overlay uses the canonical nocterm focus pattern from
/// `focus_demo.dart`: two sibling [Focusable]s (step content and
/// footer) plus [TextField] Focusables, with only ONE having
/// `focused: true` at a time.
///
/// The focus state is managed by the wizard panel's state class
/// (e.g. `_ProviderWizardAddState`) via a single focus area enum
/// that includes ALL focusable elements: input fields, toggle
/// buttons, and footer buttons. The overlay reads this state
/// through [WizardStep] callbacks to determine which [Focusable]
/// should be `focused: true`.
///
/// Three focus states:
/// 1. **TextField focused** — a TextField within the step content
///    has `focused: true`. Neither overlay Focusable is focused.
///    The TextField's `onKeyEvent` handles all keys.
/// 2. **Step content focused** — a non-TextField area within the
///    step (toggle button, list, etc.) has focus. The step content
///    [Focusable] has `focused: true`. Its `onKeyEvent` delegates
///    to [onKeyEvent].
/// 3. **Footer focused** — a footer button has focus. The footer
///    [Focusable] has `focused: true`. Its `onKeyEvent` delegates
///    to [onFooterKeyEvent].
///
/// Steps with input fields must provide [stepContentFocused],
/// [footerFocusIndex], and [onFooterKeyEvent]. Steps without
/// input fields can omit these — defaults work correctly.
class WizardStep {
  /// The title displayed in the wizard header.
  final String title;

  /// Builds the content component for this step's body area.
  final Component Function() contentBuilder;

  /// Validates whether this step's inputs are sufficient to proceed.
  /// Defaults to always returning `true` if not explicitly provided.
  final bool Function() validate;

  /// Whether this step represents a final review or confirmation step.
  final bool isComplete;

  /// Optional key event handler for the step content [Focusable].
  ///
  /// Called when the step content Focusable receives a key event
  /// (i.e., when focus is on a non-TextField area within the step).
  /// Should return `true` if the key was consumed.
  ///
  /// The overlay handles Enter/Escape/Ctrl+B as navigation defaults
  /// if this handler returns `false` (or is null).
  ///
  /// For selection-list steps, handle arrow up/down for list navigation.
  /// For steps with toggle buttons, handle Space to activate them.
  final bool Function(KeyboardEvent event)? onKeyEvent;

  /// Returns whether the step content [Focusable] should be focused.
  ///
  /// When `true`, the step content Focusable has `focused: true` and
  /// receives key events. When `false`, focus is on a [TextField]
  /// within the step or on the footer.
  ///
  /// **Steps with [TextField]s must provide this**, returning `true`
  /// only when focus is on a non-TextField area (toggle button, list)
  /// and `false` when focus is on a TextField or footer button.
  ///
  /// **Steps without [TextField]s** can omit this — defaults to `true`.
  final bool Function()? stepContentFocused;

  /// Returns the index of the currently keyboard-focused footer button.
  ///
  /// Uses [FooterFocus] constants:
  /// - `FooterFocus.none` (-1): no footer button focused
  /// - `FooterFocus.back` (0): Back button focused
  /// - `FooterFocus.next` (1): Next/Confirm button focused
  /// - `FooterFocus.cancel` (2): Cancel button focused
  ///
  /// When this returns a value other than [FooterFocus.none], the
  /// footer [Focusable] has `focused: true` and buttons are visually
  /// highlighted with `▸ ◂` markers and bright cyan color.
  ///
  /// **Must be provided alongside [onFooterKeyEvent]** for steps that
  /// support Tab navigation to footer buttons.
  final int Function()? footerFocusIndex;

  /// Optional key event handler for the footer [Focusable].
  ///
  /// Called when the footer Focusable receives a key event while a
  /// footer button is focused. Handles:
  /// - Arrow keys / Tab to cycle between footer buttons
  /// - Enter to activate the focused footer button (calls
  ///   [WizardController.back]/[next]/[cancel] as appropriate)
  /// - Tab / Shift+Tab to shift focus back to step content
  ///   (updates the wizard state's internal focus area and calls
  ///   [WizardController.requestRebuild])
  /// - Escape to cancel
  ///
  /// **Must be provided alongside [footerFocusIndex]** for steps that
  /// support keyboard navigation of footer buttons.
  final bool Function(KeyboardEvent event)? onFooterKeyEvent;

  /// Creates a wizard step.
  WizardStep({
    required this.title,
    required this.contentBuilder,
    bool Function()? validate,
    this.isComplete = false,
    this.onKeyEvent,
    this.stepContentFocused,
    this.footerFocusIndex,
    this.onFooterKeyEvent,
  }) : validate = validate ?? _defaultValidate;

  static bool _defaultValidate() => true;
}

/// A step-by-step wizard overlay with navigation, progress tracking,
/// and per-step validation.
///
/// ### Focus architecture (nocterm focus_demo pattern)
///
/// The overlay uses two sibling [Focusable]s, following the canonical
/// nocterm pattern from `focus_demo.dart`:
///
/// 1. **Step content Focusable** — `focused: true` when keyboard focus
///    is on a non-TextField area within the step. Its `onKeyEvent`
///    delegates to [WizardStep.onKeyEvent], with Enter/Escape/Ctrl+B
///    defaults for unhandled keys.
///
/// 2. **Footer Focusable** — `focused: true` when a footer navigation
///    button is keyboard-focused. Its `onKeyEvent` delegates to
///    [WizardStep.onFooterKeyEvent], with Enter/Escape defaults.
///
/// 3. **TextField Focusables** — when focus is on a [TextField] within
///    the step content, the TextField's own Focusable has `focused: true`
///    and **neither** overlay Focusable is focused. The TextField's
///    `onKeyEvent` handles all keys (including Tab/Shift+Tab/arrows
///    for focus traversal between fields and to the footer).
///
/// Only ONE Focusable has `focused: true` at a time, matching the
/// `focus_demo.dart` pattern where `focusedArea == FocusArea.xxx`
/// drives all Focusable `focused` values.
///
/// Focus shifts between areas via Tab/arrow keys, managed by each
/// Focusable's `onKeyEvent`. The wizard panel's state class holds a
/// single focus area enum that covers ALL focusable elements (input
/// fields, toggle buttons, footer buttons), enabling a unified cycle
/// where Tab/Shift+Tab/arrows traverse every interactive element.
///
/// When focus changes, the wizard state calls `setState()` and
/// [WizardController.requestRebuild] so both the wizard state and
/// overlay state rebuild, updating Focusable `focused` values and
/// button highlighting.
class WizardOverlay extends StatefulComponent {
  /// The steps to display in this wizard, in order.
  final List<WizardStep> steps;

  /// Called when the user confirms the last step.
  final VoidCallback onComplete;

  /// Called when the user cancels the wizard (Escape or Cancel button).
  final VoidCallback onCancel;

  /// Called when the wizard transitions to a different step.
  ///
  /// The callback receives the new step index (0-based). Parent wizard
  /// states should use this to reset their focus area variables to
  /// sensible defaults for the new step (e.g., first input field).
  ///
  /// Not called when `next()` triggers `onComplete` (last step) or
  /// when `back()` does nothing (first step).
  final ValueChanged<int>? onStepChanged;

  /// Optional external controller for navigation.
  /// If not provided, an internal controller is created.
  final WizardController? controller;

  const WizardOverlay({
    super.key,
    required this.steps,
    required this.onComplete,
    required this.onCancel,
    this.onStepChanged,
    this.controller,
  });

  @override
  State<WizardOverlay> createState() => _WizardOverlayState();
}

class _WizardOverlayState extends State<WizardOverlay> {
  int _currentStep = 0;

  /// Callback that triggers a rebuild of this state's component.
  /// Exposed so [WizardController] can mark the state as needing
  /// rebuild without calling the protected [setState] method.
  VoidCallback get _markNeedsBuild =>
      () => setState(() {});

  /// Internal controller created when none is provided externally.
  late final WizardController _internalController = WizardController();

  /// The effective controller (external if provided, internal otherwise).
  WizardController get _effectiveController =>
      component.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    _effectiveController._attach(this);
  }

  @override
  void didUpdateComponent(WizardOverlay oldComponent) {
    super.didUpdateComponent(oldComponent);
    final oldController = oldComponent.controller ?? _internalController;
    final newController = _effectiveController;
    if (oldController != newController) {
      oldController._detach();
      newController._attach(this);
    }
  }

  @override
  void dispose() {
    _effectiveController._detach();
    super.dispose();
  }

  /// Advances to the next step if validation passes, or calls
  /// [onComplete] if already on the last step.
  void _goNext() => _effectiveController.next();

  /// Moves back to the previous step, if not on the first step.
  void _goBack() => _effectiveController.back();

  @override
  Component build(BuildContext context) {
    final wizard = component;
    final steps = wizard.steps;
    final step = steps[_currentStep];
    final isLastStep = _currentStep == steps.length - 1;
    final isFirstStep = _currentStep == 0;
    final isValid = step.validate();

    // ── Step indicator dots ──
    // ● = active, ◉ = completed/past, ○ = future
    final indicators = <Component>[];
    for (int i = 0; i < steps.length; i++) {
      final isActive = i == _currentStep;
      final isPast = i < _currentStep;
      final dotColor = isActive
          ? CruxTheme.of(context).buttonTextFocused
          : isPast
          ? CruxTheme.of(context).wizardTitle
          : CruxTheme.of(context).wizardTextDim;
      final dotChar = isActive
          ? terminalSymbol('●', '*')
          : isPast
          ? terminalSymbol('◉', '+')
          : terminalSymbol('○', '.');
      indicators.add(Text(dotChar, style: TextStyle(color: dotColor)));
      if (i < steps.length - 1) {
        indicators.add(
          Text(
            '─',
            style: TextStyle(
              color: isPast
                  ? CruxTheme.of(context).wizardTitle
                  : CruxTheme.of(context).wizardTextDim,
            ),
          ),
        );
      }
    }

    // ── Footer: buttons with shortcut hints aligned below ──
    final focusedBtnColor = CruxTheme.of(context).buttonTextFocused;
    final focusedBtnBgColor = CruxTheme.of(context).buttonBackgroundFocused;
    final shortcutStyle = TextStyle(color: CruxTheme.of(context).hintText);

    // ── Build the wizard layout ──
    // Two sibling Focusables following nocterm's focus_demo pattern:
    // only ONE has focused: true at a time.
    //
    // When focus is on a TextField within the step content,
    // neither Focusable has focused: true — the TextField's
    // own Focusable handles key events.
    //
    // The step content Focusable is inside Expanded so the Column
    // allocates remaining space correctly (Expanded must be a
    // direct child of Column/Flex).
    return Container(
      decoration: BoxDecoration(
        color: CruxTheme.of(context).wizardOverlayBg,
        border: BoxBorder(
          top: BorderSide(color: CruxTheme.of(context).outline),
          right: BorderSide(color: CruxTheme.of(context).outline),
          bottom: BorderSide(color: CruxTheme.of(context).outline),
          left: BorderSide(color: CruxTheme.of(context).outline),
        ),
      ),
      padding: const EdgeInsets.all(1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header area (not focusable) ──
          Row(
            children: [
              Text(
                'Step ${_currentStep + 1}/${steps.length}: ',
                style: TextStyle(color: CruxTheme.of(context).wizardTextDim),
              ),
              Text(
                step.title,
                style: TextStyle(
                  color: CruxTheme.of(context).wizardTitle,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(children: indicators),
          Divider(color: CruxTheme.of(context).outline, height: 1),

          Expanded(child: step.contentBuilder()),

          Divider(color: CruxTheme.of(context).outline, height: 1),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (!isFirstStep)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Focusable(
                      onKeyEvent: (event) {
                        if (event.logicalKey == LogicalKey.enter) {
                          _goBack();
                          return true;
                        }
                        if (event.logicalKey == LogicalKey.escape) {
                          _effectiveController.cancel();
                          return true;
                        }
                        return false;
                      },
                      child: Builder(
                        builder: (context) {
                          final focused = Focus.of(context);
                          return Button(
                            label: focused
                                ? '${terminalSymbol('▸', '>')} Back ${terminalSymbol('◂', '<')}'
                                : ' Back ',
                            onPressed: _goBack,
                            focused: focused,
                            color: focused
                                ? focusedBtnColor
                                : CruxTheme.of(context).foreground,
                            hoverColor: CruxTheme.of(context).buttonTextFocused,
                            bgColor: focused
                                ? focusedBtnBgColor
                                : CruxTheme.of(context).buttonBackground,
                            hoverBgColor: CruxTheme.of(
                              context,
                            ).buttonBackgroundHover,
                          );
                        },
                      ),
                    ),
                    Text('Ctrl+B', style: shortcutStyle),
                  ],
                )
              else
                const SizedBox(width: 0),

              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Focusable(
                        onKeyEvent: (event) {
                          if (event.logicalKey == LogicalKey.enter && isValid) {
                            _goNext();
                            return true;
                          }
                          if (event.logicalKey == LogicalKey.escape) {
                            _effectiveController.cancel();
                            return true;
                          }
                          return false;
                        },
                        child: Builder(
                          builder: (context) {
                            final focused = Focus.of(context);
                            return Button(
                              label: focused
                                  ? (isLastStep
                                        ? '${terminalSymbol('▸', '>')} Confirm ${terminalSymbol('◂', '<')}'
                                        : '${terminalSymbol('▸', '>')} Next ${terminalSymbol('◂', '<')}')
                                  : (isLastStep ? ' Confirm ' : ' Next '),
                              onPressed: isValid ? _goNext : null,
                              focused: focused,
                              color: focused
                                  ? focusedBtnColor
                                  : isValid
                                  ? CruxTheme.of(context).buttonTextFocused
                                  : CruxTheme.of(context).wizardTextDim,
                              hoverColor: isValid
                                  ? CruxTheme.of(context).buttonTextFocused
                                  : CruxTheme.of(context).wizardTextDim,
                              bgColor: focused
                                  ? focusedBtnBgColor
                                  : isValid
                                  ? CruxTheme.of(context).buttonBackground
                                  : CruxTheme.of(context).wizardOverlayBg,
                              hoverBgColor: isValid
                                  ? CruxTheme.of(context).buttonBackgroundHover
                                  : CruxTheme.of(context).wizardOverlayBg,
                            );
                          },
                        ),
                      ),
                      Text('Enter', style: shortcutStyle),
                    ],
                  ),
                  const SizedBox(width: 2),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Focusable(
                        onKeyEvent: (event) {
                          if (event.logicalKey == LogicalKey.enter) {
                            _effectiveController.cancel();
                            return true;
                          }
                          if (event.logicalKey == LogicalKey.escape) {
                            _effectiveController.cancel();
                            return true;
                          }
                          return false;
                        },
                        child: Builder(
                          builder: (context) {
                            final focused = Focus.of(context);
                            return Button(
                              label: focused
                                  ? '${terminalSymbol('▸', '>')} Cancel ${terminalSymbol('◂', '<')}'
                                  : ' Cancel ',
                              onPressed: wizard.onCancel,
                              focused: focused,
                              color: focused
                                  ? focusedBtnColor
                                  : CruxTheme.of(context).wizardTextDim,
                              hoverColor: CruxTheme.of(
                                context,
                              ).wizardMarkerSelected,
                              bgColor: focused
                                  ? focusedBtnBgColor
                                  : CruxTheme.of(context).buttonBackground,
                              hoverBgColor: CruxTheme.of(
                                context,
                              ).buttonBackgroundHover,
                            );
                          },
                        ),
                      ),
                      Text('Esc', style: shortcutStyle),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A2UI interactive catalog items for Crux.
///
/// These items support two-way data binding (CheckBox, TextField, ChoicePicker)
/// and/or action dispatch (Button). They follow the A2UI basic catalog
/// semantics as implemented in the Flutter GenUI SDK.
library;

import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../theme/crux_theme.dart';
import 'basic_catalog_items.dart' show resolveString;
import 'models.dart';
import 'surface_catalog.dart';

// ---------------------------------------------------------------------------
// Button
// ---------------------------------------------------------------------------

/// A2UI `Button` component — a clickable button that dispatches an action.
///
/// Properties:
/// - `child` (string, required): ID of the child component (usually a Text).
/// - `action` (object, required): `{"event": {"name": ..., "context": {...}}}`.
/// - `variant` (string, optional): `'primary'` or `'borderless'`.
class ButtonCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Button';

  @override
  String get description =>
      'A clickable button that dispatches an action when pressed.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'child': {
      'type': 'string',
      'description': 'The ID of a child component (usually a Text).',
    },
    'action': {
      'type': 'object',
      'description':
          'The action to perform when pressed. '
          'Format: {"event": {"name": "action_name", "context": {...}}}',
    },
    'variant': {
      'type': 'string',
      'enum': ['primary', 'bordered', 'borderless'],
      'description':
          'Button style. All variants render borderless (chip style, same '
          'size as ChoicePicker inline tags); they differ by background: '
          'borderless/bordered (default): subtle surfaceVariant fill. '
          'primary: solid accent fill + bold text (the main action pops).',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final theme = CruxTheme.of(context);
    final childId = component.properties['child'];
    final actionData = component.properties['action'];
    final variant = component.properties['variant'] as String? ?? '';

    // Build the child label component.
    Component child = const SizedBox();
    if (childId is String && childId.isNotEmpty) {
      child = buildChild(childId);
    }

    // Parse the action declaration.
    String actionName = '';
    Map<String, dynamic> actionContext = const {};
    if (actionData is Map<String, dynamic>) {
      final event = actionData['event'];
      if (event is Map<String, dynamic>) {
        actionName = event['name'] as String? ?? '';
        final ctx = event['context'];
        if (ctx is Map<String, dynamic>) actionContext = ctx;
      }
    }

    final isPrimary = variant == 'primary';
    final isDisabled = submitted || onAction == null;

    return _SurfaceButton(
      actionName: actionName,
      actionContext: actionContext,
      surfaceId: component.id,
      sourceComponentId: component.id,
      onAction: isDisabled ? null : onAction,
      isPrimary: isPrimary,
      isDisabled: isDisabled,
      variant: variant,
      theme: theme,
      child: child,
    );
  }
}

/// Internal stateful button for surface interactivity.
class _SurfaceButton extends StatefulComponent {
  final String actionName;
  final Map<String, dynamic> actionContext;
  final String surfaceId;
  final String sourceComponentId;
  final void Function(A2uiAction action)? onAction;
  final bool isPrimary;
  final bool isDisabled;
  final String variant;
  final CruxThemeData theme;
  final Component child;

  const _SurfaceButton({
    required this.actionName,
    required this.actionContext,
    required this.surfaceId,
    required this.sourceComponentId,
    required this.onAction,
    required this.isPrimary,
    required this.isDisabled,
    this.variant = '',
    required this.theme,
    required this.child,
  });

  @override
  State<_SurfaceButton> createState() => _SurfaceButtonState();
}

class _SurfaceButtonState extends State<_SurfaceButton> {
  bool _hovered = false;
  bool _keyboardFocused = false;

  void _handleTap() {
    if (component.isDisabled || component.onAction == null) return;
    component.onAction!(
      A2uiAction(
        name: component.actionName,
        surfaceId: component.surfaceId,
        sourceComponentId: component.sourceComponentId,
        context: component.actionContext,
      ),
    );
  }

  /// Keyboard activation is inlined in build's Focusable.onKeyEvent —
  /// Enter/Space fire the action (mirroring the mouse tap), Escape
  /// releases focus back to the chat input.
  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final isActive = !component.isDisabled && component.onAction != null;
    final highlighted = _hovered || _keyboardFocused;

    // Borderless chip style — matches the ChoicePicker inline tags so
    // buttons and option tags sit side-by-side at the same size.
    // Differentiation is by background color, not by border:
    //   primary  → solid accent fill (the main action pops)
    //   others   → surfaceVariant fill (same base as option tags)
    //   hover/focus → same inversion language: primary flips to a
    //     bright fill with accent text; others get accent text.
    // Keyboard focus and mouse hover look identical — a flat TUI has
    // no separate affordance budget for both.
    final Color bg;
    final Color fg;
    final FontWeight? weight;
    if (component.isDisabled) {
      bg = theme.surfaceVariant;
      fg = theme.onSurfaceDim;
      weight = null;
    } else if (component.isPrimary) {
      // Hover/focus INVERTS the primary button: accent fill with
      // on-accent text normally; bright surface fill with accent text
      // when engaged. A full light/dark flip reads far more clearly in
      // a terminal palette than a 20% lighten of the same hue.
      bg = highlighted ? theme.buttonBackgroundHover : theme.accent;
      fg = highlighted ? theme.accent : theme.onColor(theme.accent);
      weight = FontWeight.bold;
    } else if (highlighted) {
      bg = theme.buttonBackgroundHover;
      fg = theme.accent;
      weight = null;
    } else {
      bg = theme.surfaceVariant;
      fg = theme.foreground;
      weight = null;
    }

    // The button label is a Text per the catalog contract — restyle it
    // directly (no DefaultTextStyle in nocterm). Non-Text children pass
    // through untouched.
    final child = component.child;
    final styledChild = child is Text
        ? Text(
            child.data,
            key: child.key,
            style: TextStyle(color: fg, fontWeight: weight),
            softWrap: child.softWrap,
            overflow: child.overflow,
            textAlign: child.textAlign,
            maxLines: child.maxLines,
          )
        : child;

    return Focusable(
      autofocus: false,
      disabled: !isActive,
      onKeyEvent: isActive
          ? (event) {
              final key = event.logicalKey;
              if (key == LogicalKey.enter || key == LogicalKey.space) {
                setState(() => _keyboardFocused = true);
                _handleTap();
                return true;
              }
              if (key == LogicalKey.escape) {
                NoctermBinding.instance.focusManager.unfocus();
                setState(() => _keyboardFocused = false);
                return true;
              }
              return false;
            }
          : (event) => false,
      child: MouseRegion(
        onEnter: isActive ? (_) => setState(() => _hovered = true) : null,
        onExit: isActive ? (_) => setState(() => _hovered = false) : null,
        opaque: false,
        child: GestureDetector(
          onTap: isActive ? _handleTap : null,
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(color: bg),
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: styledChild,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CheckBox
// ---------------------------------------------------------------------------

/// A2UI `CheckBox` component — a selectable checkbox for boolean toggles.
///
/// Properties:
/// - `label` (string, required): The text label next to the checkbox.
/// - `value` (object, required): `{"path": "/field"}` binding to DataModel.
class CheckBoxCatalogItem extends CatalogItem {
  @override
  String get typeName => 'CheckBox';

  @override
  String get description =>
      'A selectable checkbox for boolean toggles with a label.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'label': {
      'type': 'string',
      'description':
          'The text to display next to the checkbox. '
          'Can be a literal string or {"path": "/field"} for data binding.',
    },
    'value': {
      'type': 'object',
      'description':
          'The boolean value binding. Format: {"path": "/field"}. '
          'The component reads the initial value from this path and writes '
          'back user toggles.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final theme = CruxTheme.of(context);
    final label = resolveString(component.properties['label'], dataModel);
    final valueRef = component.properties['value'];

    // Resolve the binding path.
    String path = '${component.id}.value';
    if (valueRef is Map<String, dynamic> && valueRef.containsKey('path')) {
      path = valueRef['path'] as String;
    }

    // Read current value from DataModel.
    final currentValue = DataBinding(path).resolve(dataModel);
    final isChecked = currentValue == true;

    return _SurfaceCheckBox(
      label: label,
      isChecked: isChecked,
      path: path,
      onDataModelUpdate: submitted ? null : onDataModelUpdate,
      theme: theme,
    );
  }
}

class _SurfaceCheckBox extends StatefulComponent {
  final String label;
  final bool isChecked;
  final String path;
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final CruxThemeData theme;

  const _SurfaceCheckBox({
    required this.label,
    required this.isChecked,
    required this.path,
    required this.onDataModelUpdate,
    required this.theme,
  });

  @override
  State<_SurfaceCheckBox> createState() => _SurfaceCheckBoxState();
}

class _SurfaceCheckBoxState extends State<_SurfaceCheckBox> {
  bool _hovered = false;

  void _toggle() {
    component.onDataModelUpdate?.call(component.path, !component.isChecked);
  }

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final isActive = component.onDataModelUpdate != null;

    final checkMark = component.isChecked ? '☑' : '☐';
    final markerColor = _hovered
        ? theme.accent
        : component.isChecked
        ? theme.success
        : theme.onSurfaceDim;
    final labelColor = _hovered ? theme.accent : theme.foreground;

    return MouseRegion(
      onEnter: isActive ? (_) => setState(() => _hovered = true) : null,
      onExit: isActive ? (_) => setState(() => _hovered = false) : null,
      opaque: false,
      child: GestureDetector(
        onTap: isActive ? _toggle : null,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Text(
              '$checkMark ',
              style: TextStyle(
                color: markerColor,
                fontWeight: _hovered ? FontWeight.bold : null,
              ),
            ),
            Expanded(
              child: Text(component.label, style: TextStyle(color: labelColor)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toggle
// ---------------------------------------------------------------------------

/// A compact boolean switch. It shares CheckBox's data-binding semantics but
/// communicates an immediate on/off setting rather than a checklist item.
class ToggleCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Toggle';

  @override
  String get description =>
      'An on/off switch with two-way boolean data binding. Use for settings, '
      'not multi-step checklist items.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'label': {'type': 'string', 'description': 'Setting label.'},
    'value': {
      'type': 'object',
      'description': 'Boolean binding: {"path": "/field"}.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final valueRef = component.properties['value'];
    final path = valueRef is Map<String, dynamic> && valueRef['path'] is String
        ? valueRef['path'] as String
        : '${component.id}.value';
    return _SurfaceToggle(
      label: resolveString(component.properties['label'], dataModel),
      isOn: DataBinding(path).resolve(dataModel) == true,
      path: path,
      onDataModelUpdate: submitted ? null : onDataModelUpdate,
      theme: CruxTheme.of(context),
    );
  }
}

class _SurfaceToggle extends StatefulComponent {
  final String label;
  final bool isOn;
  final String path;
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final CruxThemeData theme;

  const _SurfaceToggle({
    required this.label,
    required this.isOn,
    required this.path,
    required this.onDataModelUpdate,
    required this.theme,
  });

  @override
  State<_SurfaceToggle> createState() => _SurfaceToggleState();
}

class _SurfaceToggleState extends State<_SurfaceToggle> {
  bool _hovered = false;

  void _toggle() =>
      component.onDataModelUpdate?.call(component.path, !component.isOn);

  @override
  Component build(BuildContext context) {
    final active = component.onDataModelUpdate != null;
    final theme = component.theme;
    final marker = component.isOn ? ' ON ' : ' OFF ';
    final color = component.isOn ? theme.success : theme.surfaceVariant;
    final foreground = component.isOn
        ? theme.onColor(color)
        : theme.onSurfaceVariant;
    return Focusable(
      onKeyEvent: (event) {
        if (active &&
            (event.logicalKey == LogicalKey.enter ||
                event.logicalKey == LogicalKey.space)) {
          _toggle();
          return true;
        }
        return false;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: active ? _toggle : null,
        child: MouseRegion(
          onEnter: active ? (_) => setState(() => _hovered = true) : null,
          onExit: active ? (_) => setState(() => _hovered = false) : null,
          opaque: false,
          child: Row(
            children: [
              Container(
                color: _hovered ? theme.buttonBackgroundHover : color,
                child: Text(
                  marker,
                  style: TextStyle(
                    color: _hovered ? theme.accent : foreground,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(child: Text(component.label)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TextField
// ---------------------------------------------------------------------------

/// A2UI `TextField` component — a text input field.
///
/// Properties:
/// - `value` (object, required): `{"path": "/field"}` binding to DataModel.
/// - `label` (string, optional): Label text displayed before the input.
/// - `variant` (string, optional): `shortText` (default), `longText`,
///   `number`, `obscured`.
/// - `onSubmittedAction` (object, optional): Action on submit.
class TextFieldCatalogItem extends CatalogItem {
  @override
  String get typeName => 'TextField';

  @override
  String get description =>
      'A text input field with bidirectional data binding.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'value': {
      'type': 'object',
      'description':
          'The value binding. Format: {"path": "/field"}. '
          'The component reads the initial value and writes back user input.',
    },
    'label': {
      'type': 'string',
      'description': 'Label text displayed before the input.',
    },
    'variant': {
      'type': 'string',
      'enum': ['shortText', 'longText', 'number', 'obscured'],
      'description': 'The kind of input the field accepts.',
    },
    'onSubmittedAction': {
      'type': 'object',
      'description':
          'Action to perform when the user submits. '
          'Format: {"event": {"name": ..., "context": {...}}}',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final theme = CruxTheme.of(context);
    final label = resolveString(component.properties['label'], dataModel);
    final valueRef = component.properties['value'];
    final variant = component.properties['variant'] as String? ?? 'shortText';
    final onSubmittedAction = component.properties['onSubmittedAction'];

    // Resolve the binding path.
    String path = '${component.id}.value';
    if (valueRef is Map<String, dynamic> && valueRef.containsKey('path')) {
      path = valueRef['path'] as String;
    }

    // Read current value from DataModel.
    final currentValue = DataBinding(path).resolve(dataModel);
    final initialText =
        currentValue?.toString() ?? (valueRef is String ? valueRef : '');

    // Parse onSubmitted action.
    String? submitActionName;
    Map<String, dynamic>? submitActionContext;
    if (onSubmittedAction is Map<String, dynamic>) {
      final event = onSubmittedAction['event'];
      if (event is Map<String, dynamic>) {
        submitActionName = event['name'] as String?;
        final ctx = event['context'];
        if (ctx is Map<String, dynamic>) submitActionContext = ctx;
      }
    }

    return _SurfaceTextField(
      label: label,
      initialText: initialText,
      path: path,
      variant: variant,
      submitActionName: submitActionName,
      submitActionContext: submitActionContext,
      surfaceId: component.id,
      sourceComponentId: component.id,
      onAction: submitted ? null : onAction,
      onDataModelUpdate: submitted ? null : onDataModelUpdate,
      theme: theme,
    );
  }
}

class _SurfaceTextField extends StatefulComponent {
  final String label;
  final String initialText;
  final String path;
  final String variant;
  final String? submitActionName;
  final Map<String, dynamic>? submitActionContext;
  final String surfaceId;
  final String sourceComponentId;
  final void Function(A2uiAction action)? onAction;
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final CruxThemeData theme;

  const _SurfaceTextField({
    required this.label,
    required this.initialText,
    required this.path,
    required this.variant,
    this.submitActionName,
    this.submitActionContext,
    required this.surfaceId,
    required this.sourceComponentId,
    this.onAction,
    this.onDataModelUpdate,
    required this.theme,
  });

  @override
  State<_SurfaceTextField> createState() => _SurfaceTextFieldState();
}

class _SurfaceTextFieldState extends State<_SurfaceTextField> {
  late final TextEditingController _controller;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: component.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleChanged(String value) {
    component.onDataModelUpdate?.call(component.path, value);
  }

  void _handleSubmitted(String value) {
    if (component.submitActionName != null && component.onAction != null) {
      component.onAction!(
        A2uiAction(
          name: component.submitActionName!,
          surfaceId: component.surfaceId,
          sourceComponentId: component.sourceComponentId,
          context: component.submitActionContext ?? const {},
        ),
      );
    }
  }

  /// Handle key events that the TextField's own handler doesn't consume.
  /// Escape releases focus back to the chat input via FocusManager.unfocus().
  /// Ctrl+C is consumed here after releasing focus so the event doesn't
  /// double-trigger (the binding's global Ctrl+C handler would also fire).
  bool _handleKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      NoctermBinding.instance.focusManager.unfocus();
      setState(() => _focused = false);
      return true;
    }
    // Ctrl+C: release focus AND let the event bubble to the global handler.
    // The surface TextField must not hold focus when Ctrl+C arrives — the
    // global quit handler needs to fire. Releasing focus first ensures the
    // chat input is the active focusable, then the event bubbles up.
    if (event.logicalKey == LogicalKey.keyC && event.isControlPressed) {
      NoctermBinding.instance.focusManager.unfocus();
      setState(() => _focused = false);
      return false; // let the binding's global Ctrl+C handler fire
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final isObscured = component.variant == 'obscured';
    final isLongText = component.variant == 'longText';
    final isNumber = component.variant == 'number';
    final isActive = component.onDataModelUpdate != null;

    // Border color: focused > hovered > default (visible but not loud).
    final borderColor = _focused
        ? theme.borderActive
        : _hovered
        ? theme.accent
        : theme.borderActive.withOpacity(0.5);

    final field = GestureDetector(
      onTap: isActive
          ? () {
              if (!_focused) setState(() => _focused = true);
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        onEnter: isActive ? (_) => setState(() => _hovered = true) : null,
        onExit: isActive ? (_) => setState(() => _hovered = false) : null,
        opaque: false,
        child: TextField(
          controller: _controller,
          focused: _focused,
          onFocusChange: (hasFocus) {
            if (!hasFocus && _focused) {
              setState(() => _focused = false);
            }
          },
          onKeyEvent: _handleKeyEvent,
          decoration: InputDecoration(
            hintText: isNumber ? '0' : null,
            border: BoxBorder.all(
              color: borderColor,
              style: BoxBorderStyle.rounded,
            ),
            focusedBorder: BoxBorder.all(
              color: theme.borderActive,
              style: BoxBorderStyle.rounded,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 1),
          ),
          obscureText: isObscured,
          maxLines: isLongText ? 3 : 1,
          onChanged: _handleChanged,
          onSubmitted: _handleSubmitted,
          style: TextStyle(color: theme.foreground),
          enabled: isActive,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Expanded under an unbounded main-axis constraint is a flex
        // layout error — e.g. when the agent declares Row > [Text,
        // TextField]: the outer Row passes unbounded width down to our
        // internal Row. Stretch only when bounded; otherwise give the
        // field a compact fixed width so the outer Row can size itself.
        final stretch = constraints.maxWidth.isFinite;
        return Row(
          children: [
            if (component.label.isNotEmpty)
              Text(
                '${component.label} ',
                style: TextStyle(color: theme.onSurfaceDim),
              ),
            if (stretch)
              Expanded(child: field)
            else
              SizedBox(width: 30, child: field),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// ChoicePicker
// ---------------------------------------------------------------------------

/// A2UI `ChoicePicker` component — selecting one or more options from a list.
///
/// Properties:
/// - `label` (string, optional): Group label.
/// - `options` (array, required): List of `{"label": ..., "value": ...}`.
/// - `value` (object, required): `{"path": "/field"}` binding to DataModel.
///   Stores a list of selected value strings.
/// - `variant` (string, optional): `mutuallyExclusive` (radio) or
///   `multipleSelection` (checkbox, default).
/// - `displayStyle` (string, optional): `checkbox` (default) or `chips`.
/// - `filterable` (bool, optional): Whether options can be filtered.
class ChoicePickerCatalogItem extends CatalogItem {
  @override
  String get typeName => 'ChoicePicker';

  @override
  String get description =>
      'A component for selecting one or more options from a list.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'label': {
      'type': 'string',
      'description': 'The label for the group of options.',
    },
    'options': {
      'type': 'array',
      'description':
          'The list of available options. Each option is '
          '{"label": "display text", "value": "stable_value"}.',
      'items': {
        'type': 'object',
        'properties': {
          'label': {'type': 'string'},
          'value': {'type': 'string'},
        },
        'required': ['label', 'value'],
      },
    },
    'value': {
      'type': 'object',
      'description':
          'The selection binding. Format: {"path": "/field"}. '
          'Stores a list of selected value strings.',
    },
    'variant': {
      'type': 'string',
      'enum': ['mutuallyExclusive', 'multipleSelection'],
      'description':
          'mutuallyExclusive: single-select (radio). '
          'multipleSelection: multi-select (checkbox, default).',
    },
    'displayStyle': {
      'type': 'string',
      'enum': ['checkbox', 'chips', 'inline'],
      'description':
          'checkbox: one option per line (default). '
          'inline: options flow horizontally on one line, '
          'separated by two spaces. Use inline for ≤4 short options.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final theme = CruxTheme.of(context);
    final label = resolveString(component.properties['label'], dataModel);
    final variant =
        component.properties['variant'] as String? ?? 'multipleSelection';
    final valueRef = component.properties['value'];
    final optionsRaw = component.properties['options'];

    // Resolve the binding path.
    String path = '${component.id}.value';
    if (valueRef is Map<String, dynamic> && valueRef.containsKey('path')) {
      path = valueRef['path'] as String;
    }

    // Parse options. unwrapListProperty tolerates the {"item": [...]}
    // array wrapper some providers emit.
    final options = <({String label, String value})>[];
    final optionsList = unwrapListProperty(optionsRaw);
    if (optionsList is List) {
      for (final o in optionsRaw) {
        if (o is Map<String, dynamic>) {
          final optLabel = o['label']?.toString() ?? '';
          final optValue = o['value']?.toString() ?? optLabel;
          options.add((label: optLabel, value: optValue));
        }
      }
    }

    // Read current selections from DataModel.
    final currentValue = DataBinding(path).resolve(dataModel);
    List<String> selections;
    if (currentValue is List) {
      selections = currentValue.map((e) => e.toString()).toList();
    } else if (currentValue is String) {
      selections = [currentValue];
    } else {
      // Fall back to literal value if provided.
      if (valueRef is List) {
        selections = valueRef.map((e) => e.toString()).toList();
      } else if (valueRef is String) {
        selections = [valueRef];
      } else {
        selections = [];
      }
    }

    final isMutuallyExclusive = variant == 'mutuallyExclusive';
    final displayStyle =
        component.properties['displayStyle'] as String? ?? 'checkbox';

    return _SurfaceChoicePicker(
      label: label,
      options: options,
      selections: selections,
      path: path,
      isMutuallyExclusive: isMutuallyExclusive,
      displayStyle: displayStyle,
      onDataModelUpdate: submitted ? null : onDataModelUpdate,
      theme: theme,
    );
  }
}

class _SurfaceChoicePicker extends StatefulComponent {
  final String label;
  final List<({String label, String value})> options;
  final List<String> selections;
  final String path;
  final bool isMutuallyExclusive;
  final String displayStyle;
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final CruxThemeData theme;

  const _SurfaceChoicePicker({
    required this.label,
    required this.options,
    required this.selections,
    required this.path,
    required this.isMutuallyExclusive,
    this.displayStyle = 'checkbox',
    required this.onDataModelUpdate,
    required this.theme,
  });

  @override
  State<_SurfaceChoicePicker> createState() => _SurfaceChoicePickerState();
}

class _SurfaceChoicePickerState extends State<_SurfaceChoicePicker> {
  /// Keyboard-focus index — only set by arrow keys, not by mouse clicks.
  /// When -1, no option has keyboard focus (mouse-only interaction).
  int _focusedIndex = -1;

  /// Mouse-hover index for the inline tag style — gives the same hover
  /// feedback buttons get (background lightens).
  int _hoveredIndex = -1;

  void _toggle(String optionValue) {
    final current = List<String>.from(component.selections);
    if (component.isMutuallyExclusive) {
      component.onDataModelUpdate?.call(component.path, [optionValue]);
    } else {
      if (current.contains(optionValue)) {
        current.remove(optionValue);
      } else {
        current.add(optionValue);
      }
      component.onDataModelUpdate?.call(component.path, current);
    }
  }

  bool _handleKey(KeyboardEvent event) {
    if (component.onDataModelUpdate == null) return false;
    final key = event.logicalKey;
    if (key == LogicalKey.arrowUp) {
      setState(() {
        if (_focusedIndex < 0) {
          _focusedIndex = component.options.length - 1;
        } else {
          _focusedIndex =
              (_focusedIndex - 1 + component.options.length) %
              component.options.length;
        }
      });
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      setState(() {
        if (_focusedIndex < 0) {
          _focusedIndex = 0;
        } else {
          _focusedIndex = (_focusedIndex + 1) % component.options.length;
        }
      });
      return true;
    }
    if (key == LogicalKey.enter || key == LogicalKey.space) {
      if (component.options.isNotEmpty && _focusedIndex >= 0) {
        _toggle(component.options[_focusedIndex].value);
      }
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final isActive = component.onDataModelUpdate != null;
    final isInline = component.displayStyle == 'inline';

    if (isInline) {
      return Focusable(
        onKeyEvent: _handleKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (component.label.isNotEmpty)
              Text(
                component.label,
                style: TextStyle(
                  color: theme.onSurfaceDim,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Row(
              children: [
                for (var i = 0; i < component.options.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  _buildInlineOption(theme, i, isActive),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Focusable(
      onKeyEvent: _handleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (component.label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 0),
              child: Text(
                component.label,
                style: TextStyle(
                  color: theme.onSurfaceDim,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          for (var i = 0; i < component.options.length; i++)
            _buildOption(theme, i, isActive),
        ],
      ),
    );
  }

  /// Inline option — renders as a compact tag-like button, all on one
  /// line separated by 2-column gaps. Selected state shown by
  /// background highlight instead of a checkbox marker.
  Component _buildInlineOption(CruxThemeData theme, int index, bool isActive) {
    final option = component.options[index];
    final isSelected = component.selections.contains(option.value);
    final isFocused = _focusedIndex >= 0 && index == _focusedIndex;
    final isHovered = _hoveredIndex == index && isActive;

    final Color bg;
    final Color fg;
    if (isSelected) {
      // Selected tags invert on hover too — same language as buttons:
      // a light/dark flip reads much more clearly than a slight tint.
      bg = isHovered ? theme.buttonBackgroundHover : theme.success;
      fg = isHovered ? theme.success : theme.onColor(theme.success);
    } else if (isHovered) {
      bg = theme.buttonBackgroundHover;
      fg = theme.accent;
    } else if (isFocused && isActive) {
      bg = theme.surfaceVariant;
      fg = theme.accent;
    } else {
      bg = theme.surfaceVariant;
      fg = theme.foreground;
    }

    return MouseRegion(
      onEnter: isActive ? (_) => setState(() => _hoveredIndex = index) : null,
      onExit: isActive ? (_) => setState(() => _hoveredIndex = -1) : null,
      opaque: false,
      child: GestureDetector(
        onTap: isActive ? () => _toggle(option.value) : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(color: bg),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Text(
            option.label,
            style: TextStyle(
              color: fg,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
        ),
      ),
    );
  }

  Component _buildOption(CruxThemeData theme, int index, bool isActive) {
    final option = component.options[index];
    final isSelected = component.selections.contains(option.value);
    // Keyboard focus only active when _focusedIndex >= 0 (arrow keys used).
    // Mouse clicks don't set _focusedIndex, so no blue highlight on click.
    final isFocused = _focusedIndex >= 0 && index == _focusedIndex;

    final String marker;
    if (component.isMutuallyExclusive) {
      marker = isSelected ? '◉' : '○';
    } else {
      marker = isSelected ? '☑' : '☐';
    }

    final Color markerColor;
    final Color textColor;
    if (isFocused && isActive) {
      // Focused: bright accent for both marker and text.
      markerColor = theme.accent;
      textColor = theme.accent;
    } else if (isSelected) {
      // Selected: success green for marker, normal text for label.
      markerColor = theme.success;
      textColor = theme.foreground;
    } else {
      // Unselected: dim for both.
      markerColor = theme.onSurfaceDim;
      textColor = theme.foreground;
    }

    return GestureDetector(
      onTap: isActive ? () => _toggle(option.value) : null,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Text(
            '$marker ',
            style: TextStyle(
              color: markerColor,
              fontWeight: isFocused && isActive ? FontWeight.bold : null,
            ),
          ),
          Expanded(
            child: Text(option.label, style: TextStyle(color: textColor)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register all interactive catalog items into a [SurfaceCatalog].
void registerInteractiveCatalogItems(SurfaceCatalog catalog) {
  catalog.register(ButtonCatalogItem());
  catalog.register(CheckBoxCatalogItem());
  catalog.register(ToggleCatalogItem());
  catalog.register(TextFieldCatalogItem());
  catalog.register(ChoicePickerCatalogItem());
}

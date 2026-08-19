/// A2UI interactive catalog items for Crux.
///
/// These items support two-way data binding (CheckBox, TextField, ChoicePicker)
/// and/or action dispatch (Button). They follow the A2UI basic catalog
/// semantics as implemented in the Flutter GenUI SDK.
library;

import 'package:nocterm/nocterm.dart';

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
      'enum': ['primary', 'borderless'],
      'description': 'A hint for the button style.',
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
    required this.theme,
    required this.child,
  });

  @override
  State<_SurfaceButton> createState() => _SurfaceButtonState();
}

class _SurfaceButtonState extends State<_SurfaceButton> {
  bool _hovered = false;

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

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final isActive = !component.isDisabled && component.onAction != null;

    final Color bgColor;
    if (component.isDisabled) {
      bgColor = theme.surface;
    } else if (_hovered) {
      bgColor = theme.buttonBackgroundHover;
    } else {
      bgColor = theme.buttonBackground;
    }

    return MouseRegion(
      onEnter: isActive ? (_) => setState(() => _hovered = true) : null,
      onExit: isActive ? (_) => setState(() => _hovered = false) : null,
      opaque: false,
      child: GestureDetector(
        onTap: isActive ? _handleTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(color: bgColor),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: component.child,
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
              child: Text(
                component.label,
                style: TextStyle(color: labelColor),
              ),
            ),
          ],
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
    final initialText = currentValue?.toString() ??
        (valueRef is String ? valueRef : '');

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

    return Row(
      children: [
        if (component.label.isNotEmpty)
          Text(
            '${component.label} ',
            style: TextStyle(color: theme.onSurfaceDim),
          ),
        // TextField needs a decoration with border or fillColor to get
        // a proper width constraint inside Expanded — without it the
        // render object measures zero and nothing renders.
        //
        // Focus: tap to focus, Escape to release back to chat input.
        // Ctrl+C and other global shortcuts pass through (not consumed).
        Expanded(
          child: GestureDetector(
            onTap: isActive
                ? () {
                    if (!_focused) setState(() => _focused = true);
                  }
                : null,
            behavior: HitTestBehavior.opaque,
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
                  color: _focused ? theme.borderActive : theme.borderSubtle,
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
        ),
      ],
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
      'enum': ['checkbox', 'chips'],
      'description': 'The display style of the component.',
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

    // Parse options.
    final options = <({String label, String value})>[];
    if (optionsRaw is List) {
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

    return _SurfaceChoicePicker(
      label: label,
      options: options,
      selections: selections,
      path: path,
      isMutuallyExclusive: isMutuallyExclusive,
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
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final CruxThemeData theme;

  const _SurfaceChoicePicker({
    required this.label,
    required this.options,
    required this.selections,
    required this.path,
    required this.isMutuallyExclusive,
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
            child: Text(
              option.label,
              style: TextStyle(color: textColor),
            ),
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
  catalog.register(TextFieldCatalogItem());
  catalog.register(ChoicePickerCatalogItem());
}

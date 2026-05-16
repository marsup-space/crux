import 'package:nocterm/nocterm.dart';
import 'ui/wizard_overlay.dart';
import '../services/provider_service.dart';
import 'provider_wizard_add.dart';
import 'provider_wizard_remove.dart';
import 'provider_wizard_modify.dart';

enum _CustomAction { add, modify, remove }

class ProviderWizardCustom extends StatefulComponent {
  final ProviderService service;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardCustom({
    super.key,
    required this.service,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardCustom> createState() => _ProviderWizardCustomState();
}

class _ProviderWizardCustomState extends State<ProviderWizardCustom> {
  _CustomAction? _selectedAction;
  Component? _activeWizard;

  ProviderService get _service => component.service;

  void _selectAction(_CustomAction action) {
    final VoidCallback onComplete = () {
      setState(() {
        _activeWizard = null;
      });
      component.onComplete?.call();
    };
    final VoidCallback onDismiss = () {
      setState(() {
        _activeWizard = null;
      });
      component.onDismiss?.call();
    };

    setState(() {
      _selectedAction = action;
      _activeWizard = switch (action) {
        _CustomAction.add => ProviderWizardAdd(
            service: _service,
            onComplete: onComplete,
            onDismiss: onDismiss,
          ),
        _CustomAction.modify => ProviderWizardModify(
            service: _service,
            onComplete: onComplete,
            onDismiss: onDismiss,
          ),
        _CustomAction.remove => ProviderWizardRemove(
            service: _service,
            onComplete: onComplete,
            onDismiss: onDismiss,
          ),
      };
    });
  }

  @override
  Component build(BuildContext context) {
    if (_activeWizard != null) return _activeWizard!;

    return WizardOverlay(
      steps: [
        WizardStep(
          title: 'Custom Provider',
          contentBuilder: _buildMenuStep,
          validate: () => _selectedAction != null,
          stepContentFocused: () => true,
          onKeyEvent: (event) {
            if (event.logicalKey == LogicalKey.arrowUp) {
              setState(() {
                final values = _CustomAction.values;
                final idx = _selectedAction != null
                    ? values.indexOf(_selectedAction!)
                    : -1;
                _selectedAction =
                    values[(idx - 1).clamp(0, values.length - 1)];
              });
              return true;
            }
            if (event.logicalKey == LogicalKey.arrowDown) {
              setState(() {
                final values = _CustomAction.values;
                final idx = _selectedAction != null
                    ? values.indexOf(_selectedAction!)
                    : -1;
                _selectedAction =
                    values[(idx + 1).clamp(0, values.length - 1)];
              });
              return true;
            }
            if (event.logicalKey == LogicalKey.enter &&
                _selectedAction != null) {
              _selectAction(_selectedAction!);
              return true;
            }
            return false;
          },
        ),
      ],
      onComplete: () {
        if (_selectedAction != null) {
          _selectAction(_selectedAction!);
        }
      },
      onCancel: () => component.onDismiss?.call(),
    );
  }

  Component _buildMenuStep() {
    final actions = [
      (_CustomAction.add, 'Add', 'Add a new custom provider (OpenAI or Anthropic compatible)'),
      (_CustomAction.modify, 'Modify', 'Edit an existing provider\'s config or models'),
      (_CustomAction.remove, 'Remove', 'Remove an existing provider'),
    ];

    final rows = <Component>[];

    rows.add(
      const Text(
        'Manage custom providers:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    for (final (action, label, description) in actions) {
      final isSelected = _selectedAction == action;
      rows.add(
        MouseRegion(
          onEnter: (_) => setState(() => _selectedAction = action),
          opaque: false,
          child: GestureDetector(
            onTap: () => _selectAction(action),
            behavior: HitTestBehavior.opaque,
            child: Container(
              decoration: isSelected
                  ? const BoxDecoration(color: Color.fromRGB(40, 30, 80))
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
              child: Row(
                children: [
                  Text(
                    isSelected ? '▶ ' : '  ',
                    style: TextStyle(
                      color: isSelected ? Colors.brightCyan : Colors.gray,
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.brightCyan : Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      description,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.gray,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

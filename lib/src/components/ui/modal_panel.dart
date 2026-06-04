import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';

class ModalPanel extends StatefulComponent {
  final String title;
  final Component Function(BuildContext context) contentBuilder;
  final VoidCallback onDismiss;
  final List<ModalPanelShortcut> shortcuts;
  final KeyEventHandler? onKeyEvent;

  const ModalPanel({
    required this.title,
    required this.contentBuilder,
    required this.onDismiss,
    this.shortcuts = const [],
    this.onKeyEvent,
  });

  @override
  State<ModalPanel> createState() => _ModalPanelState();
}

class ModalPanelShortcut {
  final String label;
  final String keyHint;
  final bool Function(KeyboardEvent event) matches;
  final VoidCallback onActivate;

  const ModalPanelShortcut({
    required this.label,
    required this.keyHint,
    required this.matches,
    required this.onActivate,
  });
}

class _ModalPanelState extends State<ModalPanel> {
  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        children: [
          Positioned.fill(
            child: ModalBarrier(
              color: CruxTheme.wizardOverlayBg,
              dismissible: false,
              obscure: true,
            ),
          ),
          Positioned(
            top: 1,
            left: 2,
            right: 2,
            bottom: 1,
            child: Container(
              decoration: BoxDecoration(
                color: CruxTheme.wizardOverlayBg,
                border: BoxBorder(
                  top: const BorderSide(color: CruxTheme.outline),
                  right: const BorderSide(color: CruxTheme.outline),
                  bottom: const BorderSide(color: CruxTheme.outline),
                  left: const BorderSide(color: CruxTheme.outline),
                ),
              ),
              padding: const EdgeInsets.all(1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        component.title,
                        style: const TextStyle(
                          color: CruxTheme.wizardTitle,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Esc close',
                        style: const TextStyle(color: CruxTheme.hintText),
                      ),
                    ],
                  ),
                  const Divider(color: CruxTheme.outline, height: 1),
                  Expanded(child: component.contentBuilder(context)),
                  if (component.shortcuts.isNotEmpty) ...[
                    const Divider(color: CruxTheme.outline, height: 1),
                    _buildShortcutsFooter(),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Component _buildShortcutsFooter() {
    final items = <Component>[];
    for (int i = 0; i < component.shortcuts.length; i++) {
      if (i > 0) {
        items.add(
          Text('  ', style: const TextStyle(color: CruxTheme.hintText)),
        );
      }
      final s = component.shortcuts[i];
      items.add(
        Text(
          '${s.keyHint} ${s.label}',
          style: const TextStyle(color: CruxTheme.onSurfaceVariant),
        ),
      );
    }
    return Row(children: items);
  }

  bool _handleKeyEvent(KeyboardEvent event) {
    if (component.onKeyEvent != null) {
      final handled = component.onKeyEvent!(event);
      if (handled) return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    for (final shortcut in component.shortcuts) {
      if (shortcut.matches(event)) {
        shortcut.onActivate();
        return true;
      }
    }
    return true;
  }
}

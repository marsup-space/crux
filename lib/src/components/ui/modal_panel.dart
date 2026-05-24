import 'package:nocterm/nocterm.dart';

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
              color: const Color.fromRGB(20, 15, 40),
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
                color: const Color.fromRGB(20, 15, 40),
                border: BoxBorder(
                  top: const BorderSide(color: Color.fromRGB(80, 60, 120)),
                  right: const BorderSide(color: Color.fromRGB(80, 60, 120)),
                  bottom: const BorderSide(color: Color.fromRGB(80, 60, 120)),
                  left: const BorderSide(color: Color.fromRGB(80, 60, 120)),
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
                          color: Colors.brightMagenta,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Esc close',
                        style: const TextStyle(
                          color: Color.fromRGB(60, 50, 90),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Color.fromRGB(80, 60, 120), height: 1),
                  Expanded(
                    child: component.contentBuilder(context),
                  ),
                  if (component.shortcuts.isNotEmpty) ...[
                    const Divider(color: Color.fromRGB(80, 60, 120), height: 1),
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
        items.add(Text('  ', style: const TextStyle(color: Color.fromRGB(60, 50, 90))));
      }
      final s = component.shortcuts[i];
      items.add(Text(
        '${s.keyHint} ${s.label}',
        style: const TextStyle(color: Color.fromRGB(120, 100, 160)),
      ));
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

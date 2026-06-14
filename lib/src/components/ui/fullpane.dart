import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';
import 'button.dart';

/// Width threshold (columns) below which the fullpane becomes truly
/// full-screen. Matches the side-panel hide threshold so the UX is
/// consistent: when the terminal is too narrow for a side panel it's
/// also too narrow for margin insets.
const kFullpaneNarrowThreshold = 100;

/// Height threshold (rows) below which the fullpane becomes truly
/// full-screen. 24 rows is the classic minimum terminal size; below
/// that there's no room for margins around the pane.
const kFullpaneShortThreshold = 24;

/// A shortcut hint displayed in the fullpane footer.
class FullpaneShortcut {
  final String label;
  final String keyHint;
  final bool Function(KeyboardEvent event) matches;
  final VoidCallback onActivate;

  const FullpaneShortcut({
    required this.label,
    required this.keyHint,
    required this.matches,
    required this.onActivate,
  });
}

/// A huge, near-full-screen modal pane. When the terminal is wide
/// and tall enough it renders with a margin on each side so the
/// underlying UI is still visible (dimmed) around the edges; when
/// the terminal is narrow (< [kFullpaneNarrowThreshold] columns) or
/// short (< [kFullpaneShortThreshold] rows) it fills the entire
/// screen instead.
///
/// Provides a title bar with close button, an expanded content area,
/// and an optional shortcuts footer — the same chrome that
/// [ModalPanel] offers, but in a larger, near-full-screen form.
class Fullpane extends StatefulComponent {
  final String title;
  final VoidCallback onClose;
  final Component Function(BuildContext context) contentBuilder;
  final List<FullpaneShortcut> shortcuts;
  final KeyEventHandler? onKeyEvent;

  const Fullpane({
    required this.title,
    required this.onClose,
    required this.contentBuilder,
    this.shortcuts = const [],
    this.onKeyEvent,
    super.key,
  });

  @override
  State<Fullpane> createState() => _FullpaneState();
}

class _FullpaneState extends State<Fullpane> {
  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final isNarrow = w < kFullpaneNarrowThreshold;
        final isShort = h < kFullpaneShortThreshold;
        final isFullScreen = isNarrow || isShort;

        // Margins: 3 rows top/bottom, 6 cols left/right — but only
        // when the terminal is large enough to afford them.
        final topInset = isFullScreen ? 0.0 : 3.0;
        final bottomInset = isFullScreen ? 0.0 : 3.0;
        final horizontalInset = isFullScreen ? 0.0 : 6.0;

        return Stack(
          children: [
            // Dim the background so the pane stands out.
            // obscure: false preserves the underlying text characters
            // while darkening their colors — you can still see the
            // chat through the margin gaps, just dimmed.
            Positioned.fill(
              child: ModalBarrier(
                color: CruxTheme.of(context).wizardOverlayBg.withOpacity(0.85),
                dismissible: false,
                obscure: false,
              ),
            ),
            Positioned(
              top: topInset,
              left: horizontalInset,
              right: horizontalInset,
              bottom: bottomInset,
              child: Focusable(
                focused: true,
                onKeyEvent: _handleKeyEvent,
                child: Container(
                  decoration: BoxDecoration(
                    color: CruxTheme.of(context).surface,
                    border: BoxBorder.all(
                      color: CruxTheme.of(context).outline,
                      style: BoxBorderStyle.rounded,
                    ),
                    borderRadius: BorderRadius.circular(1),
                  ),
                  padding: const EdgeInsets.only(left: 1, right: 1, bottom: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Header row ──
                      Row(
                        children: [
                          Text(
                            component.title,
                            style: TextStyle(
                              color: CruxTheme.of(context).wizardTitle,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Button(
                            label: '✕ close',
                            onPressed: component.onClose,
                            color: CruxTheme.of(context).hintText,
                            hoverColor: CruxTheme.of(context).foreground,
                            bgColor: CruxTheme.of(context).surface,
                            hoverBgColor:
                                CruxTheme.of(context).buttonBackgroundHover,
                          ),
                        ],
                      ),
                      Divider(
                        color: CruxTheme.of(context).outline,
                        height: 1,
                      ),

                      // ── Content area ──
                      Expanded(child: component.contentBuilder(context)),

                      // ── Shortcuts footer ──
                      if (component.shortcuts.isNotEmpty) ...[
                        Divider(
                          color: CruxTheme.of(context).outline,
                          height: 1,
                        ),
                        _buildShortcutsFooter(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Component _buildShortcutsFooter() {
    final items = <Component>[];
    for (int i = 0; i < component.shortcuts.length; i++) {
      if (i > 0) {
        items.add(
          Text(
            '  ',
            style: TextStyle(color: CruxTheme.of(context).hintText),
          ),
        );
      }
      final s = component.shortcuts[i];
      items.add(
        Text(
          '${s.keyHint} ${s.label}',
          style: TextStyle(
            color: CruxTheme.of(context).onSurfaceVariant,
          ),
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
      component.onClose();
      return true;
    }
    for (final shortcut in component.shortcuts) {
      if (shortcut.matches(event)) {
        shortcut.onActivate();
        return true;
      }
    }
    // Consume all other keys so the underlying chat doesn't react
    // while the fullpane is open.
    return true;
  }
}

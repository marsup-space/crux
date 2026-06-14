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

/// A huge, near-full-screen modal pane. When the terminal is wide
/// and tall enough it renders with a margin on each side so the
/// underlying UI is still visible around the edges; when the
/// terminal is narrow (< [kFullpaneNarrowThreshold] columns) or
/// short (< [kFullpaneShortThreshold] rows) it fills the entire
/// screen instead.
///
/// Currently a placeholder — title, content area, and a close
/// button in the top-right corner.
class Fullpane extends StatefulComponent {
  final String title;
  final VoidCallback onClose;

  const Fullpane({
    required this.title,
    required this.onClose,
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
                            hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
                          ),
                        ],
                      ),
                      Divider(color: CruxTheme.of(context).outline, height: 1),

                      // ── Content area (placeholder) ──
                      Expanded(
                        child: Center(
                          child: Text(
                            'Fullpane placeholder content',
                            style: TextStyle(
                              color: CruxTheme.of(context).onSurfaceDim,
                            ),
                          ),
                        ),
                      ),
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

  bool _handleKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onClose();
      return true;
    }
    // Consume all other keys so the underlying chat doesn't react
    // while the fullpane is open.
    return true;
  }
}

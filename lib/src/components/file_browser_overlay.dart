import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/file_searcher.dart';
import '../utils/ticker_registry.dart';

/// File browser popover shown when the user types `@` in the chat
/// input. Mirrors [SuggestionOverlay] but renders file/directory
/// paths with a small icon column and segments the path into
/// "directory/prefix" (dim) + "filename" (highlighted) so the user
/// can scan visually. Layout matches the command palette.
class FileBrowserOverlay extends StatefulComponent {
  final List<FileMatch> files;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final String query;

  /// True while the underlying FileSearcher is still building its
  /// index or scoring the latest query. Existing rows stay visible;
  /// the header shows a tiny spinner so the popover doesn't flash
  /// on every keypress.
  final bool isSearching;

  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const FileBrowserOverlay({
    super.key,
    required this.files,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    required this.query,
    this.isSearching = false,
    this.onHover,
    this.onTap,
  });

  @override
  State<FileBrowserOverlay> createState() => _FileBrowserOverlayState();
}

class _FileBrowserOverlayState extends State<FileBrowserOverlay> {
  static const _spinnerFrames = ['|', '/', '-', r'\'];

  /// Time per spinner-frame advance. The ticker fires at
  /// 120 ms, but we accumulate the actual elapsed time and
  /// only advance the visible frame once we've crossed this
  /// threshold — this keeps the rotation rate constant in
  /// wall-clock terms even if frames take longer than 120 ms.
  static const double _spinnerFrameMs = 100.0;

  TickerToken? _spinnerTicker;
  int _spinnerFrame = 0;
  double _spinnerAccumulatorMs = 0.0;

  @override
  void initState() {
    super.initState();
    _syncSpinnerTicker();
  }

  @override
  void didUpdateComponent(covariant FileBrowserOverlay oldComponent) {
    super.didUpdateComponent(oldComponent);
    _syncSpinnerTicker();
  }

  @override
  void dispose() {
    _stopSpinnerTicker();
    super.dispose();
  }

  void _syncSpinnerTicker() {
    if (component.isSearching) {
      _spinnerTicker ??= TickerRegistry.instance.subscribe(
        name: 'fileSearchSpinner',
        interval: const Duration(milliseconds: 120),
        onTick: (elapsed) {
          if (!mounted) return;
          // Delta-time spinner: throttle the frame advance by
          // accumulated wall-clock time, not by fixed-step
          // ticks. With `_frameStep = 100 ms`, the spinner
          // advances one frame every ~100 ms regardless of
          // whether frames land at 60 fps, 30 fps, or whatever
          // — the visible rotation stays at a steady pace.
          // Without this, a 20 ms slow frame would tick at the
          // same rate as a 120 ms frame, and the spinner would
          // visibly speed up during lag spikes.
          _spinnerAccumulatorMs += elapsed == Duration.zero
              ? 120.0
              : elapsed.inMicroseconds / 1000.0;
          while (_spinnerAccumulatorMs >= _spinnerFrameMs) {
            _spinnerAccumulatorMs -= _spinnerFrameMs;
            _spinnerFrame =
                (_spinnerFrame + 1) % _spinnerFrames.length;
          }
          setState(() {});
        },
      );
    } else {
      _stopSpinnerTicker();
      _spinnerFrame = 0;
      _spinnerAccumulatorMs = 0.0;
    }
  }

  void _stopSpinnerTicker() {
    _spinnerTicker?.cancel();
    _spinnerTicker = null;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final visible = component.files
        .skip(component.scrollOffset)
        .take(component.maxVisible)
        .toList();
    final rows = <Component>[];

    rows.add(Divider(color: theme.outline, height: 1));
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Files',
              style: TextStyle(
                color: theme.wizardTitle,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: 1),
            Text(
              component.query.isEmpty
                  ? '(@-mention a file)'
                  : '(@${component.query})',
              style: TextStyle(color: theme.wizardTextDim),
            ),
            if (component.isSearching) ...[
              SizedBox(width: 1),
              Text(
                _spinnerFrames[_spinnerFrame],
                style: TextStyle(color: theme.wizardTextDim),
              ),
            ] else if (component.files.isEmpty) ...[
              SizedBox(width: 1),
              Text(
                '  no matches',
                style: TextStyle(color: theme.wizardTextDim),
              ),
            ],
          ],
        ),
      ),
    );
    rows.add(Divider(color: theme.outline, height: 1));

    for (int i = 0; i < visible.length; i++) {
      final file = visible[i];
      final actualIndex = component.scrollOffset + i;
      final isSelected = actualIndex == component.selectedIndex;
      rows.add(
        MouseRegion(
          onEnter: (_) => component.onHover?.call(actualIndex),
          opaque: false,
          child: GestureDetector(
            onTap: () => component.onTap?.call(actualIndex),
            behavior: HitTestBehavior.opaque,
            child: _buildFileRow(file, isSelected, theme),
          ),
        ),
      );
    }

    rows.add(Divider(color: theme.outline, height: 1));

    return Container(
      decoration: BoxDecoration(color: theme.wizardOverlayBg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildFileRow(
    FileMatch file,
    bool isSelected,
    CruxThemeData theme,
  ) {
    final isDir = file.kind == FileMatchKind.directory;
    final icon = isDir ? '▸ ' : '  ';
    // Split path into directory and filename for a Claude-Code-like
    // "files/" (dim) + "name.dart" (highlighted) split.
    final path = file.relativePath;
    final lastSlash = path.lastIndexOf('/');
    final dirPart = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '';
    final namePart = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;

    return Container(
      decoration: isSelected
          ? BoxDecoration(color: theme.wizardRowBgSelected)
          : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            isSelected ? '> ' : '  ',
            style: TextStyle(
              color: isSelected
                  ? theme.wizardMarkerSelected
                  : theme.wizardMarkerUnselected,
            ),
          ),
          Text(
            icon,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextDim,
            ),
          ),
          if (dirPart.isNotEmpty)
            Text(
              dirPart,
              style: TextStyle(
                color: isSelected
                    ? theme.wizardTextUnselected
                    : theme.wizardTextDim,
              ),
            ),
          Text(
            namePart,
            style: TextStyle(
              color: isSelected
                  ? theme.wizardTextSelected
                  : theme.wizardTextUnselected,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          // Pad with trailing spaces to fill the row so the selected
          // background stretches to the right edge.
          Expanded(
            child: Text(
              '',
              style: TextStyle(
                color: isSelected
                    ? theme.wizardTextUnselected
                    : theme.wizardTextDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

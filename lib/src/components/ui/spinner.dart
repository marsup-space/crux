import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import '../../utils/terminal_symbols.dart';
import '../../utils/ticker_registry.dart';

/// Braille spinner frames, in cycle order.
const List<String> kSpinnerFramesBraille = [
  '⠋',
  '⠙',
  '⠹',
  '⠸',
  '⠼',
  '⠴',
  '⠦',
  '⠧',
  '⠇',
  '⠏',
];

/// ASCII fallback frames for terminals without rich glyph support
/// (same `- \ | /` idiom the file browser used before this component
/// existed).
const List<String> kSpinnerFramesAscii = ['-', r'\', '|', '/'];

/// The frame list appropriate for the current terminal, rich braille
/// frames when supported and the ASCII fallback otherwise.
List<String> spinnerFrames() {
  return supportsRichTerminalSymbols()
      ? kSpinnerFramesBraille
      : kSpinnerFramesAscii;
}

/// Pure frame lookup shared by [Spinner] and the tests: wraps [index]
/// around the active frame list so callers can advance indefinitely.
String spinnerFrameAt(int index) {
  final frames = spinnerFrames();
  return frames[index % frames.length];
}

/// A tiny animated spinner that cycles the braille frames
/// `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (ASCII `- \ | /` fallback) at a
/// steady wall-clock pace.
///
/// Animation follows the same pattern as [GlossyModelButton] and the
/// old file-browser spinner: a [TickerRegistry] subscription with
/// delta-time accumulation, so a slow frame advances the spinner by
/// the same wall-clock amount as a fast one and the rotation never
/// visibly speeds up or stalls during lag spikes. The subscription is
/// cancelled in [State.dispose].
class Spinner extends StatefulComponent {
  /// Glyph color. Defaults to the theme's accent hue.
  final Color? color;

  /// Wall-clock time each frame stays on screen.
  final Duration frameDuration;

  const Spinner({
    super.key,
    this.color,
    this.frameDuration = const Duration(milliseconds: 80),
  });

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> {
  TickerToken? _ticker;
  int _frame = 0;
  double _accumulatorMs = 0.0;

  @override
  void initState() {
    super.initState();
    _ticker = TickerRegistry.instance.subscribe(
      name: 'spinner',
      interval: component.frameDuration,
      onTick: _onTick,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final stepMs = component.frameDuration.inMicroseconds / 1000.0;
    if (stepMs <= 0) return;
    _accumulatorMs += elapsed == Duration.zero
        ? stepMs
        : elapsed.inMicroseconds / 1000.0;
    var advanced = false;
    final frameCount = spinnerFrames().length;
    while (_accumulatorMs >= stepMs) {
      _accumulatorMs -= stepMs;
      _frame = (_frame + 1) % frameCount;
      advanced = true;
    }
    if (advanced) {
      setState(() {});
    }
  }

  @override
  Component build(BuildContext context) {
    return Text(
      spinnerFrameAt(_frame),
      style: TextStyle(
        color: component.color ?? CruxTheme.of(context).accent,
      ),
    );
  }
}

import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';
import '../../utils/ticker_registry.dart';

class GlossyModelButton extends StatefulComponent {
  final String label;
  final bool isAnimating;
  final VoidCallback? onPressed;

  /// Minimum rendered width in terminal columns. When the label
  /// (plus its 2 padding cells) is narrower, the button is padded
  /// with trailing background cells so short labels stay the same
  /// width as long ones — used by the side panel's auxiliary-model
  /// button, whose label shrinks from `AUX: model-name` to
  /// `titling…` while busy but must keep occupying the full panel
  /// width. Null (default) = size to label, the historic behavior.
  final int? minWidth;

  const GlossyModelButton({
    required this.label,
    required this.isAnimating,
    this.onPressed,
    this.minWidth,
  });

  @override
  State<GlossyModelButton> createState() => GlossyModelButtonState();
}

class GlossyModelButtonState extends State<GlossyModelButton> {
  TickerToken? _animTicker;
  double _phase = -_bandWidth;
  int _tickCount = 0;
  bool _hovered = false;
  bool _isFadingOut = false;
  double _fadeIntensity = 1.0;

  static const double _bandWidth = 8.0;
  static const int _fadeTicks = 20; // ~1.2s at 60ms per tick

  @override
  void initState() {
    super.initState();
    if (component.isAnimating) {
      _startAnimation();
    }
  }

  @override
  void didUpdateComponent(GlossyModelButton oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (component.isAnimating && !oldComponent.isAnimating) {
      _isFadingOut = false;
      _fadeIntensity = 1.0;
      _startAnimation();
    } else if (!component.isAnimating && oldComponent.isAnimating) {
      // Start fade-out instead of immediately stopping
      _isFadingOut = true;
      _fadeIntensity = 1.0;
      // Animation ticker keeps running during fade
      if (_animTicker == null) {
        _startAnimation();
      }
    }
  }

  @override
  void dispose() {
    _animTicker?.cancel();
    _animTicker = null;
    super.dispose();
  }

  void _startAnimation() {
    _phase = -_bandWidth;
    _tickCount = 0;
    _animTicker?.cancel();
    _animTicker = TickerRegistry.instance.subscribe(
      name: 'glossyButton',
      interval: const Duration(milliseconds: 60),
      onTick: (elapsed) {
        // Delta-time advance: convert the wall-clock delta
        // to seconds and multiply by the cell-per-second
        // rate. The original cadence advanced `_phase` by
        // 1.5 every 60 ms tick — that's 25 cells/sec. With
        // delta-time math, slow frames advance the phase
        // further and fast frames less, so the sweep stays
        // at a constant wall-clock speed regardless of the
        // frame interval.
        final dt = elapsed == Duration.zero
            ? 60.0 / 1000.0
            : elapsed.inMicroseconds / Duration.microsecondsPerSecond;
        _phase += 25.0 * dt; // 25 cells/sec = matches original 1.5/60ms
        final sweepEnd =
            component.label.length + 2 + _bandWidth; // +2 for padding cells
        if (_phase > sweepEnd) {
          _phase = -_bandWidth;
        }
        _tickCount++;

        if (_isFadingOut) {
          // Fade-out over `_fadeTicks` ticks (~1.2s at 60ms
          // per tick on the original cadence); with delta
          // time we subtract a per-second rate instead of a
          // per-tick fraction so the fade stays 1.2s long
          // regardless of frame rate.
          _fadeIntensity -= dt / (_fadeTicks * 60.0 / 1000.0);
          if (_fadeIntensity <= 0) {
            _fadeIntensity = 0;
            _isFadingOut = false;
            _stopAnimation();
            setState(() {});
            return;
          }
        }

        setState(() {});
      },
    );
  }

  void _stopAnimation() {
    _animTicker?.cancel();
    _animTicker = null;
  }

  @override
  Component build(BuildContext context) {
    final btn = component;
    final theme = CruxTheme.of(context);
    final baseBg = theme.buttonBackground;
    final peakBg = theme.progressFill;
    final baseFg = theme.onSurfaceVariant;
    final flashFg = theme.foreground;

    if (!btn.isAnimating && !_isFadingOut) {
      // Static mode with hover support
      final bgColor = _hovered ? theme.buttonBackgroundHover : baseBg;
      final fg = _hovered ? theme.buttonTextHover : baseFg;

      // minWidth padding: trailing cells in the same background so
      // the padded area is visually part of the button (and, thanks
      // to the opaque GestureDetector, part of its hit region).
      final padCells = btn.minWidth == null
          ? 0
          : max(0, btn.minWidth! - btn.label.length - 2);

      return MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        opaque: false,
        child: GestureDetector(
          onTap: btn.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            color: bgColor,
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              children: [
                Text(
                  btn.label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: _hovered ? FontWeight.bold : null,
                  ),
                ),
                if (padCells > 0) Text(' ' * padCells),
              ],
            ),
          ),
        ),
      );
    }

    // Animated/fading mode: flowing gradient sweep + periodic text flash
    // Render every cell (left padding, label chars, right padding) with
    // individual sweep-based background color so gradient covers the whole area.
    // Pulse: brief periodic flash using sin² — peaks every 0.33s
    final pulseValue = pow(max(0.0, sin(_tickCount * 1.142)), 2.0).toDouble();

    final labelLength = btn.label.length;
    final cells = <Component>[];

    // Sweep-relative positions: left pad = -1, label chars = 0..labelLength-1,
    // then right padding. minWidth extends the right padding so the
    // gradient covers the full requested width — trailing cells are
    // background-only, exactly like the two natural padding cells.
    final rightPadEnd = btn.minWidth == null
        ? labelLength
        : max(labelLength, btn.minWidth! - 1);
    for (int sweepPos = -1; sweepPos <= rightPadEnd; sweepPos++) {
      final distance = (sweepPos - _phase).abs();
      double sweepEase;
      if (distance < _bandWidth) {
        final t = 1.0 - distance / _bandWidth;
        sweepEase = t * t * (3 - 2 * t); // smoothstep
      } else {
        sweepEase = 0.0;
      }

      final bgBrightness = sweepEase * _fadeIntensity;
      final bg = Color.lerp(baseBg, peakBg, bgBrightness)!;

      if (sweepPos >= 0 && sweepPos < labelLength) {
        // Label character — also has foreground with pulse flash
        final fgBrightness = max(sweepEase, pulseValue) * _fadeIntensity;
        final fg = Color.lerp(baseFg, flashFg, fgBrightness)!;

        cells.add(
          Text(
            btn.label[sweepPos],
            style: TextStyle(
              color: fg,
              backgroundColor: bg,
              fontWeight: fgBrightness > 0.3 ? FontWeight.bold : null,
            ),
          ),
        );
      } else {
        // Padding cell — space with sweep-based background only
        cells.add(Text(' ', style: TextStyle(backgroundColor: bg)));
      }
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: btn.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Row(children: cells),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';

class GlossyModelButton extends StatefulComponent {
  final String label;
  final bool isAnimating;
  final VoidCallback? onPressed;

  const GlossyModelButton({
    required this.label,
    required this.isAnimating,
    this.onPressed,
  });

  @override
  State<GlossyModelButton> createState() => GlossyModelButtonState();
}

class GlossyModelButtonState extends State<GlossyModelButton> {
  Timer? _animTimer;
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
      // Animation timer keeps running during fade
      if (_animTimer == null) {
        _startAnimation();
      }
    }
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _animTimer = null;
    super.dispose();
  }

  void _startAnimation() {
    _phase = -_bandWidth;
    _tickCount = 0;
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      _phase += 1.5; // faster sweep
      final sweepEnd =
          component.label.length + 2 + _bandWidth; // +2 for padding cells
      if (_phase > sweepEnd) {
        _phase = -_bandWidth;
      }
      _tickCount++;

      if (_isFadingOut) {
        _fadeIntensity -= 1.0 / _fadeTicks;
        if (_fadeIntensity <= 0) {
          _fadeIntensity = 0;
          _isFadingOut = false;
          _stopAnimation();
          setState(() {});
          return;
        }
      }

      setState(() {});
    });
  }

  void _stopAnimation() {
    _animTimer?.cancel();
    _animTimer = null;
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
            child: Text(
              btn.label,
              style: TextStyle(
                color: fg,
                fontWeight: _hovered ? FontWeight.bold : null,
              ),
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

    // Sweep-relative positions: left pad = -1, label chars = 0..labelLength-1, right pad = labelLength
    for (int sweepPos = -1; sweepPos <= labelLength; sweepPos++) {
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

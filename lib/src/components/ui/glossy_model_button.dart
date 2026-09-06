// ignore_for_file: implementation_imports

import 'dart:math';

import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import '../../theme/crux_theme.dart';
import '../../utils/ticker_registry.dart';

class GlossyModelButton extends StatefulComponent {
  final String label;

  /// Label shown while the pointer hovers the button. When null the
  /// button always shows [label]. Used by the streaming model button to
  /// swap the model name for the "Interrupt" affordance on hover, so
  /// the user can see what a click will do before committing.
  final String? hoverLabel;
  final bool isAnimating;
  final VoidCallback? onPressed;

  /// Centers [label] within the fixed-width content area. Intended for
  /// transient task labels such as `titling…`; normal model names remain
  /// left-aligned.
  final bool centerLabel;

  /// Minimum rendered width in terminal columns. When the label
  /// (plus its 2 padding cells) is narrower, the button is padded
  /// with background cells so short labels stay centered at the same
  /// width as long ones — used by the side panel's auxiliary-model
  /// button, whose label shrinks from `AUX: model-name` to
  /// `titling…` while busy but must keep occupying the full panel
  /// width. Null (default) = size to label, the historic behavior.
  final int? minWidth;

  const GlossyModelButton({
    required this.label,
    this.hoverLabel,
    required this.isAnimating,
    this.onPressed,
    this.centerLabel = false,
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

  /// The text area between the button's two outer padding cells.
  ///
  /// This must use terminal *column* width, not [String.length]: in the
  /// Chinese UI, `中断` is two Dart characters but occupies four columns.
  /// Keeping one shared width for both labels makes hover a content change,
  /// rather than a layout change.
  int get _contentWidth => max(
    max(
      UnicodeWidth.stringWidth(component.label),
      UnicodeWidth.stringWidth(component.hoverLabel ?? ''),
    ),
    max(0, (component.minWidth ?? 0) - 2),
  );

  ({int leading, int trailing}) _labelPadding(String label) {
    final remaining = max(
      0,
      _contentWidth - UnicodeWidth.stringWidth(label),
    ).toInt();
    final shouldCenter =
        component.centerLabel || (_hovered && component.hoverLabel != null);
    return shouldCenter
        ? (leading: remaining ~/ 2, trailing: remaining - remaining ~/ 2)
        : (leading: 0, trailing: remaining);
  }

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
        // Sweep across the fixed button width so hover cannot alter its path.
        final sweepEnd = _contentWidth + 2 + _bandWidth; // outer padding
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

    // The label actually rendered: the hover label when the pointer is
    // over the button and one is provided, else the base label. Applies
    // to both the static and the animated branches so the streaming
    // model button can swap to "Interrupt" on hover.
    final effectiveLabel = (_hovered && btn.hoverLabel != null)
        ? btn.hoverLabel!
        : btn.label;

    if (!btn.isAnimating && !_isFadingOut) {
      // Static mode with hover support
      final bgColor = _hovered ? theme.buttonBackgroundHover : baseBg;
      final fg = _hovered ? theme.buttonTextHover : baseFg;

      // Center either label inside the shared content width. The spaces use
      // the same background and remain inside the opaque hit region.
      final padding = _labelPadding(effectiveLabel);

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
                if (padding.leading > 0) Text(' ' * padding.leading),
                Text(
                  effectiveLabel,
                  style: TextStyle(
                    color: fg,
                    fontWeight: _hovered ? FontWeight.bold : null,
                  ),
                ),
                if (padding.trailing > 0) Text(' ' * padding.trailing),
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

    // The animated button uses the same centered, fixed-width geometry as
    // the static one. Graphemes are used so emoji and CJK labels consume
    // their proper number of terminal columns.
    final padding = _labelPadding(effectiveLabel);
    final cells = <Component>[];

    Component buildCell(String text, int sweepPos, {bool isLabel = false}) {
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

      if (isLabel) {
        // Label grapheme — also has foreground with pulse flash.
        final fgBrightness = max(sweepEase, pulseValue) * _fadeIntensity;
        final fg = Color.lerp(baseFg, flashFg, fgBrightness)!;
        return Text(
          text,
          style: TextStyle(
            color: fg,
            backgroundColor: bg,
            fontWeight: fgBrightness > 0.3 ? FontWeight.bold : null,
          ),
        );
      }
      // Padding cell — space with sweep-based background only.
      return Text(' ', style: TextStyle(backgroundColor: bg));
    }

    // One outer padding cell, then the centered content, then the other.
    var sweepPos = -1;
    cells.add(buildCell(' ', sweepPos++));
    for (var i = 0; i < padding.leading; i++) {
      cells.add(buildCell(' ', sweepPos++));
    }
    for (final grapheme in effectiveLabel.characters) {
      cells.add(buildCell(grapheme, sweepPos, isLabel: true));
      sweepPos += UnicodeWidth.graphemeWidth(grapheme);
    }
    for (var i = 0; i < padding.trailing; i++) {
      cells.add(buildCell(' ', sweepPos++));
    }
    cells.add(buildCell(' ', sweepPos));

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

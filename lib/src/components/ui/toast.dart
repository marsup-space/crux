import 'dart:async';
import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';

/// A toast notification that auto-closes after a duration.
///
/// The countdown pauses when the mouse hovers over the toast
/// and resumes (from remaining time) when the mouse exits.
///
/// Example:
/// ```dart
/// Toast(
///   message: 'Model switched to openai/gpt-4o',
///   onDismissed: () => hideToast(),
/// )
/// ```
class Toast extends StatefulComponent {
  /// The message text to display.
  final String message;

  /// Callback invoked when the toast auto-closes.
  final VoidCallback? onDismissed;

  /// How long the toast stays visible before auto-closing.
  final Duration duration;

  /// Text style for the message.
  final TextStyle? style;

  /// Background color of the toast.
  final Color bgColor;

  /// Border color of the toast.
  final Color borderColor;

  /// Padding inside the toast.
  final EdgeInsets padding;

  const Toast({
    super.key,
    required this.message,
    this.onDismissed,
    this.duration = const Duration(seconds: 2),
    this.style,
    this.bgColor = CruxTheme.toastBackground,
    this.borderColor = CruxTheme.toastBorder,
    this.padding = const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
  });

  @override
  State<Toast> createState() => _ToastState();
}

class _ToastState extends State<Toast> {
  Timer? _timer;
  DateTime? _timerStartedAt;
  Duration _remaining = const Duration(seconds: 2);
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _remaining = component.duration;
    _startTimer();
  }

  @override
  void didUpdateComponent(Toast oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.duration != component.duration) {
      _remaining = component.duration;
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timerStartedAt = DateTime.now();
    _timer = Timer(_remaining, _dismiss);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timerStartedAt = DateTime.now();
    _timer = Timer(_remaining, _dismiss);
  }

  void _pauseTimer() {
    if (_timerStartedAt != null) {
      final elapsed = DateTime.now().difference(_timerStartedAt!);
      _remaining = component.duration - elapsed;
      if (_remaining.isNegative) {
        _remaining = Duration.zero;
      }
    }
    _timer?.cancel();
  }

  void _resumeTimer() {
    if (_remaining <= Duration.zero) {
      _dismiss();
      return;
    }
    _startTimer();
  }

  void _dismiss() {
    _timer?.cancel();
    component.onDismissed?.call();
  }

  void _onHoverEnter() {
    _hovered = true;
    _pauseTimer();
  }

  void _onHoverExit() {
    _hovered = false;
    _resumeTimer();
  }

  @override
  Component build(BuildContext context) {
    final toast = component;
    final effectiveStyle = TextStyle(
      color: CruxTheme.toastText,
      fontWeight: FontWeight.bold,
    ).merge(toast.style);

    return MouseRegion(
      onEnter: (_) => _onHoverEnter(),
      onExit: (_) => _onHoverExit(),
      opaque: false,
      child: Container(
        color: toast.bgColor,
        padding: toast.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(color: toast.borderColor, height: 1),
            Row(
              children: [
                Text(' ⚡ ', style: TextStyle(color: CruxTheme.toastText)),
                Expanded(child: Text(toast.message, style: effectiveStyle)),
                if (_hovered)
                  Text(
                    ' (paused)',
                    style: TextStyle(color: CruxTheme.hintText),
                  ),
              ],
            ),
            Divider(color: toast.borderColor, height: 1),
          ],
        ),
      ),
    );
  }
}

import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import 'ui/button.dart';
import 'ui/fullpane.dart';

/// Persistent, focused UI for the ChatGPT Codex device authorization flow.
///
/// The device code is intentionally kept visible while OAuth polling runs, so
/// opening the browser never makes the only copy of the code disappear.
class CodexLoginFullpane extends StatelessComponent {
  final String userCode;
  final String verificationUrl;
  final VoidCallback onOpenBrowser;
  final VoidCallback onClose;

  const CodexLoginFullpane({
    required this.userCode,
    required this.verificationUrl,
    required this.onOpenBrowser,
    required this.onClose,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Fullpane(
      title: 'Connect ChatGPT Codex',
      onClose: onClose,
      contentBuilder: (context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sign in with your ChatGPT account',
              style: TextStyle(color: theme.text, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            Text(
              '1. The browser has opened the secure OpenAI verification page.',
              style: TextStyle(color: theme.onSurfaceVariant),
            ),
            Text(
              '2. Sign in, then enter this temporary device code:',
              style: TextStyle(color: theme.onSurfaceVariant),
            ),
            const SizedBox(height: 1),
            Container(
              width: 22,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: BoxDecoration(
                color: theme.buttonBackgroundHover,
                border: BoxBorder.all(color: theme.success),
                borderRadius: BorderRadius.circular(1),
              ),
              child: Center(
                child: Text(
                  userCode,
                  style: TextStyle(
                    color: theme.success,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '3. Return here — Crux is waiting for approval and will finish automatically.',
              style: TextStyle(color: theme.onSurfaceVariant),
            ),
            const SizedBox(height: 1),
            Text(
              'Verification page: $verificationUrl',
              style: TextStyle(color: theme.hintText),
            ),
            const Spacer(),
            Divider(color: theme.outline, height: 1),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Row(
                children: [
                  Button(
                    label: 'Open browser again',
                    onPressed: onOpenBrowser,
                    color: theme.text,
                    hoverColor: theme.foreground,
                    bgColor: theme.surface,
                    hoverBgColor: theme.buttonBackgroundHover,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'Waiting for ChatGPT approval…',
                    style: TextStyle(color: theme.warning),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

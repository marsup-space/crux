/// Chat-log bubble for a submitted A2UI surface action.
///
/// Rendered in place of the normal user message when the message content
/// parses as a surface action (`action: ...` / `surface: ...` lines, see
/// [A2uiAction.tryParseDisplayString]). The raw serialized action is still
/// what goes to the agent (and what lands in the message store); this
/// bubble is purely the user-facing recap — a compact chip plus the
/// submitted values, mirroring how [AskAnswerBubble] recaps form answers.
library;

import 'package:nocterm/nocterm.dart';

import '../services/a2ui/models.dart';
import '../theme/crux_theme.dart';

class SurfaceActionBubble extends StatelessComponent {
  final A2uiAction action;

  const SurfaceActionBubble({super.key, required this.action});

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    // One compact line: the user only needs to see THAT they submitted —
    // WHAT they submitted is frozen into the surface itself (rendered
    // read-only above in the chat flow).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            ' Surface ',
            style: TextStyle(
              color: theme.buttonTextFocused,
              fontWeight: FontWeight.bold,
              backgroundColor: theme.buttonBackground,
            ),
          ),
          Expanded(
            child: Text(
              ' ${action.name} · ${action.surfaceId}',
              style: TextStyle(color: theme.hintText),
            ),
          ),
        ],
      ),
    );
  }
}

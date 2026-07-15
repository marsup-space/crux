import 'package:test/test.dart';

import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/session_runtime_state.dart';

void main() {
  test('chat display mode defaults to vibe across session models', () {
    expect(Session(id: 1).chatDisplayMode, ChatDisplayMode.vibe);
    expect(
      SessionRuntimeState(sessionId: 1).chatDisplayMode,
      ChatDisplayMode.vibe,
    );
  });

  test('callers can still explicitly select verbose mode', () {
    expect(
      Session(id: 1, chatDisplayMode: ChatDisplayMode.verbose).chatDisplayMode,
      ChatDisplayMode.verbose,
    );
    expect(
      SessionRuntimeState(
        sessionId: 1,
        chatDisplayMode: ChatDisplayMode.verbose,
      ).chatDisplayMode,
      ChatDisplayMode.verbose,
    );
  });
}

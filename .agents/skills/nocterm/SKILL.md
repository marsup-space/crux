---
name: nocterm
description: >
  Debug, test, and interact with nocterm-based TUI (Terminal User Interface) apps
  using the headless test harness. Use this skill whenever you need to debug a
  nocterm/Dart TUI app, write integration tests, simulate user input (keyboard/mouse),
  inspect screen output, or verify component behavior. Trigger on: debugging TUI
  layout issues, testing keyboard/mouse interactions, writing nocterm tests, verifying
  component rendering, or any "how do I test/debug my TUI" question.
---

# Nocterm TUI Debugging & Testing

## Core Concept

Nocterm apps run in a terminal, not a GUI. Flutter-specific tools (widget tree, flutter_driver, DTD) **do not work**. Instead, use nocterm's built-in **headless test harness** (`testNocterm`) which runs the app with a mock terminal backend — no real stdin/stdout needed.

## Test Framework Overview

| Feature | API | Purpose |
|---|---|---|
| Test runner | `testNocterm('name', (tester) async { ... })` | Creates headless app scope with auto cleanup |
| Custom size | `testNocterm('name', callback, size: Size(120, 40))` | Test at specific terminal dimensions |
| Render component | `tester.pumpComponent(MyComponent())` | Mount a component and render one frame |
| Advance frames | `tester.pump()` or `tester.pump(duration)` | Re-render after state changes |
| Settle | `tester.pumpAndSettle()` | Render until no more scheduled frames |
| Keyboard input | `tester.sendKey(LogicalKey.enter)` | Send a single key press |
| Keyboard with char | `tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.keyA, character: 'a'))` | Send key with character payload |
| Type text | `tester.enterText('hello')` | Simulate typing a string |
| Common keys | `tester.sendEnter()`, `sendEscape()`, `sendTab()` | Convenience methods |
| Mouse tap | `tester.tap(x, y)` | Click at terminal coordinates (press + release) |
| Mouse hover | `tester.hover(x, y)` | Move mouse to coordinates |
| Press/release | `tester.press(x, y)`, `tester.release(x, y)` | Separate press and release |
| Drag | `tester.mouseMove(x1, y1, x2, y2)` | Simulate mouse drag |
| Read screen text | `tester.terminalState.getText()` | Get all visible text |
| Find text | `tester.terminalState.findText('pattern')` | Search for text with positions |
| Contains text | `tester.terminalState.containsText('needle')` | Boolean text search |
| Cell inspection | `tester.terminalState.getCellAt(x, y)` | Get individual cell (char + style) |
| Visual dump | `tester.renderToString(showBorders: true)` | Bordered visual representation of screen |
| Snapshot | `tester.toSnapshot()` | Compact dot-for-space representation |
| Find state | `tester.findState<MyState>()` | Access internal state of a StatefulComponent |
| Find component | `tester.findComponent<MyComponent>()` | Find a component by type |
| Matchers | `containsText('x')`, `hasTextAt(x,y,'x')`, `matchesSnapshot()` | Custom matchers for expect() |

## Import Pattern

```dart
import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
```

Note: `nocterm_test.dart` is a separate import from `nocterm.dart`. It exports testing utilities, keyboard/mouse event types, and matchers.

## Best Practices

### 1. Always Wrap in a Full-Size Container

Components tested without a parent container may not have proper layout constraints. Always wrap your test component in `Container(width: 80, height: 24)` (or your desired terminal size):

```dart
await tester.pumpComponent(
  Container(
    width: 80,
    height: 24,
    child: MyComponent(),
  ),
);
```

This is especially important for mouse/tap interactions — hit testing depends on the component having defined bounds.

### 2. Use `sendKeyEvent` for Character Input, Not `sendKey`

`sendKey(LogicalKey.keyA)` sends a key event **without a character**. To simulate typing a letter, use `sendKeyEvent` with both `logicalKey` and `character`:

```dart
await tester.sendKeyEvent(KeyboardEvent(
  logicalKey: LogicalKey.keyA,
  character: 'a',
));
```

Or use `enterText('abc')` which types a whole string character-by-character.

### 3. Use `renderToString()` to Debug Layout Issues

When a test fails or you need to understand what's on screen, use `renderToString(showBorders: true)`:

```dart
final visual = tester.renderToString(showBorders: true);
print(visual);
```

This produces a bordered ASCII art representation of the terminal screen. Use `showBorders: false` for raw content.

### 4. Use `findState<T>()` to Inspect Internal State

You can access a component's internal state directly:

```dart
final state = tester.findState<_MyState>();
expect(state.counter, equals(0));
await tester.sendKey(LogicalKey.space);
expect(state.counter, equals(1));
```

This is invaluable for verifying state transitions without relying solely on screen output.

### 5. Determine Tap Coordinates from Layout

Terminal coordinates are (x, y) where (0, 0) is top-left. To find the right coordinates:
- Use `renderToString()` to see the visual layout
- Use `terminalState.findText('label')` to get text positions
- Count rows from top: each `Text`, `Divider`, `Container` occupies rows

### 6. Test Keyboard-Driven UIs First

TUI apps are primarily keyboard-driven. Prioritize testing:
- Key presses and their effect on state
- Focus navigation (Tab, arrows)
- Command overlays and selection
- Text input and submission

### 7. MouseRegion with `opaque: false` Needs Care

`MouseRegion(opaque: false)` doesn't always receive hover events in the test environment. If hover-dependent features fail, verify by:
- Wrapping in a full-size Container parent
- Using `tap()` instead of `hover()` for verification
- Using `findState()` to check internal `_hovered` state

### 8. Async Operations Need `pumpAndSettle()`

If your component uses timers (e.g., Toast auto-dismiss), use `pumpAndSettle()` or `pump(duration)` to advance time:

```dart
await tester.pumpComponent(Toast(message: 'Saved', duration: Duration(seconds: 2)));
await tester.pumpAndSettle();
```

### 9. Component Dependencies

For complex components (like ChatPanel) that depend on databases, services, or external I/O:
- Extract the pure UI component and test it separately
- Mock or inject services via constructor parameters
- Test the component's build output, not its side effects

### 10. Use Type Annotations for Collections

Nocterm types like `SlashCommand` need explicit type annotations to avoid inference issues:

```dart
final commands = <SlashCommand>[
  SlashCommand(name: '/model', description: 'Switch model'),
];
```

## Complete Test Template

```dart
import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';

void main() {
  group('MyComponent', () {
    test('renders correctly', () async {
      await testNocterm('my component renders', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: MyComponent(),
          ),
        );

        expect(tester.terminalState, containsText('expected text'));

        final visual = tester.renderToString(showBorders: true);
        print(visual);
      });
    });

    test('responds to keyboard input', () async {
      await testNocterm('my component keys', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: MyComponent(),
          ),
        );

        final state = tester.findState<_MyComponentState>();
        expect(state.value, equals(0));

        await tester.sendKey(LogicalKey.space);
        expect(state.value, equals(1));
        expect(tester.terminalState, containsText('Value: 1'));
      });
    });

    test('responds to mouse tap', () async {
      await testNocterm('my component tap', (tester) async {
        var tapped = false;

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: GestureDetector(
              onTap: () => tapped = true,
              child: Container(
                width: 10,
                height: 3,
                child: const Text('Click'),
              ),
            ),
          ),
        );

        await tester.tap(5, 1);
        expect(tapped, isTrue);
      });
    });
  });
}
```

## AI Agent Debugging Workflow

When debugging a TUI app as an AI agent:

1. **Identify the component** — Find the relevant component file in `lib/src/components/`
2. **Write a test** — Create a `test/tui_test.dart` with `testNocterm` covering the issue
3. **Run the test** — Use `dart test test/tui_test.dart`
4. **Read the visual output** — Use `renderToString()` to see what's on screen
5. **Inspect state** — Use `findState<T>()` to check internal variables
6. **Simulate user actions** — Use `sendKey()`, `enterText()`, `tap()` to trigger behavior
7. **Verify fix** — Re-run tests after code changes

## Key Limitations

- No real terminal output — tests run headlessly
- `renderToString()` shows character content but not ANSI colors visually
- Mouse hover on `MouseRegion(opaque: false)` may not route correctly
- Timer-based features (auto-dismiss, animations) need `pumpAndSettle()` or explicit `pump(duration)`
- `sendKey()` without `character` won't trigger character-based handlers

## Reference Files

- Test harness: `nocterm/lib/src/test/nocterm_tester.dart`
- Terminal state: `nocterm/lib/src/test/terminal_state.dart`
- Matchers: `nocterm/lib/src/test/matchers.dart`
- Test binding: `nocterm/lib/src/test/nocterm_test_binding.dart`
- Example tests: `nocterm/test/regression/simple_test.dart`, `nocterm/test/input/gesture_detector_test.dart`
- Working test: `test/tui_test.dart`
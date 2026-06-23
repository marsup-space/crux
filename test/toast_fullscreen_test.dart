import 'package:crux/crux.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  // Regression tests: toasts must not fill the full screen.
  //
  // Background. The toast is wrapped in a `Positioned(bottom: 0, left: 0,
  // right: 0)` inside a `Stack(fit: StackFit.expand, ...)`. The Positioned
  // tells the Stack to give the toast a tight width but unbounded height,
  // and the toast shrink-wraps to its content.
  //
  // What was breaking: `ToastHub` used to return `const SizedBox()` when
  // empty and `MouseRegion(child: Container(...))` once a toast arrived.
  // That swap changed the render object attached to the Stack, and the
  // new render object didn't inherit the `Positioned`'s parentData. The
  // Stack then treated the new render object as a non-positioned child
  // and gave it tight constraints under `StackFit.expand` — so the toast
  // bordered Container expanded to fill the entire Stack (the full
  // terminal height) until the next layout pass happened to reapply the
  // parentData.
  //
  // The fix: `ToastHub` always returns a `MouseRegion` (with empty
  // callbacks when there's no toast), so the render object identity is
  // stable across rebuilds and the `Positioned`'s parentData stays valid.

  Component toastHost(GlobalKey<ToastHubState> toastKey) {
    // Mirrors the chat panel's overlay setup: the toast lives inside a
    // `Positioned(bottom: 0, left: 0, right: 0)` inside a Stack that has
    // a non-positioned sibling (ChatHistory in production, SizedBox here)
    // so the Stack has a finite size to anchor against.
    return SizedBox(
      width: 80,
      height: 24,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const SizedBox(),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ToastHub(key: toastKey),
          ),
        ],
      ),
    );
  }

  int nonEmptyLineCount(String rendered) {
    return rendered
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .length;
  }

  test('error toast does not fill full screen', () async {
    await testNocterm('error toast shrink-wraps', (tester) async {
      final toastKey = GlobalKey<ToastHubState>();
      await tester.pumpComponent(toastHost(toastKey));

      // Surface a long error message — exactly the kind of error toast
      // that previously ate the whole screen.
      toastKey.currentState?.show(
        'a very long error message that contains '
        'a lot of text describing what went wrong and giving context '
        'to the user so they can understand and act on it',
        mode: ToastMode.error,
      );
      await tester.pump();

      final rendered = tester.renderToString(showBorders: false);
      // The toast must NOT cover more than ~6 lines (main row + copy
      // button + padding/border). Before the fix, the bordered Container
      // expanded to fill all 24 lines and these expectations all broke.
      expect(
        nonEmptyLineCount(rendered),
        lessThanOrEqualTo(6),
        reason:
            'error toast should shrink-wrap to a few lines, '
            'but rendered ${nonEmptyLineCount(rendered)} non-empty lines:\n'
            '$rendered',
      );
      // And the message itself should actually be visible (truncated with
      // ellipsis when needed).
      expect(rendered, contains('a very long error message'));
    });
  });

  test('info toast also shrink-wraps (does not fill full screen)',
      () async {
    await testNocterm('info toast shrink-wraps', (tester) async {
      final toastKey = GlobalKey<ToastHubState>();
      await tester.pumpComponent(toastHost(toastKey));
      toastKey.currentState?.show('hello', mode: ToastMode.info);
      await tester.pump();

      final rendered = tester.renderToString(showBorders: false);
      expect(nonEmptyLineCount(rendered), lessThanOrEqualTo(3));
      expect(rendered, contains('hello'));
    });
  });

  test('status toast also shrink-wraps (does not fill full screen)',
      () async {
    await testNocterm('status toast shrink-wraps', (tester) async {
      final toastKey = GlobalKey<ToastHubState>();
      await tester.pumpComponent(toastHost(toastKey));
      toastKey.currentState?.show('saved', mode: ToastMode.status);
      await tester.pump();

      final rendered = tester.renderToString(showBorders: false);
      expect(nonEmptyLineCount(rendered), lessThanOrEqualTo(3));
      expect(rendered, contains('saved'));
    });
  });

  test('empty toast does not paint anything visible', () async {
    await testNocterm('empty toast is invisible', (tester) async {
      final toastKey = GlobalKey<ToastHubState>();
      // Pump the host, then `pump()` again without ever calling `show()`.
      // This is the initial state that previously caused the bad render
      // object to be replaced as soon as the first toast arrived.
      await tester.pumpComponent(toastHost(toastKey));
      await tester.pump();

      final rendered = tester.renderToString(showBorders: false);
      // No bordered box, no message text — just the empty SizedBox below.
      expect(rendered, isNot(contains('╭')));
      expect(rendered, isNot(contains('╮')));
      expect(rendered, isNot(contains('╰')));
      expect(rendered, isNot(contains('╯')));
    });
  });

  test(
      'showing an error after a status toast (and vice versa) still '
      'shrink-wraps', () async {
    await testNocterm('toast mode transitions', (tester) async {
      final toastKey = GlobalKey<ToastHubState>();
      await tester.pumpComponent(toastHost(toastKey));

      toastKey.currentState?.show('ready', mode: ToastMode.status);
      await tester.pump();
      expect(
        nonEmptyLineCount(tester.renderToString(showBorders: false)),
        lessThanOrEqualTo(3),
      );

      // Wait for the 2s status toast to expire before queueing another.
      await tester.pump(const Duration(seconds: 3));

      toastKey.currentState?.show('boom', mode: ToastMode.error);
      await tester.pump();
      final rendered = tester.renderToString(showBorders: false);
      expect(nonEmptyLineCount(rendered), lessThanOrEqualTo(6));
      expect(rendered, contains('boom'));
    });
  });
}
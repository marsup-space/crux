// Visual tests for the shell-monitor toast: the intent phrase is the
// headline, the aux verdict gets its own loud row, evidence dims
// under it, and the kill entry is an unmistakable "[ click to kill ]"
// bracket button. Pressing it freezes the toast as a "✓ killed"
// incident record that later reports cannot replace.
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/ui/toast.dart';

Component toastHost(GlobalKey<ToastHubState> toastKey) => Stack(
      children: [
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: ToastHub(key: toastKey),
        ),
      ],
    );

void main() {
  group('monitor toast', () {
    test('renders intent headline, verdict row and bracket kill button',
        () async {
      await testNocterm('standing monitor toast', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        var killCalls = 0;
        await tester.pumpComponent(toastHost(toastKey));
        toastKey.currentState?.showMonitorToast(
          MonitorToastData(
            title: 'install dependencies',
            subtitle: 'dart pub get',
            verdict: 'PROGRESS',
            verdictText: 'aux: making progress — next check in 30s',
            takeaway: 'linker still running · » Resolving 42 packages…',
            onKill: () async {
              killCalls++;
              return true;
            },
          ),
        );
        await tester.pump();

        final rendered = tester.renderToString(showBorders: false);
        // Intent is the headline.
        expect(rendered, contains('install dependencies'));
        // The verdict sentence is rendered verbatim.
        expect(rendered, contains('aux: making progress — next check in 30s'));
        // Evidence row.
        expect(rendered, contains('Resolving 42 packages'));
        // The kill affordance reads as a button.
        expect(rendered, contains('[ click to kill ]'));

        // Trigger the kill (same path the button's onPressed runs):
        // the action runs and the toast freezes as a killed record.
        await toastKey.currentState?.pressMonitorKill();
        await tester.pump();
        expect(killCalls, 1);
        final killed = tester.renderToString(showBorders: false);
        expect(killed, contains('killed'));
      });
    });

    test('verdict tone maps to modes (STUCK → error palette)', () {
      expect(monitorVerdictMode('STUCK'), ToastMode.error);
      expect(monitorVerdictMode('PROGRESS'), ToastMode.status);
      expect(monitorVerdictMode('UNCERTAIN'), ToastMode.info);
      expect(monitorVerdictMode('EVAL_ERROR'), ToastMode.info);
      expect(monitorVerdictMode('FALLBACK'), ToastMode.info);
      expect(monitorVerdictMode('CONFIGURED'), ToastMode.info);
    });

    test('double-press fires the kill action only once', () async {
      await testNocterm('kill idempotence', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        var killCalls = 0;
        await tester.pumpComponent(toastHost(toastKey));
        toastKey.currentState?.showMonitorToast(
          MonitorToastData(
            title: 'run migrations',
            verdict: 'UNCERTAIN',
            verdictText: 'aux: uncertain — next check in 15s',
            onKill: () async {
              killCalls++;
              return true;
            },
          ),
        );
        await tester.pump();
        await toastKey.currentState?.pressMonitorKill();
        await tester.pump();
        // Second press: the toast is frozen (killed) — the action
        // must not run again.
        final second = await toastKey.currentState?.pressMonitorKill();
        await tester.pump();
        expect(killCalls, 1);
        expect(second, isTrue); // a monitor toast is still present…
        // …but frozen, so the action stayed at exactly one call.
      });
    });

    test('a frozen (killed) record is not replaced by newer reports',
        () async {
      await testNocterm('frozen killed record', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        await tester.pumpComponent(toastHost(toastKey));
        toastKey.currentState?.showMonitorToast(
          MonitorToastData(
            title: 'old build',
            verdict: 'PROGRESS',
            verdictText: 'aux: making progress — next check in 60s',
            onKill: () async => true,
          ),
        );
        await tester.pump();
        await toastKey.currentState?.pressMonitorKill();
        await tester.pump();

        // A newer monitor report for the SAME standing slot arrives —
        // it must NOT displace the frozen record (the old process is
        // dead; the report belongs to a run that no longer exists).
        toastKey.currentState?.showMonitorToast(
          MonitorToastData(
            title: 'new build',
            verdict: 'PROGRESS',
            verdictText: 'aux: making progress — next check in 60s',
            onKill: () async => true,
          ),
        );
        await tester.pump();
        final rendered = tester.renderToString(showBorders: false);
        expect(rendered, contains('old build'));
        expect(rendered, isNot(contains('new build')));
      });
    });

    test('pressMonitorKill on a plain toast is a no-op', () async {
      await testNocterm('plain toast still works', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        await tester.pumpComponent(toastHost(toastKey));
        toastKey.currentState?.show('hello', mode: ToastMode.info);
        await tester.pump();
        final ran = await toastKey.currentState?.pressMonitorKill();
        expect(ran, isFalse);
        final rendered = tester.renderToString(showBorders: false);
        expect(rendered, contains('hello'));
        expect(rendered, isNot(contains('click to kill')));
      });
    });
  });
}

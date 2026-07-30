import 'package:crux/src/utils/duration_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatAgentTurnGap', () {
    test('under 30s renders as "just now"', () {
      expect(formatAgentTurnGap(Duration.zero), 'just now');
      expect(formatAgentTurnGap(Duration(seconds: 5)), 'just now');
      expect(formatAgentTurnGap(Duration(seconds: 29)), 'just now');
    });

    test('under a minute still rounds to "just now"', () {
      // 59 seconds is technically < 1 minute but we cap at the
      // 30s mark and treat anything between as "just now" — a
      // literal "0 minutes ago" reads worse and is the same
      // information.
      expect(formatAgentTurnGap(Duration(seconds: 45)), 'just now');
      expect(formatAgentTurnGap(Duration(seconds: 59)), 'just now');
    });

    test('under an hour renders as "X minutes ago"', () {
      expect(formatAgentTurnGap(Duration(minutes: 1)), '1 minutes ago');
      expect(formatAgentTurnGap(Duration(minutes: 5)), '5 minutes ago');
      expect(formatAgentTurnGap(Duration(minutes: 30)), '30 minutes ago');
      expect(formatAgentTurnGap(Duration(minutes: 59)), '59 minutes ago');
    });

    test('under a day renders as "X hours Y minutes ago"', () {
      expect(formatAgentTurnGap(Duration(hours: 1)), '1 hours ago');
      expect(
        formatAgentTurnGap(Duration(hours: 1, minutes: 5)),
        '1 hours 5 minutes ago',
      );
      expect(
        formatAgentTurnGap(Duration(hours: 5, minutes: 30)),
        '5 hours 30 minutes ago',
      );
      expect(
        formatAgentTurnGap(Duration(hours: 23, minutes: 59)),
        '23 hours 59 minutes ago',
      );
    });

    test('multi-day renders with the "X days and Y hours Z minutes" shape', () {
      expect(
        formatAgentTurnGap(Duration(days: 1, hours: 2, minutes: 14)),
        '1 days and 2 hours 14 minutes ago',
      );
      expect(
        formatAgentTurnGap(Duration(days: 3, hours: 7, minutes: 5)),
        '3 days and 7 hours 5 minutes ago',
      );
      // Cumulative breakdown: 49h30m floors to 2 days 1h 30m, not
      // 1 day 25h 30m. Matches the conventional "X days ago"
      // reading and what most chat UIs do.
      expect(
        formatAgentTurnGap(Duration(hours: 49, minutes: 30)),
        '2 days and 1 hours 30 minutes ago',
      );
    });

    test('whole-day or whole-hour gaps drop the smaller unit', () {
      expect(formatAgentTurnGap(Duration(days: 2)), '2 days ago');
      expect(
        formatAgentTurnGap(Duration(days: 2, minutes: 30)),
        '2 days and 0 hours 30 minutes ago',
      );
      expect(formatAgentTurnGap(Duration(hours: 5)), '5 hours ago');
    });
  });
}

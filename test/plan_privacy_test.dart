// Plan-context privacy (plan 'test run.md', work item B): the raw
// `<plan-context>` block must never render in the user bubble. Verbose
// mode collapses it to a plain dim marker; vibe mode (the segment
// walker + scrollbar labels) routes through `stripPlanContext` too.
// The persisted `llmText` still carries the block — this is a
// display-layer change only.

import 'package:crux/src/components/message_bubble.dart';
import 'package:crux/src/i18n/strings.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/utils/strip_skill_bodies.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

const planBlock = '<plan-context>\n'
    'plan_path: PLAN.md\n'
    'mode: follow\n'
    'viewing_version: 3\n'
    'head_version: 7\n'
    'approved: false\n'
    'viewport_lines: 40..72\n'
    '</plan-context>';

void main() {
  group('stripPlanContext (unit)', () {
    test('strips a trailing block and reports it', () {
      final out = stripPlanContext('Please fix the bug\n\n$planBlock');
      expect(out.stripped, isTrue);
      expect(out.text, 'Please fix the bug');
    });

    test('leaves a message without a block untouched', () {
      final out = stripPlanContext('Just a normal message');
      expect(out.stripped, isFalse);
      expect(out.text, 'Just a normal message');
    });

    test('does not strip a non-trailing occurrence', () {
      final mid = '<plan-context>\nx\n</plan-context>\nmore text';
      final out = stripPlanContext(mid);
      expect(out.stripped, isFalse);
      expect(out.text, mid);
    });

    test('strips a block after appended skill bodies', () {
      // Skill bodies are appended BEFORE the plan-context block in the
      // persisted llmText. stripSkillBodies cuts at the first
      // `\n\nSkill: ` marker — everything after (bodies + plan block)
      // goes — so stripPlanContext finds nothing trailing. The net
      // display text is the user's prose either way; assert that.
      final content = 'Do it\n\nSkill: widget\nbody text\n\n$planBlock';
      final out = stripPlanContext(stripSkillBodies(content));
      expect(out.text, 'Do it');
      expect(out.stripped, isFalse,
          reason: 'the skill strip already removed the trailing content');

      // Without skill bodies the plan strip owns the tail.
      final solo = stripPlanContext('Do it\n\n$planBlock');
      expect(solo.stripped, isTrue);
      expect(solo.text, 'Do it');
    });
  });

  group('verbose user bubble', () {
    test('renders without the block and shows the plain marker', () async {
      final message = Message(
        id: 1,
        sessionId: 1,
        role: 'user',
        content: 'Please fix the bug\n\n$planBlock',
      );

      await testNocterm('user bubble hides plan context', (tester) async {
        await tester.pumpComponent(
          _Host(
            child: MessageBubble(message: message, strings: kEnglishStrings),
          ),
        );
        final state = tester.terminalState;
        expect(state.containsText('Please fix the bug'), isTrue);
        expect(state.containsText('plan_path'), isFalse);
        expect(state.containsText('<plan-context>'), isFalse);
        expect(state.containsText('plan context attached'), isTrue);
      }, size: const Size(60, 12));
    });

    test('message without a block is unchanged', () async {
      final message = Message(
        id: 1,
        sessionId: 1,
        role: 'user',
        content: 'Plain text only',
      );

      await testNocterm('plain user bubble', (tester) async {
        await tester.pumpComponent(
          _Host(
            child: MessageBubble(message: message, strings: kEnglishStrings),
          ),
        );
        expect(tester.terminalState.containsText('Plain text only'), isTrue);
        expect(
          tester.terminalState.containsText('plan context attached'),
          isFalse,
        );
      }, size: const Size(60, 12));
    });
  });
}

class _Host extends StatelessComponent {
  final Component child;
  const _Host({required this.child});

  @override
  Component build(BuildContext context) {
    return SizedBox(width: 60, height: 12, child: child);
  }
}

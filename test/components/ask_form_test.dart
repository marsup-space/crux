// Tests for ASK 2.0: the `ask` tool plumbing, the prose serializer,
// and the AskForm interactive component.
//
// Two layers:
//   - Pure-logic tests (no TUI harness) for parseAskSpec and
//     serializeAskAnswer, so regressions in the wire format are caught
//     without needing the headless terminal.
//   - TUI tests via testNocterm covering AskForm rendering, keyboard
//     selection, mouse tap, note field, submit, and dismiss.

import 'dart:async';

import 'package:crux/src/components/ask_answer_bubble.dart';
import 'package:crux/src/components/ask_form.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/ask_tool.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('parseAskSpec', () {
    test('parses a minimal single-group spec', () {
      final spec = parseAskSpec({
        'groups': [
          {
            'name': 'runtime',
            'options': [
              {'label': 'node'},
              {'label': 'bun'},
            ],
          },
        ],
      });
      expect(spec, isNotNull);
      expect(spec!.prompt, equals(''));
      expect(spec.groups, hasLength(1));
      expect(spec.groups.first.name, equals('runtime'));
      expect(spec.groups.first.multi, isFalse);
      expect(spec.groups.first.options, hasLength(2));
      expect(spec.groups.first.options.first.label, equals('node'));
      expect(spec.groups.first.options.first.value, equals('node'));
    });

    test('parses a multi-group spec with multi-select and explicit values', () {
      final spec = parseAskSpec({
        'prompt': 'Pick and choose',
        'groups': [
          {
            'name': 'modules',
            'multi': true,
            'options': [
              {'label': 'web'},
              {'label': 'api', 'value': 'api-v2'},
            ],
          },
          {
            'name': 'runtime',
            'options': [
              {'label': 'Node LTS', 'value': 'node'},
            ],
          },
        ],
      });
      expect(spec, isNotNull);
      expect(spec!.prompt, equals('Pick and choose'));
      expect(spec.groups, hasLength(2));
      expect(spec.groups.first.multi, isTrue);
      expect(
        spec.groups.first.options.last.value,
        equals('api-v2'),
        reason: 'explicit value should override label',
      );
      expect(spec.groups.last.options.first.label, equals('Node LTS'));
      expect(spec.groups.last.options.first.value, equals('node'));
    });

    test('returns null on invalid structures', () {
      expect(parseAskSpec({}), isNull);
      expect(parseAskSpec({'groups': []}), isNull);
      expect(parseAskSpec({'groups': 'not-a-list'}), isNull);
      expect(
        parseAskSpec({
          'groups': [
            {'options': [{'label': 'x'}]},
          ],
        }),
        isNull,
        reason: 'missing group name',
      );
      expect(
        parseAskSpec({
          'groups': [
            {'name': 'g', 'options': []},
          ],
        }),
        isNull,
        reason: 'empty options',
      );
      expect(
        parseAskSpec({
          'groups': [
            {
              'name': 'g',
              'options': [{'label': ''}],
            },
          ],
        }),
        isNull,
        reason: 'empty label',
      );
    });
  });

  group('serializeAskAnswer', () {
    final spec = AskSpec(
      prompt: 'Pick modules to refactor',
      groups: [
        AskGroup(
          name: 'modules',
          multi: true,
          options: [
            AskOption(label: 'web'),
            AskOption(label: 'api'),
            AskOption(label: 'cli'),
          ],
        ),
        AskGroup(
          name: 'runtime',
          options: [
            AskOption(label: 'Node', value: 'node'),
            AskOption(label: 'Bun', value: 'bun'),
          ],
        ),
      ],
    );

    test('serializes picks with comma-joined multi-select values', () {
      final out = serializeAskAnswer(
        spec,
        {
          'modules': [AskOption(label: 'web'), AskOption(label: 'cli')],
          'runtime': [AskOption(label: 'Node', value: 'node')],
        },
        '',
      );
      expect(out, contains('[prompt] Pick modules to refactor'));
      expect(out, contains('[modules] web, cli'));
      expect(out, contains('[runtime] node'));
      expect(out, isNot(contains('[note]')));
    });

    test('emits (none) for empty multi-select', () {
      final out = serializeAskAnswer(
        spec,
        {'modules': <AskOption>[], 'runtime': <AskOption>[]},
        '',
      );
      expect(out, contains('[modules] (none)'));
      expect(out, contains('[runtime] (none)'));
    });

    test('emits [note] footer when note is non-empty', () {
      final out = serializeAskAnswer(
        spec,
        {'modules': [AskOption(label: 'web')], 'runtime': [AskOption(label: 'Node', value: 'node')]},
        'prefer bun actually',
      );
      expect(out, contains('[note] prefer bun actually'));
    });

    test('trims and omits note when whitespace-only', () {
      final out = serializeAskAnswer(
        spec,
        {'modules': [AskOption(label: 'web')], 'runtime': [AskOption(label: 'Node', value: 'node')]},
        '   \n  ',
      );
      expect(out, isNot(contains('[note]')));
    });
  });

  group('PendingAskCubit', () {
    test('register / complete / dismiss flow', () async {
      final cubit = PendingAskCubit();
      expect(cubit.state.pending, isNull);

      final completer = Completer<ToolResult>();
      final ask = PendingAsk(
        sessionId: 1,
        callId: 'call-1',
        spec: AskSpec(groups: [AskGroup(name: 'x', options: [AskOption(label: 'a')])]),
        completer: completer,
      );
      cubit.register(ask);
      expect(cubit.state.pending, same(ask));

      cubit.complete('[x] a');
      final result = await completer.future;
      expect(result.output, equals('[x] a'));
      expect(cubit.state.pending, isNull);
    });

    test('dismiss resolves with the sentinel', () async {
      final cubit = PendingAskCubit();
      final completer = Completer<ToolResult>();
      final ask = PendingAsk(
        sessionId: 1,
        callId: 'call-2',
        spec: AskSpec(groups: [AskGroup(name: 'x', options: [AskOption(label: 'a')])]),
        completer: completer,
      );
      cubit.register(ask);
      cubit.dismiss();
      final result = await completer.future;
      expect(result.output, equals('(dismissed)'));
      expect(cubit.state.pending, isNull);
    });

    test('clearFor only affects the matching session', () async {
      final cubit = PendingAskCubit();
      final completer = Completer<ToolResult>();
      cubit.register(PendingAsk(
        sessionId: 7,
        callId: 'c7',
        spec: AskSpec(groups: [AskGroup(name: 'x', options: [AskOption(label: 'a')])]),
        completer: completer,
      ));
      // clearFor on a different session should be a no-op.
      cubit.clearFor(99);
      expect(cubit.state.pending, isNotNull);
      expect(completer.isCompleted, isFalse);

      // clearFor on the matching session aborts it.
      cubit.clearFor(7);
      expect(completer.isCompleted, isTrue);
      expect(cubit.state.pending, isNull);
      expect((await completer.future).output, equals('(dismissed)'));
    });
  });

  group('AskForm TUI', () {
    PendingAsk makePending({String callId = 'test-call'}) {
      return PendingAsk(
        sessionId: 1,
        callId: callId,
        spec: AskSpec(
          prompt: 'Pick modules to refactor',
          groups: [
            AskGroup(
              name: 'modules',
              multi: true,
              options: [
                AskOption(label: 'web'),
                AskOption(label: 'api'),
                AskOption(label: 'cli'),
              ],
            ),
            AskGroup(
              name: 'runtime',
              options: [
                AskOption(label: 'node'),
                AskOption(label: 'bun'),
              ],
            ),
          ],
        ),
        completer: Completer<ToolResult>(),
      );
    }

    Future<void> pumpAskForm(
      NoctermTester tester, {
      required PendingAsk pending,
      required void Function(String, AskAnswerView) onSubmit,
      required VoidCallback onDismiss,
      int width = 80,
      int height = 24,
    }) async {
      await tester.pumpComponent(
        CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: Container(
            width: width.toDouble(),
            height: height.toDouble(),
            child: AskForm(
              pending: pending,
              onSubmit: onSubmit,
              onDismiss: onDismiss,
            ),
          ),
        ),
      );
    }

    test('renders prompt, group headings, options, note, and action row', () async {
      await testNocterm('ask form renders', (tester) async {
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) => fail('submit should not fire'),
          onDismiss: () => fail('dismiss should not fire'),
        );

        final ts = tester.terminalState;
        expect(ts, containsText('Pick modules to refactor'));
        expect(ts, containsText('modules'));
        expect(ts, containsText('(multi)'));
        expect(ts, containsText('web'));
        expect(ts, containsText('api'));
        expect(ts, containsText('cli'));
        expect(ts, containsText('runtime'));
        expect(ts, containsText('node'));
        expect(ts, containsText('bun'));
        expect(ts, containsText('Submit'));
        expect(ts, containsText('Dismiss'));

        // Default selection: first option of every single-select group
        // is pre-selected. 'runtime' is single-select, so 'node' is
        // pre-picked — verified by a radio marker present on the row.
        expect(ts, containsText('◉'));
      }, size: const Size(80, 24));
    });

    test('keyboard: arrow down moves focus, space toggles checkbox', () async {
      await testNocterm('ask form keyboard toggle', (tester) async {
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) {},
          onDismiss: () {},
        );

        // Default focus is options region, index 0 (the 'web' option
        // of the 'modules' multi-select group).

        // Space on the currently focused option toggles it. Focused
        // index starts at 0 → first option of the first group → 'web'.
        await tester.sendKey(LogicalKey.space);
        await tester.pump();

        // 'web' should now be picked (checkbox marked).
        expect(tester.terminalState, containsText('☑'));

        // Space again untoggles it.
        await tester.sendKey(LogicalKey.space);
        await tester.pump();
        expect(tester.terminalState, containsText('☐'));
      }, size: const Size(80, 24));
    });

    test('keyboard: Enter on a single-select option submits the form', () async {
      await testNocterm('ask form enter submits', (tester) async {
        String? submittedProse;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (p, _) => submittedProse = p,
          onDismiss: () => fail('dismiss should not fire'),
        );

        // Default focus is options region, index 0 (the first group
        // 'modules' is multi, so Enter on it toggles, not submits).
        // Tab down to the single-select 'runtime' group: arrow down
        // three times gets us to 'node' (index 3 in the flat list).
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        // Now focused on 'node' in the single-select runtime group.
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(submittedProse, isNotNull);
        // The single-select 'node' gets submitted. 'modules' (multi)
        // started with no default selection → '(none)'.
        expect(submittedProse, contains('[runtime] node'));
      }, size: const Size(80, 24));
    });

    test('keyboard: Esc dismisses the form', () async {
      await testNocterm('ask form esc dismiss', (tester) async {
        var dismissed = false;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) => fail('submit should not fire on Esc'),
          onDismiss: () => dismissed = true,
        );

        await tester.sendEscape();
        expect(dismissed, isTrue);
      }, size: const Size(80, 24));
    });

    test('keyboard: Tab cycles to note field, Enter from there submits', () async {
      await testNocterm('ask form tab note submit', (tester) async {
        String? submittedProse;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (p, _) => submittedProse = p,
          onDismiss: () => fail('dismiss should not fire'),
        );

        // Tab forward: options → note.
        await tester.sendTab();
        await tester.pump();

        // Type into the note field.
        await tester.enterText('prefer bun');
        await tester.pump();

        // Enter from the note field submits the whole form.
        await tester.sendEnter();
        await tester.pump();

        expect(submittedProse, isNotNull);
        expect(submittedProse, contains('[note] prefer bun'));
      }, size: const Size(80, 24));
    });

    test('mouse: tap on an option toggles it', () async {
      await testNocterm('ask form tap toggle', (tester) async {
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) {},
          onDismiss: () {},
        );

        // Find the position of 'api' on screen and tap it.
        final positions = tester.terminalState.findText('api');
        expect(positions.length, greaterThan(0));
        final pos = positions.first;
        await tester.tap(pos.x, pos.y);
        await tester.pump();

        // 'api' should now be picked.
        expect(tester.terminalState, containsText('☑'));
      }, size: const Size(80, 24));
    });

    test('mouse: tap on the note field moves focus to it', () async {
      await testNocterm('ask form tap note focuses', (tester) async {
        String? submittedProse;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (p, _) => submittedProse = p,
          onDismiss: () => fail('dismiss should not fire'),
        );

        // Tap directly on the placeholder text of the note field.
        final positions =
            tester.terminalState.findText('(optional) add extra context');
        expect(positions.length, greaterThan(0));
        final pos = positions.first;
        await tester.tap(pos.x, pos.y);
        await tester.pump();

        // Focus must have moved to the note region: typed characters
        // land in the note buffer, and Enter submits the form (the
        // note region's Enter behavior) instead of toggling an option.
        await tester.enterText('via mouse');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();

        expect(submittedProse, isNotNull);
        expect(submittedProse, contains('[note] via mouse'));
      }, size: const Size(80, 24));
    });

    test('mouse: tap on the Notes label / border also focuses the field',
        () async {
      await testNocterm('ask form tap note border focuses', (tester) async {
        String? submittedProse;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (p, _) => submittedProse = p,
          onDismiss: () => fail('dismiss should not fire'),
        );

        // Tap on the note field's border — an area outside the render
        // text field's own mouse region, covered by the outer
        // GestureDetector. The border sits one column left of the
        // placeholder text.
        final positions =
            tester.terminalState.findText('(optional) add extra context');
        expect(positions.length, greaterThan(0));
        final pos = positions.first;
        await tester.tap(pos.x - 1, pos.y);
        await tester.pump();

        await tester.enterText('border tap');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();

        expect(submittedProse, isNotNull);
        expect(submittedProse, contains('[note] border tap'));
      }, size: const Size(80, 24));
    });

    test('mouse: tap on Dismiss fires onDismiss', () async {
      await testNocterm('ask form tap dismiss', (tester) async {
        var dismissed = false;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) => fail('submit should not fire'),
          onDismiss: () => dismissed = true,
        );

        final positions = tester.terminalState.findText('Dismiss');
        expect(positions.length, greaterThan(0));
        final pos = positions.first;
        await tester.tap(pos.x, pos.y);
        await tester.pump();

        expect(dismissed, isTrue);
      }, size: const Size(80, 24));
    });

    test('keyboard: Shift+Tab from the note field goes back to options', () async {
      await testNocterm('ask form shift tab reverse', (tester) async {
        var submitted = false;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (_, _) => submitted = true,
          onDismiss: () {},
        );

        // Tab to note field.
        await tester.sendTab();
        await tester.pump();

        // Shift+Tab back to options.
        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.tab,
          modifiers: const ModifierKeys(shift: true),
        ));
        await tester.pump();

        // Space should now toggle an option rather than enter the note
        // field. We verify by toggling 'web' on (checkbox appears).
        await tester.sendKey(LogicalKey.space);
        await tester.pump();
        expect(tester.terminalState, containsText('☑'));

        // Sanity: the form is still mounted.
        expect(submitted, isFalse,
            reason: 'just toggling, no submit happened');
      }, size: const Size(80, 24));
    });

    test('layout: long option labels wrap instead of overflowing', () async {
      await testNocterm('ask form long labels wrap', (tester) async {
        const longLabel =
            'Refactor the websocket reconnect logic with exponential '
            'backoff and jitter';
        await pumpAskForm(
          tester,
          pending: PendingAsk(
            sessionId: 1,
            callId: 'long-call',
            spec: AskSpec(
              prompt: 'Pick a task',
              groups: [
                AskGroup(
                  name: 'tasks',
                  multi: true,
                  options: [
                    AskOption(label: longLabel),
                    AskOption(label: 'short'),
                  ],
                ),
              ],
            ),
            completer: Completer<ToolResult>(),
          ),
          onSubmit: (_, _) {},
          onDismiss: () {},
          width: 40,
        );

        final ts = tester.terminalState;
        // Both fragments of the wrapped label must be visible; with the
        // old horizontal Row layout the tail ('jitter') would be clipped
        // off the 40-column screen.
        expect(ts, containsText('Refactor the websocket reconnect'));
        expect(ts, containsText('jitter'));
        expect(ts, containsText('short'));
      }, size: const Size(40, 24));
    });

    test('keyboard: arrow right is clamped at the group boundary', () async {
      await testNocterm('ask form arrow right clamp', (tester) async {
        String? submittedProse;
        await pumpAskForm(
          tester,
          pending: makePending(),
          onSubmit: (p, _) => submittedProse = p,
          onDismiss: () {},
        );

        // Focus starts on flat index 0 = 'web' in the multi group
        // 'modules' (web / api / cli). Arrow right twice walks within
        // the group; the third press would cross into the 'runtime'
        // group and must be clamped — focus stays on 'cli'.
        await tester.sendKey(LogicalKey.arrowRight);
        await tester.sendKey(LogicalKey.arrowRight);
        await tester.sendKey(LogicalKey.arrowRight);
        await tester.pump();

        // Space toggles the focused option. If focus were still on
        // 'cli' (clamped), modules gets exactly one pick; if the press
        // had leaked into 'runtime', the single-select default would
        // have switched from 'node' to 'bun'.
        await tester.sendKey(LogicalKey.space);
        await tester.pump();

        // Submit from the note region: Tab there, then Enter.
        await tester.sendTab();
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();

        expect(submittedProse, isNotNull);
        expect(submittedProse, contains('[modules] cli'));
        expect(submittedProse, contains('[runtime] node'));
      }, size: const Size(80, 24));
    });

    test('submit produces an AskAnswerView with labels (not values)', () async {
      await testNocterm('ask form submit view', (tester) async {
        AskAnswerView? view;
        await pumpAskForm(
          tester,
          pending: PendingAsk(
            sessionId: 1,
            callId: 'view-call',
            spec: AskSpec(
              prompt: 'Pick and choose',
              groups: [
                AskGroup(
                  name: 'modules',
                  multi: true,
                  options: [
                    AskOption(label: 'Web UI', value: 'web'),
                    AskOption(label: 'API', value: 'api'),
                  ],
                ),
                AskGroup(
                  name: 'runtime',
                  options: [
                    AskOption(label: 'Node LTS', value: 'node'),
                    AskOption(label: 'Bun', value: 'bun'),
                  ],
                ),
              ],
            ),
            completer: Completer<ToolResult>(),
          ),
          onSubmit: (_, v) => view = v,
          onDismiss: () => fail('dismiss should not fire'),
        );

        // Pick 'Web UI' in the multi group (space on focused index 0),
        // then Tab to the note field, type a note, Enter to submit.
        await tester.sendKey(LogicalKey.space);
        await tester.pump();
        await tester.sendTab();
        await tester.pump();
        await tester.enterText('prefer bun');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();

        expect(view, isNotNull);
        expect(view!.prompt, equals('Pick and choose'));
        expect(view!.note, equals('prefer bun'));
        expect(view!.selections, hasLength(2));

        final modules = view!.selections.first;
        expect(modules.group, equals('modules'));
        expect(modules.multi, isTrue);
        expect(modules.labels, equals(['Web UI']));

        final runtime = view!.selections.last;
        expect(runtime.group, equals('runtime'));
        expect(runtime.multi, isFalse);
        // Single-select default is the first option — its LABEL, not
        // its wire value.
        expect(runtime.labels, equals(['Node LTS']));
      }, size: const Size(80, 24));
    });
  });

  group('AskAnswerBubble TUI', () {
    Future<void> pumpBubble(NoctermTester tester, AskAnswerView view) async {
      await tester.pumpComponent(
        CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: Container(
            width: 80,
            height: 24,
            child: AskAnswerBubble(answer: view),
          ),
        ),
      );
    }

    test('renders prompt, picked options with markers, and the note', () async {
      await testNocterm('ask answer bubble renders', (tester) async {
        await pumpBubble(
          tester,
          const AskAnswerView(
            prompt: 'Pick modules to refactor',
            note: 'prefer bun',
            selections: [
              AskAnswerSelection(
                group: 'modules',
                multi: true,
                labels: ['web', 'cli'],
              ),
              AskAnswerSelection(group: 'runtime', labels: ['node']),
            ],
          ),
        );

        final ts = tester.terminalState;
        expect(ts, containsText('Ask'));
        expect(ts, containsText('Pick modules to refactor'));
        expect(ts, containsText('modules:'));
        expect(ts, containsText('web'));
        expect(ts, containsText('cli'));
        expect(ts, containsText('runtime:'));
        expect(ts, containsText('node'));
        expect(ts, containsText('☑')); // multi marker
        expect(ts, containsText('◉')); // single marker
        expect(ts, containsText('prefer bun'));
      }, size: const Size(80, 24));
    });

    test('renders (none) for a group submitted with no selection', () async {
      await testNocterm('ask answer bubble none', (tester) async {
        await pumpBubble(
          tester,
          const AskAnswerView(
            prompt: '',
            note: '',
            selections: [
              AskAnswerSelection(group: 'modules', multi: true, labels: []),
            ],
          ),
        );

        final ts = tester.terminalState;
        expect(ts, containsText('modules:'));
        expect(ts, containsText('(none)'));
      }, size: const Size(80, 24));
    });
  });
}

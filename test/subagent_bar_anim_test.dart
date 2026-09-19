import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty;

import 'package:crux/src/components/subagents/subagent_bar.dart';
import 'package:crux/src/components/subagents/subagent_ui_models.dart';
import 'package:crux/src/components/ui/glossy_model_button.dart';
import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/subagent/subagent_config_store.dart';

SubagentUiEntry _entry(SubagentUiStatus status, {String name = 'apus'}) =>
    SubagentUiEntry(
      id: name,
      name: name,
      role: SubagentRole.worker,
      domain: 'smoke',
      status: status,
      model: 'deepseek/deepseek-v4-flash',
      assignmentSummary: 'test',
      lastActive: DateTime.now(),
    );

const _toggles = SubagentRuntimeToggles(workersOn: true, expertsOn: true);

void main() {
  group('SubagentBar animation', () {
    test('busy chip renders an animated GlossyModelButton', () async {
      await testNocterm('busy', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 5,
            child: SubagentBar(
              toggles: _toggles,
              agents: [_entry(SubagentUiStatus.busy)],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.findComponent<GlossyModelButton>(),
          isNotNull,
          reason: 'busy chip must render an animated GlossyModelButton',
        );
        print('BUSY:\n${tester.renderToString(showBorders: false)}');
      });
    });

    test('busy animation ticker stays live over time', () async {
      await testNocterm('busy-live', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 5,
            child: SubagentBar(
              toggles: _toggles,
              agents: [_entry(SubagentUiStatus.busy)],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.findComponent<GlossyModelButton>(), isNotNull);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.findComponent<GlossyModelButton>(), isNotNull);
      });
    });

    test('ready chip stays static (no GlossyModelButton)', () async {
      await testNocterm('ready', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 5,
            child: SubagentBar(
              toggles: _toggles,
              agents: [_entry(SubagentUiStatus.ready)],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.findComponent<GlossyModelButton>(), isNull,
            reason: 'ready chip must stay static');
        print('READY:\n${tester.renderToString(showBorders: false)}');
      });
    });

    test('both-off toggles still render (bar always-on)', () async {
      await testNocterm('both-off', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 5,
            child: const SubagentBar(
              toggles: SubagentRuntimeToggles(
                workersOn: false,
                expertsOn: false,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        // Switches stay visible (and clickable) even when both are off.
        expect(tester.terminalState.containsText('workers'), isTrue);
        expect(tester.terminalState.containsText('experts'), isTrue);
        expect(tester.terminalState.containsText('off'), isTrue);
        print('BOTH-OFF:\n${tester.renderToString(showBorders: false)}');
      });
    });
  });
}

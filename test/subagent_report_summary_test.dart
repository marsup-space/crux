import 'package:crux/src/services/subagent/subagent_prompts.dart';
import 'package:crux/src/utils/subagent_meta.dart';
import 'package:crux/src/models/subagent.dart';
import 'package:test/test.dart';

void main() {
  String envelope({String report = '结论：全部验证通过。\n第二行细节。'}) =>
      subagentReportEnvelope(
        agentName: 'ara',
        role: SubagentRole.worker,
        domain: '消息渲染',
        intention: '修复 agent box 显示 envelope marker',
        status: 'completed',
        report: report,
      );

  group('subagentReportSummary', () {
    test('takes the first report line, never the envelope marker', () {
      final summary = subagentReportSummary(envelope());
      expect(summary, '结论：全部验证通过。');
      expect(summary, isNot(contains('Crux system note')));
    });

    test('skips blank lines and stops before the next: hint', () {
      expect(
        subagentReportSummary(envelope(report: '\n\nonly line')),
        'only line',
      );
      expect(subagentReportSummary(envelope(report: '')), isNull);
    });

    test('returns null when there is no report block', () {
      expect(subagentReportSummary('just prose'), isNull);
      expect(subagentReportSummary('report: not a block'), isNull);
    });

    test('parseSubagentReportEnvelope reuses the same summary', () {
      final payload = parseSubagentReportEnvelope(envelope());
      expect(payload, isNotNull);
      expect(payload!.agentName, 'ara');
      expect(payload.kind, 'report');
      expect(payload.message, '结论：全部验证通过。');
    });
  });
}

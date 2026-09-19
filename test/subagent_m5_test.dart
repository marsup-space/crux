import 'package:crux/src/services/subagent/subagent_distiller.dart';
import 'package:test/test.dart';

void main() {
  group('stageFor (three-stage gate)', () {
    test('events 0 and 1 → compact; event 2+ → distill', () {
      expect(stageFor(0), DistillationStage.compact);
      expect(stageFor(1), DistillationStage.compact);
      expect(stageFor(2), DistillationStage.distill);
      expect(stageFor(5), DistillationStage.distill);
    });
  });

  group('SubagentDistiller.parse', () {
    test('parses the three sections', () {
      const reply = '''
Some preamble prose the model emitted.

===KNOWLEDGE===
- refresh tokens must single-flight
- the config loader caches by mtime

===WORKLOG===
- read auth/token_refresh.dart
- fixed the race in refresh()
- ran dart test — all green

===INSTRUCTION===
You have fixed the race and tests pass. Remaining: update the
CHANGELOG entry and report back with the file list.
''';
      final products = SubagentDistiller.parse(reply);
      expect(products.isValid, isTrue);
      expect(products.knowledge, contains('single-flight'));
      expect(products.worklog, contains('fixed the race'));
      expect(products.instruction, startsWith('You have fixed'));
      expect(products.instruction, contains('CHANGELOG'));
    });

    test('missing sections → invalid products', () {
      expect(SubagentDistiller.parse('no markers at all').isValid, isFalse);
      expect(SubagentDistiller.parse('').isValid, isFalse);
      // Two of three present is still invalid — the instruction is
      // what makes resumption possible.
      const partial = '''
===KNOWLEDGE===
k

===WORKLOG===
w
''';
      expect(SubagentDistiller.parse(partial).isValid, isFalse);
    });
  });

  group('buildRequest', () {
    test('frames the distillation task and keeps the history', () {
      final request = SubagentDistiller.buildRequest(
        agentName: 'orion',
        domain: 'token-refresh',
        intention: 'harden refresh',
        history: [
          {'role': 'user', 'content': 'go'},
          {'role': 'assistant', 'content': 'working'},
        ],
      );
      expect(request.first['role'], 'system');
      final system = request.first['content'] as String;
      expect(system, contains('orion'));
      expect(system, contains('token-refresh'));
      expect(system, contains('harden refresh'));
      expect(system, contains('===KNOWLEDGE==='));
      expect(system, contains('===WORKLOG==='));
      expect(system, contains('===INSTRUCTION==='));
      // History rides along verbatim.
      expect(request.length, 3);
      expect(request[1]['content'], 'go');
      expect(request[2]['content'], 'working');
    });
  });

  group('buildResumeHistory', () {
    test('resumes on system + CONTINUATION with the three products', () {
      const products = DistillationProducts(
        knowledge: 'K',
        worklog: 'W',
        instruction: 'I',
      );
      final history = buildResumeHistory(
        systemPrompt: 'SYS',
        products: products,
      );
      expect(history.length, 2);
      expect(history[0]['role'], 'system');
      expect(history[0]['content'], 'SYS');
      expect(history[1]['role'], 'user');
      final continuation = history[1]['content'] as String;
      expect(continuation.startsWith('===CONTINUATION==='), isTrue);
      expect(continuation, contains('===KNOWLEDGE===\nK'));
      expect(continuation, contains('===WORKLOG===\nW'));
      expect(continuation, contains('===INSTRUCTION===\nI'));
    });
  });

  group('history token estimate', () {
    test('scales with content and stays non-zero', () {
      final small = [
        {'role': 'user', 'content': 'a'},
      ].estimatedTokens;
      final large = [
        {'role': 'user', 'content': 'a' * 4000},
      ].estimatedTokens;
      expect(small, greaterThan(0));
      expect(large, greaterThan(small * 100));
    });
  });
}

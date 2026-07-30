import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/write_tool.dart';
import 'package:crux/src/utils/tool_metrics_animator.dart';
import 'package:test/test.dart';

void main() {
  group('AnimatedToolMetrics', () {
    test('setTarget returns false when the target is unchanged', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 12, addedLines: 5, removedLines: 3);

      expect(m.setTarget(tokens: 12, addedLines: 5, removedLines: 3), isFalse);
    });

    test('setTarget returns true when any value changes', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 12, addedLines: 5, removedLines: 3);

      expect(m.setTarget(tokens: 13, addedLines: 5, removedLines: 3), isTrue);
    });

    test('advance moves the display toward the target', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 100, addedLines: 10, removedLines: 5);

      // 16ms is roughly one 60fps frame. With the default
      // lerpPerSecond=12.0, the step is ~16% of the way from
      // display=0 to target=100, so display should be in the
      // low 20s — well under the target.
      m.advance(const Duration(milliseconds: 16), 12.0);
      expect(m.displayTokens, lessThan(100));
      expect(m.displayTokens, greaterThan(0));
    });

    test('isSettled becomes true once the display reaches the target', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 1, addedLines: 1, removedLines: null);

      // An absurdly high lerp rate converges in a single step.
      m.advance(const Duration(milliseconds: 16), 1000.0);

      expect(m.isSettled, isTrue);
    });

    test('clearing removedLines to null snaps display back to 0', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 0, addedLines: null, removedLines: 5);
      m.advance(const Duration(milliseconds: 16), 1000.0);
      expect(m.displayRemovedLines, 5);

      m.setTarget(tokens: 0, addedLines: null, removedLines: null);
      m.advance(const Duration(milliseconds: 16), 1000.0);
      expect(m.displayRemovedLines, 0);
    });
  });

  group('formatToolMetrics / formatToolMetricsToken', () {
    test('null metrics returns the ~0 t placeholder', () {
      expect(formatToolMetrics(null), ' · ~0 t');
      expect(formatToolMetricsToken(null), '~0 t');
    });

    test('renders line deltas only when their targets are set', () {
      final m = AnimatedToolMetrics();
      m.setTarget(tokens: 50, addedLines: 12, removedLines: null);
      m.displayTokens = 50;
      m.displayAddedLines = 12;

      // No `-K lines` half because removedLines target is null.
      expect(formatToolMetrics(m), ' · ~50 t +12 lines');
    });
  });

  group('stripToolTokenSuffix', () {
    test('removes the trailing (~Nt) suffix', () {
      expect(stripToolTokenSuffix('Write (~12 t)'), 'Write');
      expect(stripToolTokenSuffix('Bash (~5 t)'), 'Bash');
    });

    test('leaves labels without the suffix alone', () {
      expect(stripToolTokenSuffix('Read'), 'Read');
    });
  });

  group('WriteTool.toolMetricsLineDelta', () {
    final tool = WriteTool();

    test('new file: +N added, no removed half', () {
      // The "no prior lines" shape — the success message has
      // only the +N half, no -M.
      const output = 'Wrote 12 lines to lib/foo.dart (+12 lines, 0.4KB)';
      final result = ToolResult(title: '', output: output);
      final args = {
        'filePath': 'lib/foo.dart',
        'content':
            'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve',
      };

      final delta = tool.toolMetricsLineDelta(args, result);
      expect(delta?.addedLines, 12);
      expect(delta?.removedLines, isNull);
    });

    test('existing file: +N added, -M removed', () {
      const output = 'Wrote lib/foo.dart (+12 -3 lines, 0.4KB)';
      final result = ToolResult(title: '', output: output);
      final args = {
        'filePath': 'lib/foo.dart',
        'content':
            'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve',
      };

      final delta = tool.toolMetricsLineDelta(args, result);
      expect(delta?.addedLines, 12);
      expect(delta?.removedLines, 3);
    });
  });

  group('EditTool.toolMetricsLineDelta', () {
    final tool = EditTool();

    test('single replacement: +added -removed', () {
      const output =
          'Replaced 1 occurrence of oldString in lib/foo.dart (+2 -3 lines, 0.1KB)';
      final result = ToolResult(title: '', output: output);
      final args = {
        'filePath': 'lib/foo.dart',
        'oldString': 'a\nb\nc',
        'newString': 'x\ny',
      };

      final delta = tool.toolMetricsLineDelta(args, result);
      expect(delta?.addedLines, 2);
      expect(delta?.removedLines, 3);
    });

    test('replaceAll: multiplied by the actual occurrence count', () {
      const output =
          'Replaced 4 occurrences of oldString in lib/foo.dart (+8 -12 lines, 0.1KB)';
      final result = ToolResult(title: '', output: output);
      final args = {
        'filePath': 'lib/foo.dart',
        'oldString': 'a\nb\nc',
        'newString': 'x\ny',
        'replaceAll': true,
      };

      final delta = tool.toolMetricsLineDelta(args, result);
      expect(delta?.addedLines, 8); // 2 * 4
      expect(delta?.removedLines, 12); // 3 * 4
    });

    test('new file (empty oldString): +added, no removed half', () {
      const output = 'Created lib/foo.dart (+2 lines, 0.1KB)';
      final result = ToolResult(title: '', output: output);
      final args = {
        'filePath': 'lib/foo.dart',
        'oldString': '',
        'newString': 'x\ny',
      };

      final delta = tool.toolMetricsLineDelta(args, result);
      expect(delta?.addedLines, 2);
      expect(delta?.removedLines, isNull);
    });
  });
}

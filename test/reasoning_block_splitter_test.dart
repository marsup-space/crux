import 'package:test/test.dart';
import 'package:crux/src/utils/reasoning_block_splitter.dart';

void main() {
  group('splitReasoningIntoBlocks', () {
    test('empty input → empty list', () {
      expect(splitReasoningIntoBlocks('', 4096), isEmpty);
    });

    test('single paragraph under cap → one block', () {
      expect(splitReasoningIntoBlocks('hello world', 4096), ['hello world']);
    });

    test('multiple paragraphs all fitting → one block joined by \\n\\n', () {
      final input = 'first para\n\nsecond para\n\nthird para';
      expect(splitReasoningIntoBlocks(input, 4096), [input]);
    });

    test('paragraphs exceeding cap split at \\n\\n boundaries', () {
      // Three 8-char paragraphs joined by \n\n is "aaaa\n\nbbbb\n\ncccc"
      // = 4+2+4+2+4 = 16 chars. With cap=10, the first paragraph
      // fits alone (8 ≤ 10), the second would push to 18 so it
      // starts a new block, the third starts a third block.
      final input = 'aaaaaaaa\n\nbbbbbbbb\n\ncccccccc';
      final blocks = splitReasoningIntoBlocks(input, 10);
      expect(blocks, [
        'aaaaaaaa',
        'bbbbbbbb',
        'cccccccc',
      ]);
    });

    test('block boundary preserves full paragraphs (never splits mid-para)', () {
      // 12-char paragraph with cap=8 should not be sliced — it
      // gets its own block exceeding the cap, but no mid-paragraph
      // splitting happens.
      final input = 'twelve chars';
      final blocks = splitReasoningIntoBlocks(input, 8);
      expect(blocks, ['twelve chars']);
    });

    test('oversized paragraph + small paragraph → oversized alone, small alone', () {
      final input = 'twelve chars\n\nshort';
      final blocks = splitReasoningIntoBlocks(input, 8);
      expect(blocks, ['twelve chars', 'short']);
    });

    test('consecutive \\n\\n collapses to single \\n\\n', () {
      // "a\n\n\n\nb" split on "\n\n" yields ["a", "", "", "b"];
      // after filtering empties and rejoining we get "a\n\nb".
      // The rendered output is identical, and we don't want to
      // keep empty paragraphs around as their own blocks.
      expect(splitReasoningIntoBlocks('a\n\n\n\nb', 4096), ['a\n\nb']);
    });

    test('leading \\n\\n is stripped', () {
      expect(splitReasoningIntoBlocks('\n\nhello', 4096), ['hello']);
    });

    test('trailing \\n\\n is stripped', () {
      expect(splitReasoningIntoBlocks('hello\n\n', 4096), ['hello']);
    });

    test('cap of 0 throws', () {
      expect(() => splitReasoningIntoBlocks('hello', 0), throwsArgumentError);
    });

    test('cap of -1 throws', () {
      expect(() => splitReasoningIntoBlocks('hello', -1), throwsArgumentError);
    });

    test('greedy grouping fits as many paragraphs as possible', () {
      // Five 3-char paragraphs joined by \n\n total 3+2+3+2+3+2+3+2+3
      // = 23 chars. With cap=12: para1 (3) + \n\n + para2 (3) = 8,
      // fits. Adding para3 → 8+2+3 = 13 > 12, so flush, start new
      // block with para3. Same pattern for para4/para5. Final
      // split is three blocks: ['aaa\n\nbbb', 'ccc\n\nddd', 'eee'].
      final input = 'aaa\n\nbbb\n\nccc\n\nddd\n\neee';
      final blocks = splitReasoningIntoBlocks(input, 12);
      expect(blocks, [
        'aaa\n\nbbb',
        'ccc\n\nddd',
        'eee',
      ]);
    });

    test('only-whitespace paragraphs are preserved (not collapsed)', () {
      // Whitespace-only paragraphs (e.g. intentional dividers the
      // LLM emits between thoughts) are not "empty" — they render
      // as blank space in markdown and should survive the split
      // verbatim. Only *truly* empty paragraphs (from consecutive
      // \n\n) are filtered, since they collapse to the same
      // rendered output. When everything fits under cap the
      // paragraphs are joined back together with \n\n as-is.
      expect(splitReasoningIntoBlocks('a\n\n   \n\nb', 4096), [
        'a\n\n   \n\nb',
      ]);
    });

    test('streaming scenario: blocks grow then split as text accumulates', () {
      // Simulate the streaming bubble polling over time:
      // each poll adds one more paragraph. We expect the
      // block count to stay low (active block reuses the
      // last list slot) until the active block overflows,
      // then a new block is appended.
      const cap = 10;
      final poller = <String>[];
      final traces = <List<String>>[];

      void poll(String full) {
        traces.add(splitReasoningIntoBlocks(full, cap));
      }

      poller.add('a');
      poll('a\n\nb'); // ['a\n\nb']
      poll('a\n\nbb'); // ['a\n\nbb'] still fits (5 ≤ 10)
      poll('a\n\nbbbbbbbb'); // 14 > 10 → ['a', 'bbbbbbbb']
      poller.add('c'); // keep variable referenced
      poll('a\n\nbbbbbbbb\n\ncccc'); // ['a', 'bbbbbbbb', 'cccc']

      expect(traces[0], ['a\n\nb']);
      expect(traces[1], ['a\n\nbb']);
      expect(traces[2], ['a', 'bbbbbbbb']);
      expect(traces[3], ['a', 'bbbbbbbb', 'cccc']);
    });
  });
}
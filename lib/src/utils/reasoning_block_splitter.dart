/// Split a streaming reasoning trace into render-bounded
/// blocks at paragraph boundaries.
///
/// The motivation: during long LLM reasoning the streaming
/// bubble polls the controller every frame and rebuilds its
/// markdown subtree. If that subtree is one giant
/// [HighlightedMarkdownText] over the full reasoning text,
/// [RichText] layout runs on the *entire* reasoning every
/// frame — for a 20 kB trace that's 30+ ms of layout per
/// frame and drops the chat panel to 25-40 fps.
///
/// Instead we split the text at `\n\n` paragraph boundaries
/// into chunks of at most [cap] characters each, then render
/// each chunk as its own [HighlightedMarkdownText]. The last
/// chunk is the "active" one (still receiving streamed
/// tokens); earlier chunks are frozen snapshots. Flutter's
/// element diffing reuses the frozen widgets' layout elements
/// across rebuilds, so per-frame layout cost is bounded by
/// the active chunk's size rather than the full preamble.
///
/// This is a render-time optimisation, not a data loss: the
/// full reasoning text is still preserved upstream and ends
/// up in the saved [MessageBubble] when the turn ends.
library;

/// Split [text] at paragraph boundaries into blocks of at most
/// [cap] characters each.
///
/// Strategy: split on `\n\n` (paragraph break), greedily group
/// consecutive non-empty paragraphs into a block until adding
/// the next paragraph would exceed [cap], then start a new
/// block. A single paragraph that itself exceeds [cap] is
/// kept whole in its own block (rare in practice; reasoning
/// paragraphs are usually short) and preferable to mid-
/// paragraph slicing.
///
/// Consecutive paragraph breaks (`\n\n\n\n`) collapse to one
/// (`\n\n`) since markdown renders them identically.
///
/// Examples (see `test/reasoning_block_splitter_test.dart`):
/// - `splitIntoBlocks('', 4096)` → `[]`
/// - `splitIntoBlocks('hello', 4096)` → `['hello']`
/// - `splitIntoBlocks('a\n\nb\n\nc', 4096)` → `['a\n\nb\n\nc']`
/// - `splitIntoBlocks(longText, 10)` → several shorter blocks
List<String> splitReasoningIntoBlocks(String text, int cap) {
  if (text.isEmpty) return const [];
  if (cap <= 0) {
    throw ArgumentError.value(cap, 'cap', 'must be positive');
  }
  final paragraphs = text.split('\n\n').where((p) => p.isNotEmpty);
  final blocks = <String>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isNotEmpty) {
      blocks.add(buffer.toString());
      buffer.clear();
    }
  }

  for (final p in paragraphs) {
    if (buffer.isEmpty) {
      buffer.write(p);
      continue;
    }
    final candidateLen = buffer.length + 2 + p.length;
    if (candidateLen > cap) {
      flush();
      buffer.write(p);
    } else {
      buffer
        ..write('\n\n')
        ..write(p);
    }
  }
  flush();
  return blocks;
}
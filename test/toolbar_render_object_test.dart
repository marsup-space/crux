// Tests for the toolbar's streaming widgets' custom render object
// pattern. Verifies that data updates skip the rebuild path entirely
// and instead propagate via markNeedsPaint on the render object.

import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:crux/src/components/context_bar.dart';

void main() {
  group('RenderContextBar (custom render object)', () {
    test('update() fires markNeedsPaint when data changes', () {
      final owner = PipelineOwner();
      final ro = RenderContextBar(
        width: 20,
        fillRatio: 0.5,
        label: '500 / 1000k',
        fillColor: const Color(0xFFFF0000),
        emptyColor: const Color(0xFF000000),
        labelFillFg: const Color(0xFFFFFFFF),
        labelEmptyFg: const Color(0xFF888888),
      );
      ro.attach(owner);
      ro.layout(const BoxConstraints(maxWidth: 20, maxHeight: 1));

      // Sanity: clean state
      ro.update(fillRatio: 0.5, label: '500 / 1000k');
      expect(
        ro.needsPaint,
        isFalse,
        reason: 'update with identical data must be a no-op',
      );

      // Different data → markNeedsPaint
      ro.update(fillRatio: 0.6, label: '600 / 1000k');
      expect(
        ro.needsPaint,
        isTrue,
        reason: 'changed data must trigger repaint',
      );
    });

    test('update() never triggers markNeedsLayout', () {
      // The render object has a fixed size (width × 1). Data
      // updates must NEVER mark for layout — that would defeat
      // the whole point of the refactor.
      final owner = PipelineOwner();
      final ro = RenderContextBar(
        width: 20,
        fillRatio: 0.5,
        label: '500 / 1000k',
        fillColor: const Color(0xFFFF0000),
        emptyColor: const Color(0xFF000000),
        labelFillFg: const Color(0xFFFFFFFF),
        labelEmptyFg: const Color(0xFF888888),
      );
      ro.attach(owner);
      ro.layout(const BoxConstraints(maxWidth: 20, maxHeight: 1));

      ro.update(fillRatio: 0.9, label: '900 / 1000k');
      ro.update(fillRatio: 0.1, label: '100 / 1000k');
      ro.update(fillRatio: 0.0, label: '0 / 1000k');
      ro.update(fillRatio: 1.0, label: '1000 / 1000k');
      ro.update(fillRatio: 0.5, label: 'Compact');

      expect(
        ro.needsLayout,
        isFalse,
        reason:
            'data updates must NEVER trigger relayout — '
            'size is fixed',
      );
    });

    test('size is fixed at width × 1', () {
      final ro = RenderContextBar(
        width: 20,
        fillRatio: 0.5,
        label: 'x',
        fillColor: const Color(0xFFFF0000),
        emptyColor: const Color(0xFF000000),
        labelFillFg: const Color(0xFFFFFFFF),
        labelEmptyFg: const Color(0xFF888888),
      );
      ro.layout(const BoxConstraints(maxWidth: 100, maxHeight: 100));
      expect(ro.size, const Size(20, 1));
    });
  });
}

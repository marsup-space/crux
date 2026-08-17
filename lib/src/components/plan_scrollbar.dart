import 'annotated_scrollbar.dart';

/// The plan doc pane's annotated scrollbar.
///
/// The pane scrolls a `SingleChildScrollView` over one `RichText` (the
/// parsed plan spans) — there is no `RenderListViewport`, so the chat's
/// `getItemIndexOffsetAndExtent` resolver cannot be used here. Instead a
/// marker's `itemIndex` IS the flat rendered row (the same convention
/// `PlanParseResult.headings`, `viewportSourceLines`, and
/// `_flatRowStarts` use), and the scroll offset is measured in rows, so
/// the content offset is simply `row.toDouble()`.
///
/// Jump-to-marker inherits the base implementation (`jumpTo(offset)`),
/// which is exactly the row-granular jump the pane wants.
class PlanScrollbar extends AnnotatedScrollbar {
  const PlanScrollbar({
    super.key,
    required super.child,
    super.controller,
    super.thumbVisibility,
    super.thickness,
    super.trackColor,
    super.thumbColor,
    super.markers,
    super.onMarkerTap,
  });

  @override
  double? markerContentOffset(ScrollbarMarker marker) {
    return marker.itemIndex.toDouble();
  }
}

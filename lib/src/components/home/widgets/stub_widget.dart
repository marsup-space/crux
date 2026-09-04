import 'package:nocterm/nocterm.dart';

import '../../../services/a2ui/surface_builder.dart';
import '../home_surface.dart';
import '../home_widgets.dart';

/// A placeholder [HomeWidget] that fills the grid until the Phase 3
/// built-ins land. It renders its id (and the span it was laid out at)
/// so layout, reflow, focus, and activation are all visible and
/// testable before any real data source exists.
class StubHomeWidget extends HomeWidget {
  @override
  final String id;

  @override
  final String title;

  @override
  final Set<int> supportedSpans;

  final int height;

  /// When false, [activate] returns null (a passive box). Tests use
  /// this to assert `enter` on a passive box is a no-op.
  final bool actionable;

  StubHomeWidget(
    this.id, {
    String? title,
    Set<int>? supportedSpans,
    this.height = 4,
    this.actionable = true,
  }) : title = title ?? id,
       supportedSpans = supportedSpans ?? const {1, 2};

  @override
  int heightFor(int span) => height;

  @override
  void Function()? activate(HomeContext ctx) {
    if (!actionable) return null;
    return () {};
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return homeSurface(
      declaration: SurfaceBuilder(
        surfaceId: 'home.stub.$id',
      ).text('root', '$id · span $span').build(),
      strings: ctx.strings,
    );
  }
}

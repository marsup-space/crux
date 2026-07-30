import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../version.dart';

/// `true` when running under the JIT (`dart run`, `dart test`, kernel
/// snapshots); `false` in the compiled (AOT/product) binary. Compiled
/// into a constant, so the unused branch is tree-shaken away in
/// release builds.
const bool kIsJit = !bool.fromEnvironment('dart.vm.product');

/// Overlays a faint, right-aligned version string at the top-right of
/// the terminal, without affecting the layout of [child].
///
/// The badge lives in a [Stack] sibling to [child], so [child] keeps
/// the full terminal bounds exactly as if the badge weren't there.
/// When running under the JIT the label gets a ` jit` suffix
/// (e.g. `v0.23.0 jit`) so dev runs are visually distinguishable from a
/// release binary at a glance.
///
/// Placement mirrors [HintOverlay]: put it just inside the themed
/// subtree so [CruxTheme.of] resolves, but outside the chat panel so
/// the badge stays put regardless of what the panel renders.
class VersionBadge extends StatelessComponent {
  const VersionBadge({super.key, required this.child});

  /// The subtree below the badge — receives the stack's full bounds.
  final Component child;

  @override
  Component build(BuildContext context) {
    final label = kIsJit ? 'v$kCruxVersion jit' : 'v$kCruxVersion';

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 0,
          right: 0,
          // `textMuted` is the theme's designated faint-foreground
          // token (what comments, placeholders, and secondary chrome
          // use), so the badge stays subtle in every theme without
          // hardcoding a color here.
          child: Text(
            label,
            style: TextStyle(color: CruxTheme.of(context).textMuted),
          ),
        ),
      ],
    );
  }
}

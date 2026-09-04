/// Host adapter for rendering one A2UI declaration outside chat.
///
/// The declaration language stays the same across chat, home, sidebar and
/// fullpane. Hosts choose lifecycle and action semantics: chat surfaces are
/// retained and submit once; app-owned dashboard views are rebuilt from live
/// state and may dispatch many local actions.
library;

import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../services/a2ui/models.dart';
import '../services/a2ui/surface_catalog.dart';
import '../services/a2ui/surface_controller.dart';

class SurfaceHost extends StatelessComponent {
  final CreateSurface declaration;
  final SurfaceCatalog catalog;
  final String instanceKey;
  final bool retainState;
  final bool submitOnAction;

  /// Optional centered content cap for fullpane and standalone hosts.
  /// Chat and home omit this: their parent owns the available width.
  final int? maxWidth;
  final void Function(A2uiAction action)? onAction;
  final void Function(String path, dynamic value)? onDataModelUpdate;
  final Strings strings;

  const SurfaceHost({
    super.key,
    required this.declaration,
    required this.catalog,
    required this.instanceKey,
    this.retainState = true,
    this.submitOnAction = true,
    this.maxWidth,
    this.onAction,
    this.onDataModelUpdate,
    this.strings = kEnglishStrings,
  });

  @override
  Component build(BuildContext context) {
    final errors = catalog.validate(declaration);
    if (errors.isNotEmpty) {
      return Text('[invalid surface: ${errors.join('; ')}]');
    }
    final instance = retainState
        ? catalog.instanceFor(instanceKey, declaration)
        : SurfaceInstance(declaration: declaration);
    final controller = SurfaceController(
      surface: instance,
      catalog: catalog,
      onAction: onAction,
      onDataModelUpdate: onDataModelUpdate,
      submitOnAction: submitOnAction,
      strings: strings,
    );
    if (maxWidth == null) return controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : maxWidth!.toDouble();
        final width = math.min(available, maxWidth!.toDouble());
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: width, child: controller),
        );
      },
    );
  }
}

/// Host adapter for rendering one A2UI declaration outside chat.
///
/// The declaration language stays the same across chat, home, sidebar and
/// fullpane. Hosts choose lifecycle and action semantics: chat surfaces are
/// retained and submit once; app-owned dashboard views are rebuilt from live
/// state and may dispatch many local actions.
library;

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
    return SurfaceController(
      surface: instance,
      catalog: catalog,
      onAction: onAction,
      onDataModelUpdate: onDataModelUpdate,
      submitOnAction: submitOnAction,
      strings: strings,
    );
  }
}

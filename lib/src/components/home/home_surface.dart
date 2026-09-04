/// Shared A2UI host for app-owned Home dashboard surfaces.
///
/// Home owns grid placement, selection and service lifecycles. Individual
/// boxes describe their visible content as ordinary A2UI declarations and use
/// this adapter for a fresh, non-submitting surface on each home rebuild.
library;

import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../services/a2ui/basic_catalog_items.dart';
import '../../services/a2ui/models.dart';
import '../surface_host.dart';

final homeSurfaceCatalog = createBasicCatalog();

Component homeSurface({
  required CreateSurface declaration,
  required Strings strings,
  void Function(A2uiAction action)? onAction,
}) => SurfaceHost(
  declaration: declaration,
  catalog: homeSurfaceCatalog,
  instanceKey: declaration.surfaceId,
  retainState: false,
  submitOnAction: false,
  onAction: onAction,
  strings: strings,
);

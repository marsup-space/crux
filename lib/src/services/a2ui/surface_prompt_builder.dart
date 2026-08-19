/// A2UI prompt builder for Crux.
///
/// Builds the system prompt section that teaches the agent how to use
/// the `surface` tool and the A2UI component catalog. Follows the
/// prompt-first pattern from Flutter GenUI: the catalog schema is
/// injected directly into the system prompt so the model "reads" it
/// and generates correct A2UI JSON.
library;

import 'surface_catalog.dart';

/// Build the A2UI surface section for the system prompt.
///
/// Returns a string to be appended to the system prompt, teaching the
/// agent:
///   1. When to create surfaces (interactive UI vs plain text)
///   2. The A2UI message format (createSurface + adjacency list)
///   3. Available component types and their properties
///   4. Data binding syntax
///   5. Rules and constraints
///
/// [catalog] provides the component registry — its schema is serialized
/// into the prompt so the model knows exactly what it can use.
String buildSurfacePromptSection(SurfaceCatalog catalog) {
  return catalog.toPromptSection();
}

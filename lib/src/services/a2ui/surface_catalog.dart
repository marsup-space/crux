/// A2UI catalog registry for Crux.
///
/// The catalog is the whitelist of component types the agent can use.
/// Each [CatalogItem] carries a type name, a JSON Schema fragment for
/// validation, and a builder function that constructs a nocterm component
/// from the parsed properties.
///
/// Aligned with A2UI's catalog concept: the agent can only compose from
/// registered types, and the schema is injected into the system prompt
/// so the model knows what's available.
library;

import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import 'models.dart';

/// A registered component type in the catalog.
///
/// Each item knows its A2UI type name (e.g. `'Text'`, `'Column'`),
/// how to validate its properties, and how to build a nocterm component.
abstract class CatalogItem {
  /// The A2UI type name used in the `"component"` discriminator field.
  /// Must be a valid UAX #31 identifier, PascalCase by convention.
  String get typeName;

  /// JSON Schema fragment for this component's properties.
  /// Injected into the system prompt so the model knows what properties
  /// are available. Only describes the component-specific properties
  /// (not the common `id`/`component` fields).
  Map<String, dynamic> get propertiesSchema;

  /// Human-readable description of what this component does.
  /// Injected into the system prompt alongside the schema.
  String get description;

  /// Build a nocterm component from the parsed A2UI component declaration.
  ///
  /// [context] is the nocterm build context — provides theme access.
  /// [component] is the parsed A2UI component node.
  /// [dataModel] is the surface's current data model (for resolving
  /// `{"path": ...}` bindings).
  /// [buildChild] resolves a child component id to a built nocterm
  /// component — used by container components (Column, Row, Card).
  /// [onAction] is called when an interactive component triggers an action
  /// (button press, etc.). Null for Phase 1 (single-direction surfaces).
  /// [onDataModelUpdate] is called when an interactive component mutates
  /// the data model (text input, checkbox toggle). Null for Phase 1.
  /// [submitted] is true when the surface has been submitted and should
  /// render in a disabled/read-only state.
  /// [childType] resolves a child component id to its A2UI type name
  /// (e.g. `'Card'`). Hosts inject this so layout containers can make
  /// type-aware decisions (e.g. Column auto-flowing sibling Cards into
  /// a row when the terminal is wide). Null disables type-aware layout.
  /// [strings] is the host's message catalog for host-added chrome
  /// (e.g. the Table fold toggle). Hosts thread the active locale
  /// through; defaults to English.
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted,
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  });
}

/// The surface catalog — a registry of [CatalogItem]s keyed by type name.
///
/// Modeled after `ToolRegistry`: items are registered at startup,
/// looked up by type name at render time, and enumerated for system
/// prompt generation.
class SurfaceCatalog {
  final Map<String, CatalogItem> _items = {};

  /// The catalog identifier (e.g. `'crux/1.0/chat'`).
  final String catalogId;

  /// Live surface instances keyed by their originating tool-call id.
  ///
  /// Surfaces must survive chat-list rebuilds: a rebuild re-parses the
  /// tool call and constructs a new [SurfaceBubble], but the interactive
  /// state (DataModel edits, submitted flag) lives here so re-renders
  /// pick up the same instance instead of resetting to the declaration's
  /// initial state.
  final Map<String, SurfaceInstance> _instances = {};

  /// Get or create the live [SurfaceInstance] for a tool call.
  ///
  /// [key] should be the tool call's stable id (`ToolCallData.callId`);
  /// [declaration] is parsed from the tool call input and used only on
  /// first creation.
  ///
  /// Re-keying: when a *different* key arrives carrying a declaration
  /// whose `surfaceId` already has a live instance, the existing
  /// instance is re-keyed instead of duplicating. This is what makes
  /// `surface` + `surface_update` tool calls in the same turn share one
  /// instance — the update fires before the UI first renders (both tool
  /// calls execute back-to-back), so by the time `SurfaceBubble` mounts,
  /// the create-call's key resolves to the instance the update already
  /// mutated. Restart/restore walks calls in order, so the create call
  /// registers first and the update call re-keys to it (a no-op).
  SurfaceInstance instanceFor(String key, CreateSurface declaration) {
    final existing = _instances[key];
    if (existing != null) return existing;

    // Re-key an instance created via a different tool call (surface_update
    // targeting the same surfaceId).
    final byId = instanceById(declaration.surfaceId);
    if (byId != null) {
      _instances[key] = byId;
      return byId;
    }

    final created = SurfaceInstance(declaration: declaration);
    _instances[key] = created;
    return created;
  }

  /// Find a live instance by its surfaceId (not the tool-call key).
  /// Used by chat history to restore submitted state from action messages.
  SurfaceInstance? instanceById(String surfaceId) {
    for (final instance in _instances.values) {
      if (instance.surfaceId == surfaceId) return instance;
    }
    return null;
  }

  SurfaceCatalog({this.catalogId = 'crux/1.0/chat'});

  /// Register a catalog item. Replaces any existing item with the same
  /// type name.
  void register(CatalogItem item) {
    _items[item.typeName] = item;
  }

  /// Look up a catalog item by type name.
  CatalogItem? lookup(String typeName) => _items[typeName];

  /// All registered items, in registration order.
  List<CatalogItem> get all => List.unmodifiable(_items.values);

  /// All registered type names.
  Set<String> get typeNames => Set.unmodifiable(_items.keys);

  /// Validate a [CreateSurface] declaration against this catalog.
  /// Returns a list of validation errors, empty if valid.
  List<String> validate(CreateSurface surface) {
    final errors = <String>[];

    if (surface.catalogId != catalogId) {
      errors.add(
        'catalogId mismatch: expected "$catalogId", got "${surface.catalogId}"',
      );
    }

    if (surface.components.isEmpty) {
      errors.add('components list is empty');
    }

    final ids = <String>{};
    for (final c in surface.components) {
      if (!ids.add(c.id)) {
        errors.add('duplicate component id: "${c.id}"');
      }
      if (lookup(c.component) == null) {
        errors.add('unknown component type: "${c.component}" (id: "${c.id}")');
      }
    }

    // Check that root exists.
    if (surface.root == null) {
      errors.add('no root component found (need a component with id "root")');
    }

    // Check that all child references resolve. unwrapListProperty
    // tolerates the {"item": [...]} wrapper some providers emit.
    for (final c in surface.components) {
      final children = unwrapListProperty(c.properties['children']);
      if (children is List) {
        for (final childId in children) {
          if (childId is String && !ids.contains(childId)) {
            errors.add(
              'component "${c.id}" references unknown child "$childId"',
            );
          }
        }
      }
      // Single-child references (e.g. Card's "child" property).
      final child = c.properties['child'];
      if (child is String && !ids.contains(child)) {
        errors.add('component "${c.id}" references unknown child "$child"');
      }
    }

    // Rule: a component referenced as a single-child (`child`) must NOT
    // also appear in any container's `children` list — it would render
    // twice (once inside the parent, once as an orphan). A2UI adjacency
    // list means each component has exactly one parent.
    final singleChildRefs = <String, String>{};
    for (final c in surface.components) {
      final child = c.properties['child'];
      if (child is String) {
        singleChildRefs[child] = c.id;
      }
    }
    if (singleChildRefs.isNotEmpty) {
      for (final c in surface.components) {
        final children = c.properties['children'];
        if (children is! List) continue;
        for (final childId in children) {
          final parent = singleChildRefs[childId];
          if (parent != null) {
            errors.add(
              'component "$childId" is declared as the "child" of "$parent" '
              'AND appears in "$c.id".children — it would render twice. '
              'Keep it only as "$parent".child.',
            );
          }
        }
      }
    }

    return errors;
  }

  /// Generate the catalog section for the system prompt.
  ///
  /// Lists every registered component type with its description and
  /// property schema, formatted for LLM consumption. This is the
  /// prompt-first approach — the model reads the catalog and knows
  /// what it can use.
  String toPromptSection() {
    final buf = StringBuffer();
    buf.writeln('## Generative UI — Surface Catalog');
    buf.writeln();
    buf.writeln(
      'You can create interactive UI surfaces by calling the `surface` tool '
      'with an A2UI `createSurface` message. The surface is rendered inline '
      'in the chat flow using the component types below.',
    );
    buf.writeln();
    buf.writeln('Catalog ID: `$catalogId`');
    buf.writeln();
    buf.writeln('### Available component types');
    buf.writeln();

    for (final item in _items.values) {
      buf.writeln('#### ${item.typeName}');
      buf.writeln(item.description);
      buf.writeln();
      if (item.propertiesSchema.isNotEmpty) {
        buf.writeln('Properties:');
        for (final entry in item.propertiesSchema.entries) {
          final prop = entry.value;
          if (prop is Map<String, dynamic>) {
            final type = prop['type'] ?? 'any';
            final desc = prop['description'] ?? '';
            buf.writeln('- `${entry.key}` ($type): $desc');
          } else {
            buf.writeln('- `${entry.key}`');
          }
        }
        buf.writeln();
      }
    }

    buf.writeln('### Message format');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "version": "v0.9",');
    buf.writeln('  "createSurface": {');
    buf.writeln('    "surfaceId": "unique_id",');
    buf.writeln('    "catalogId": "$catalogId",');
    buf.writeln('    "components": [');
    buf.writeln(
      '      {"id": "root", "component": "Column", "children": ["title", "body"]},',
    );
    buf.writeln('      {"id": "title", "component": "Text", "text": "Hello"},');
    buf.writeln(
      '      {"id": "body", "component": "Text", "text": "World"}',
    );
    buf.writeln('    ],');
    buf.writeln('    "dataModel": {}');
    buf.writeln('  }');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();
    buf.writeln('### Data binding');
    buf.writeln();
    buf.writeln(
      'Component properties can reference the data model using '
      '`{"path": "/fieldName"}`. The value is resolved at render time.',
    );
    buf.writeln();
    buf.writeln('### Interactive example');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "version": "v0.9",');
    buf.writeln('  "createSurface": {');
    buf.writeln('    "surfaceId": "form_1",');
    buf.writeln('    "catalogId": "$catalogId",');
    buf.writeln('    "components": [');
    buf.writeln(
      '      {"id": "root", "component": "Column", "children": ["name_label", "name_input", "subscribe", "interests", "submit"]},',
    );
    buf.writeln(
      '      {"id": "name_label", "component": "Text", "text": "Name:"},',
    );
    buf.writeln(
      '      {"id": "name_input", "component": "TextField", "value": {"path": "/name"}, "variant": "shortText"},',
    );
    buf.writeln(
      '      {"id": "subscribe", "component": "CheckBox", "label": "Subscribe", "value": {"path": "/subscribe"}},',
    );
    buf.writeln(
      '      {"id": "interests", "component": "ChoicePicker", "label": "Topics", "options": [{"label": "Food", "value": "food"}, {"label": "Tech", "value": "tech"}], "value": {"path": "/interests"}, "variant": "multipleSelection"},',
    );
    buf.writeln(
      '      {"id": "submit_label", "component": "Text", "text": "Submit"},',
    );
    buf.writeln(
      '      {"id": "submit", "component": "Button", "child": "submit_label", "variant": "primary", "action": {"event": {"name": "submit_form", "context": {"name": {"path": "/name"}, "subscribe": {"path": "/subscribe"}, "interests": {"path": "/interests"}}}}}',
    );
    buf.writeln('    ],');
    buf.writeln(
      '    "dataModel": {"name": "", "subscribe": false, "interests": []}',
    );
    buf.writeln('  }');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();

    buf.writeln('### Layout — declare content, the host owns presentation');
    buf.writeln();
    buf.writeln(
      'You declare WHAT is on the surface; the host decides HOW it is laid '
      'out for the actual terminal width AND height. Do NOT hand-place '
      'siblings into rows to fill width, and do NOT worry about long '
      'content — the host handles both responsively:',
    );
    buf.writeln();
    buf.writeln(
      '- **Just stack Cards in a Column.** When ≥2 consecutive Cards fit '
      'the terminal width, the host automatically flows them side-by-side '
      'into an equal-width row; on narrow terminals they stack. Never wrap '
      'Cards in a Row yourself.',
    );
    buf.writeln(
      '- **Long tables fold automatically.** A Table with more than ~12 '
      'rows folds behind a "… N more rows" toggle the HOST renders — you '
      'declare all rows; the user expands them if they want. Do not '
      'pre-truncate or paginate your own tables.',
    );
    buf.writeln(
      '- **Row** is still right for intrinsically horizontal groups that '
      'must stay together at any width: a label + its input, action '
      'buttons, the ChoicePicker + submit button of a form.',
    );
    buf.writeln(
      '- **ChoicePicker** with `"displayStyle": "inline"` for ≤4 short options — '
      'renders all options on one line as compact tags.',
    );
    buf.writeln(
      '- **Keyboard is first-class.** Tab cycles interactive components '
      '(Button, ChoicePicker, TextField, fold toggles); Enter/Space '
      'activates a focused Button or toggles the fold; arrow keys move '
      'within a ChoicePicker; Escape returns focus to the chat input. '
      'Don\'t add "press X to…" instructions for this — the host renders '
      'the chrome.',
    );
    buf.writeln();
    buf.writeln('Compact example — a confirmation form using horizontal layout:');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "version": "v0.9",');
    buf.writeln('  "createSurface": {');
    buf.writeln('    "surfaceId": "confirm_1",');
    buf.writeln('    "catalogId": "$catalogId",');
    buf.writeln('    "components": [');
    buf.writeln(
      '      {"id": "root", "component": "Column", "children": ["title", "options", "actions"]},',
    );
    buf.writeln(
      '      {"id": "title", "component": "Text", "text": "Deploy to production?"},',
    );
    buf.writeln(
      '      {"id": "options", "component": "ChoicePicker", "options": [{"label": "Yes", "value": "yes"}, {"label": "No", "value": "no"}, {"label": "Dry run", "value": "dry"}], "value": {"path": "/choice"}, "variant": "mutuallyExclusive", "displayStyle": "inline"},',
    );
    buf.writeln(
      '      {"id": "actions", "component": "Row", "gap": 2, "children": ["ok", "cancel"]},',
    );
    buf.writeln(
      '      {"id": "ok", "component": "Button", "child": "ok_label", "variant": "primary", "action": {"event": {"name": "confirm"}}},',
    );
    buf.writeln(
      '      {"id": "ok_label", "component": "Text", "text": "Confirm"},',
    );
    buf.writeln(
      '      {"id": "cancel", "component": "Button", "child": "cancel_label", "action": {"event": {"name": "cancel"}}},',
    );
    buf.writeln(
      '      {"id": "cancel_label", "component": "Text", "text": "Cancel"}',
    );
    buf.writeln('    ],');
    buf.writeln('    "dataModel": {"choice": []}');
    buf.writeln('  }');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();

    buf.writeln('### Rules');
    buf.writeln();
    buf.writeln(
      '- CRITICAL: A component referenced as a `child` of Button or Card '
      'must NOT also appear in any container\'s `children` list — it would '
      'render twice (once inside the parent, once as an orphan). Each '
      'component has exactly ONE parent. If a Button has '
      '`"child": "btn_label"`, the `btn_label` component must NOT be in '
      'root.children.',
    );
    buf.writeln(
      '- IMPORTANT: Pass the createSurface payload directly as the '
      '"surface" tool argument. Do NOT wrap it in another object. '
      'The payload must have "surfaceId", "catalogId", and "components" '
      'at the top level.',
    );
    buf.writeln(
      '- To refresh a live surface later (progress, status, new data), '
      'call the `surface_update` tool with '
      '{"surface_id": "<surfaceId>", "updates": {"/field": value, ...}} '
      '— data-bound components re-render immediately. Declare the '
      'dynamic parts as {"path": "/field"} bindings in createSurface '
      'so updates can flow in.',
    );
    buf.writeln(
      '- To CHANGE THE STRUCTURE of a live surface (append rows/blocks, '
      'swap a component), pass `components` (and optionally '
      '`extend_container_id`) to the same `surface_update` tool: '
      '{"surface_id": "...", "components": [{"id": "row_new", '
      '"component": "Text", "text": "..."}], "extend_container_id": '
      '"root"}. Existing ids are replaced in place; new ids are appended '
      'to the container\'s children — you never need to re-declare a '
      'whole surface just to add a row.',
    );
    buf.writeln(
      '- Components form an adjacency list: containers reference children '
      'by id, not by nesting.',
    );
    buf.writeln(
      '- Every surface must have a component with id `"root"` as the '
      'top-level component.',
    );
    buf.writeln('- Only use component types listed above.');
    buf.writeln(
      '- Do NOT specify colors, fonts, or styles — theme is controlled '
      'by the host.',
    );
    buf.writeln(
      '- Keep surfaces compact — they render inside a chat bubble. '
      'Prefer Row for side-by-side layout over stacking everything in a Column.',
    );
    buf.writeln(
      '- Button\'s `child` should reference a Text component that serves '
      'as the button label. Example: '
      '`{"id": "btn", "component": "Button", "child": "btn_label", ...}` '
      'with `{"id": "btn_label", "component": "Text", "text": "Submit"}`.',
    );
    buf.writeln(
      '- INLINE SURFACES: You can also embed a surface directly in your '
      'prose reply with an <a2ui>...</a2ui> tag. The tag body must be the '
      'RAW createSurface JSON object — do NOT wrap it in a markdown code '
      'fence (```), do NOT add a "version" wrapper. Example: '
      '<a2ui>{"createSurface": {"surfaceId": "x", "catalogId": "$catalogId", '
      '"components": [...], "dataModel": {}}}</a2ui>. Use inline surfaces '
      'for small contextual confirmations; use the `surface` tool for '
      'larger panels.',
    );

    return buf.toString();
  }
}

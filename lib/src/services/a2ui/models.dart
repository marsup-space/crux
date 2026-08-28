/// A2UI protocol data models for Crux.
///
/// Implements the A2UI v0.9.1 message format (a2ui.org) as plain Dart
/// objects. These are the wire-format types — the agent emits them as
/// JSON, the client parses and renders them.
///
/// Message types:
///   * `createSurface` — create a new surface with components + data model
///   * `updateComponents` — add/update components on an existing surface
///   * `updateDataModel` — update the data model (JSON Pointer paths)
///   * `deleteSurface` — remove a surface
///   * `action` — user interaction event sent client→agent
library;

import 'dart:convert';

import 'package:nocterm/nocterm.dart' show ChangeNotifier;

// ---------------------------------------------------------------------------
// Provider-mangled payload normalization
// ---------------------------------------------------------------------------

/// Normalize a property value that is expected to be a JSON array.
///
/// Some providers (observed with MiniMax-M3 via OpenRouter, ses://5047)
/// serialize tool-call arguments with the array wrapped in a keyed
/// object — `"children": {"item": ["a", "b"]}` instead of
/// `"children": ["a", "b"]` — and turn numeric literals into strings
/// (`"gap": "2"`). The strict `is List` checks in the catalog items
/// then silently drop the value and the surface renders empty.
///
/// Unwraps, in order:
/// * a single-key `{"<key>": [...]}` wrapper whose value is a List
///   (any key name — `item`, `items`, `children`, …);
/// * a JSON-encoded string (`"[\"a\"]"` → `["a"]`);
/// * anything else passes through unchanged (the caller's `is List`
///   check still guards).
dynamic unwrapListProperty(dynamic value) {
  // Already a list — nothing to do.
  if (value is List) return value;

  // Single-key object wrapper: {"item": [...]} → [...].
  if (value is Map<String, dynamic> && value.length == 1) {
    final inner = value.values.first;
    if (inner is List) return inner;
  }

  // JSON-encoded array string: "[\"a\",\"b\"]" → ["a","b"].
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) return decoded;
      } catch (_) {
        // Not valid JSON — fall through.
      }
    }
  }

  return value;
}

/// Normalize a property value that is expected to be a number.
///
/// Providers sometimes stringify numbers (`"gap": "2"`). Returns the
/// int value, or [fallback] when the value is not numeric.
int coerceIntProperty(dynamic value, int fallback) {
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim()) ?? double.tryParse(value.trim());
    if (parsed != null) return parsed.toInt();
  }
  return fallback;
}

// ---------------------------------------------------------------------------
// Surface declaration (createSurface)
// ---------------------------------------------------------------------------

/// A single component in the A2UI adjacency-list model.
///
/// Components are NOT nested — they form a flat list where containers
/// reference children by id. The renderer resolves the tree at build time.
class A2uiComponent {
  /// Unique id within the surface. Referenced by parent containers.
  final String id;

  /// Component type discriminator (e.g. `'Text'`, `'Column'`, `'Button'`).
  /// Must match a registered [CatalogItem] type name.
  final String component;

  /// All other properties from the JSON payload, keyed by property name.
  /// Values can be literals or `{"path": "/field"}` data-binding refs.
  final Map<String, dynamic> properties;

  const A2uiComponent({
    required this.id,
    required this.component,
    this.properties = const {},
  });

  /// Parse from a JSON map. Expects at minimum `{"id": ..., "component": ...}`.
  /// All other keys become [properties].
  static A2uiComponent? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final component = json['component'];
    if (id is! String || id.isEmpty) return null;
    if (component is! String || component.isEmpty) return null;

    final props = Map<String, dynamic>.from(json)
      ..remove('id')
      ..remove('component');

    return A2uiComponent(id: id, component: component, properties: props);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'component': component,
    ...properties,
  };

  @override
  String toString() => 'A2uiComponent($id, $component)';
}

/// The payload of a `createSurface` message.
///
/// Contains the full initial state of a surface: component list (adjacency
/// list form) and optional data model.
class CreateSurface {
  /// Unique surface identifier. Used for action routing and updates.
  final String surfaceId;

  /// Catalog version identifier (e.g. `'crux/1.0/chat'`).
  final String catalogId;

  /// Flat list of components. The root is the component with id `'root'`
  /// or the first component if no explicit root is designated.
  final List<A2uiComponent> components;

  /// Initial data model values, keyed by field name (without leading `/`).
  final Map<String, dynamic> dataModel;

  const CreateSurface({
    required this.surfaceId,
    required this.catalogId,
    this.components = const [],
    this.dataModel = const {},
  });

  /// Parse from the value of a `"createSurface"` key in an A2UI message.
  static CreateSurface? fromJson(Map<String, dynamic> json) {
    final surfaceId = json['surfaceId'];
    if (surfaceId is! String || surfaceId.isEmpty) return null;

    final catalogId = json['catalogId'];
    if (catalogId is! String || catalogId.isEmpty) return null;

    final componentsRaw = json['components'];
    final components = <A2uiComponent>[];
    if (componentsRaw is List) {
      for (final c in componentsRaw) {
        if (c is Map<String, dynamic>) {
          final parsed = A2uiComponent.fromJson(c);
          if (parsed != null) components.add(parsed);
        }
      }
    }

    final dataModelRaw = json['dataModel'];
    final dataModel = <String, dynamic>{};
    if (dataModelRaw is Map<String, dynamic>) {
      dataModel.addAll(dataModelRaw);
    }

    return CreateSurface(
      surfaceId: surfaceId,
      catalogId: catalogId,
      components: components,
      dataModel: dataModel,
    );
  }

  Map<String, dynamic> toJson() => {
    'surfaceId': surfaceId,
    'catalogId': catalogId,
    'components': components.map((c) => c.toJson()).toList(),
    if (dataModel.isNotEmpty) 'dataModel': dataModel,
  };

  /// Find the root component — the one with id `'root'`, or the first
  /// component if no explicit root exists.
  A2uiComponent? get root {
    for (final c in components) {
      if (c.id == 'root') return c;
    }
    return components.isNotEmpty ? components.first : null;
  }

  /// Look up a component by id.
  A2uiComponent? componentById(String id) {
    for (final c in components) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  String toString() =>
      'CreateSurface($surfaceId, ${components.length} components)';
}

// ---------------------------------------------------------------------------
// Action message (client → agent)
// ---------------------------------------------------------------------------

/// An `action` message sent when the user interacts with a surface
/// (e.g. clicks a Button). This is the client→agent direction.
class A2uiAction {
  /// Action name declared by the trigger component.
  final String name;

  /// Surface that generated the action.
  final String surfaceId;

  /// Id of the component that triggered the action.
  final String sourceComponentId;

  /// Context data — typically resolved DataModel values at send time.
  final Map<String, dynamic> context;

  const A2uiAction({
    required this.name,
    required this.surfaceId,
    required this.sourceComponentId,
    this.context = const {},
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'surfaceId': surfaceId,
    'sourceComponentId': sourceComponentId,
    if (context.isNotEmpty) 'context': context,
  };

  /// Serialize as a human-readable string for tool result output.
  ///
  /// Context is a single-line JSON object so it round-trips losslessly —
  /// [tryParseDisplayString] can rebuild the surface's submitted state from
  /// the persisted message, preserving bools/numbers/lists.
  String toDisplayString() {
    final buf = StringBuffer('action: $name\n');
    buf.writeln('surface: $surfaceId');
    if (context.isNotEmpty) {
      buf.writeln('context: ${jsonEncode(context)}');
    }
    return buf.toString().trimRight();
  }

  /// Try to parse a message [content] string as a surface action
  /// produced by [toDisplayString]. Returns null for ordinary user text.
  ///
  /// Current format:
  ///
  ///     action: NAME
  ///     surface: SURFACE_ID
  ///     context: {"key": value, ...}     (optional, single-line JSON)
  ///
  /// Legacy format (emitted before the JSON switch) is also accepted:
  ///
  ///     action: NAME
  ///     surface: SURFACE_ID
  ///     context:
  ///       key: value
  ///       list: [a, b]
  static A2uiAction? tryParseDisplayString(String content) {
    final lines = content.split('\n');
    if (lines.length < 2) return null;
    final nameLine = lines[0];
    if (!nameLine.startsWith('action: ')) return null;
    final surfaceLine = lines[1];
    if (!surfaceLine.startsWith('surface: ')) return null;

    final name = nameLine.substring('action: '.length).trim();
    final surfaceId = surfaceLine.substring('surface: '.length).trim();
    if (name.isEmpty || surfaceId.isEmpty) return null;

    final context = <String, dynamic>{};
    if (lines.length >= 3 && lines[2].startsWith('context: ')) {
      final json = lines[2].substring('context: '.length).trim();
      _decodeContextJson(json, context);
    } else if (lines.length >= 3 && lines[2] == 'context:') {
      // Legacy multi-line "key: value" pairs (indented by 2 spaces).
      for (var i = 3; i < lines.length; i++) {
        final line = lines[i];
        if (!line.startsWith('  ')) break;
        final body = line.substring(2);
        final colon = body.indexOf(': ');
        final key = colon > 0 ? body.substring(0, colon) : body;
        final rawValue = colon > 0 ? body.substring(colon + 2) : '';
        if (key.isNotEmpty) context[key] = _parseLegacyValue(rawValue);
      }
    }

    return A2uiAction(
      name: name,
      surfaceId: surfaceId,
      sourceComponentId: '',
      context: context,
    );
  }

  static void _decodeContextJson(String json, Map<String, dynamic> out) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) out.addAll(decoded);
    } catch (_) {
      // Malformed context JSON — keep the action, drop the context.
    }
  }

  /// Best-effort scalar parse for legacy `key: value` context lines:
  /// bool/int/double literals, `[a, b, c]` lists, else the raw string.
  static dynamic _parseLegacyValue(String raw) {
    final v = raw.trim();
    if (v == 'true') return true;
    if (v == 'false') return false;
    if (v.startsWith('[') && v.endsWith(']')) {
      final inner = v.substring(1, v.length - 1).trim();
      if (inner.isEmpty) return const <String>[];
      return [for (final item in inner.split(',')) item.trim()];
    }
    final i = int.tryParse(v);
    if (i != null) return i;
    final d = double.tryParse(v);
    if (d != null) return d;
    return v;
  }

  @override
  String toString() => 'A2uiAction($name, surface=$surfaceId)';
}

// ---------------------------------------------------------------------------
// Data binding reference
// ---------------------------------------------------------------------------

/// A data-binding reference in a component property value.
///
/// When a property value is `{"path": "/fieldName"}`, the renderer resolves
/// it from the DataModel at render time and subscribes to changes.
class DataBinding {
  /// The JSON Pointer path (e.g. `/fieldName`, `/nested/field`).
  final String path;

  const DataBinding(this.path);

  /// Try to parse a property value as a data binding.
  /// Returns null if the value is not a `{"path": ...}` map.
  static DataBinding? tryParse(dynamic value) {
    if (value is Map<String, dynamic>) {
      final path = value['path'];
      if (path is String && path.isNotEmpty) {
        return DataBinding(path);
      }
    }
    return null;
  }

  /// Resolve this binding against a data model map.
  /// Returns the value at the path, or null if not found.
  dynamic resolve(Map<String, dynamic> dataModel) {
    // Strip leading '/' and split into segments.
    final segments = path.startsWith('/')
        ? path.substring(1).split('/')
        : path.split('/');

    dynamic current = dataModel;
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      if (current is Map<String, dynamic>) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  @override
  String toString() => 'DataBinding($path)';
}

// ---------------------------------------------------------------------------
// Surface instance (runtime state)
// ---------------------------------------------------------------------------

/// Runtime state of a surface after `createSurface` has been processed.
///
/// Tracks the component tree, the mutable data model, and whether the
/// surface has been submitted (action sent) and is therefore non-interactive.
///
/// Extends [ChangeNotifier]: mutations that affect rendering (external
/// `updateDataModel` messages, submit, restore) notify listeners so a
/// mounted [SurfaceController] rebuilds with the fresh values. Local
/// DataModel edits route through the controller (which calls
/// [updateDataModel]) and thus also notify.
class SurfaceInstance extends ChangeNotifier {
  /// The parsed createSurface payload.
  final CreateSurface declaration;

  /// Mutable data model — updated by user interactions (TextField input,
  /// CheckBox toggle, etc.) and read by data bindings at render time.
  final Map<String, dynamic> dataModel;

  /// Whether this surface has been submitted (an action was sent).
  /// When true, the surface renders in a disabled/read-only state.
  bool submitted;

  SurfaceInstance({
    required this.declaration,
    Map<String, dynamic>? dataModel,
    this.submitted = false,
  }) : dataModel = dataModel ?? Map.of(declaration.dataModel);

  /// Mark the surface as submitted. The data model already holds exactly
  /// what was sent (components mutate it live), and submitted components
  /// are read-only — so the live model IS the frozen record of the
  /// submission.
  void markSubmitted() {
    if (submitted) return;
    submitted = true;
    notifyListeners();
  }

  /// The data model the renderer reads — the live model, which after
  /// submission holds the submitted values (no further edits possible).
  Map<String, dynamic> get renderDataModel => dataModel;

  /// Rebuild submitted state from a persisted action's context, as
  /// recorded in the chat history by the original submission. Used when
  /// the surface instance is recreated from the tool call (app restart,
  /// session switch) — the surface renders the submitted values instead
  /// of resetting to the declaration's initial state.
  ///
  /// Context keys are DataModel field names (the agent binds values via
  /// `{"path": "/field"}` which resolves to the field name in the action
  /// context).
  void restoreSubmitted(A2uiAction action) {
    submitted = true;
    // Merge the submitted values into the existing model instead of
    // clearing it — the declaration may carry nested structures that
    // the flat action context doesn't cover (e.g. "/form/name" paths
    // create {"form": {"name": ...}} but the action context has flat
    // keys like {"name": ...}). Merging preserves whatever the
    // declaration set up.
    dataModel.addAll(action.context);
    notifyListeners();
  }

  String get surfaceId => declaration.surfaceId;

  /// Update a value in the data model by path.
  ///
  /// Notifies listeners — mounted [SurfaceController]s rebuild so
  /// data-bound components (Text, ProgressBar, Table, …) re-resolve.
  void updateDataModel(String path, dynamic value) {
    final segments = path.startsWith('/')
        ? path.substring(1).split('/')
        : path.split('/');

    Map<String, dynamic> current = dataModel;
    for (var i = 0; i < segments.length - 1; i++) {
      final segment = segments[i];
      if (segment.isEmpty) continue;
      if (current[segment] is! Map<String, dynamic>) {
        current[segment] = <String, dynamic>{};
      }
      current = current[segment] as Map<String, dynamic>;
    }
    if (segments.isNotEmpty && segments.last.isNotEmpty) {
      current[segments.last] = value;
    }
    notifyListeners();
  }

  /// Read a value from the data model by path.
  dynamic readDataModel(String path) {
    return DataBinding(path).resolve(dataModel);
  }

  @override
  String toString() =>
      'SurfaceInstance($surfaceId, submitted=$submitted, '
      '${declaration.components.length} components)';
}

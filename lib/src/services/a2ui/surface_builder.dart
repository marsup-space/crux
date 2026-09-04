/// Type-safe declarations for app-owned A2UI surfaces.
///
/// Agent-authored surfaces arrive as JSON. App-owned UI should use this small
/// builder instead: it produces the identical [CreateSurface] wire model
/// without scattering stringly-typed maps throughout home and plugin hosts.
library;

import 'models.dart';

class SurfaceBuilder {
  final String surfaceId;
  final String catalogId;
  final List<A2uiComponent> _components = [];

  SurfaceBuilder({required this.surfaceId, this.catalogId = 'crux/1.0/chat'});

  SurfaceBuilder column(String id, List<String> children) {
    return _add(id, 'Column', {'children': children});
  }

  SurfaceBuilder row(String id, List<String> children, {int gap = 0}) {
    return _add(id, 'Row', {'children': children, 'gap': gap});
  }

  SurfaceBuilder text(String id, String text) =>
      _add(id, 'Text', {'text': text});

  SurfaceBuilder keyValue(
    String id, {
    required String label,
    required String value,
    int? labelWidth,
    bool selected = false,
    bool muted = false,
  }) => _add(id, 'KeyValue', {
    'label': label,
    'value': value,
    'labelWidth': ?labelWidth,
    'selected': selected,
    'muted': muted,
  });

  SurfaceBuilder divider(String id) => _add(id, 'Divider', const {});

  SurfaceBuilder card(String id, {required String child, String? title}) =>
      _add(id, 'Card', {'child': child, 'title': ?title});

  SurfaceBuilder section(
    String id, {
    required String title,
    required String child,
  }) => _add(id, 'Section', {'title': title, 'child': child});

  SurfaceBuilder badge(
    String id, {
    required String text,
    String tone = 'neutral',
  }) => _add(id, 'Badge', {'text': text, 'tone': tone});

  SurfaceBuilder stat(
    String id, {
    required String label,
    required String value,
  }) => _add(id, 'Stat', {'label': label, 'value': value});

  SurfaceBuilder listItem(
    String id, {
    required String title,
    String? leading,
    String? detail,
    String? badge,
    bool selected = false,
    String? action,
    Map<String, dynamic> actionContext = const {},
  }) => _add(id, 'ListItem', {
    'title': title,
    'leading': ?leading,
    'detail': ?detail,
    'badge': ?badge,
    'selected': selected,
    'action': action == null
        ? null
        : {
            'event': {'name': action, 'context': actionContext},
          },
  });

  SurfaceBuilder barList(String id, List<Map<String, dynamic>> rows) =>
      _add(id, 'BarList', {'rows': rows});

  SurfaceBuilder _add(String id, String component, Map<String, dynamic> props) {
    _components.add(
      A2uiComponent(id: id, component: component, properties: props),
    );
    return this;
  }

  CreateSurface build({Map<String, dynamic> dataModel = const {}}) =>
      CreateSurface(
        surfaceId: surfaceId,
        catalogId: catalogId,
        components: List.unmodifiable(_components),
        dataModel: dataModel,
      );
}

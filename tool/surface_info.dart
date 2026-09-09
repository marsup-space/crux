/// 验收辅助：dump surface 工具的系统 prompt 段和工具 schema。
///
/// Usage:
///   dart run tool/surface_info.dart prompt   # 系统 prompt 的 surface 段
///   dart run tool/surface_info.dart tool     # surface 工具的 LLM-facing schema
///   dart run tool/surface_info.dart catalog  # catalog 注册的所有组件类型
///   dart run tool/surface_info.dart all      # 以上全部
library;

import 'dart:convert';

import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/surface_prompt_builder.dart';
import 'package:crux/src/tools/surface_tool.dart';

void main(List<String> args) {
  final mode = args.isEmpty ? 'all' : args.first;
  final catalog = createBasicCatalog();

  if (mode == 'prompt' || mode == 'all') {
    print('════════════════════════════════════════');
    print('  System prompt — Generative UI section');
    print('════════════════════════════════════════');
    print(buildSurfacePromptSection(catalog));
    print('');
  }

  if (mode == 'tool' || mode == 'all') {
    print('════════════════════════════════════════');
    print('  surface tool — LLM-facing schema');
    print('════════════════════════════════════════');
    final tool = SurfaceTool(catalog: catalog);
    final schema = {
      'name': tool.name,
      'description': tool.description,
      'parameters': tool.parametersSchema,
    };
    print(const JsonEncoder.withIndent('  ').convert(schema));
    print('');
  }

  if (mode == 'catalog' || mode == 'all') {
    print('════════════════════════════════════════');
    print('  Catalog — registered component types');
    print('════════════════════════════════════════');
    for (final item in catalog.all) {
      print('  ${item.typeName}: ${item.description}');
    }
    print('');
    print('  Catalog ID: ${catalog.catalogId}');
    print('');
  }
}

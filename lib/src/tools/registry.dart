import 'tool_def.dart';
import 'bash_tool.dart';
import 'read_tool.dart';
import 'write_tool.dart';
import 'edit_tool.dart';
import 'grep_tool.dart';
import 'glob_tool.dart';
import 'webfetch_tool.dart';
import 'file_read_tracker.dart';

class ToolRegistry {
  final Map<String, ToolDef> _tools = {};

  void register(ToolDef tool) {
    _tools[tool.name.toLowerCase()] = tool;
  }

  ToolDef? lookup(String name) => _tools[name.toLowerCase()];

  List<ToolDef> get all => List.unmodifiable(_tools.values);

  List<Map<String, dynamic>> toApiTools() {
    return _tools.values
        .map(
          (tool) => {
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.parametersSchema,
          },
        )
        .toList();
  }

  void registerDefaults(FileReadTracker tracker) {
    register(BashTool());
    register(ReadTool());
    register(WriteTool(tracker: tracker));
    register(EditTool(tracker: tracker));
    register(GrepTool());
    register(GlobTool());
    register(WebFetchTool());
  }
}

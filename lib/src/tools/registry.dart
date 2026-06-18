import 'dart:io';

import 'bash_tool.dart';
import 'cmd_tool.dart';
import 'edit_tool.dart';
import 'file_read_tracker.dart';
import 'glob_tool.dart';
import 'grep_tool.dart';
import 'powershell_tool.dart';
import 'read_tool.dart';
import 'tool_def.dart';
import 'webfetch_tool.dart';
import 'write_tool.dart';

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

  /// Register default tools. [lsp] is optional — when provided, edit
  /// and write tools surface diagnostics from language servers after
  /// each successful mutation, and the read tool warms the server
  /// in the background so subsequent edits are fast. Pass null to
  /// disable LSP feedback.
  void registerDefaults(FileReadTracker tracker, {dynamic lsp}) {
    if (Platform.isWindows) {
      register(CmdTool());
      register(PowerShellTool());
    } else {
      register(BashTool());
    }
    register(ReadTool(tracker: tracker, lsp: lsp));
    register(WriteTool(tracker: tracker, lsp: lsp));
    register(EditTool(tracker: tracker, lsp: lsp));
    register(GrepTool());
    register(GlobTool());
    register(WebFetchTool());
  }
}

import 'dart:io';

import '../storage/session_store.dart';
import 'bash_tool.dart';
import 'cmd_tool.dart';
import 'edit_tool.dart';
import 'file_read_tracker.dart';
import 'glob_tool.dart';
import 'grep_tool.dart';
import 'powershell_tool.dart';
import 'find_similar_code_tool.dart';
import 'read_tool.dart';
import 'semantic_search_tool.dart';
import 'session_tool.dart';
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
  ///
  /// [sessionStore] powers the read-only `session` tool, which lets
  /// the agent list sessions, page through messages, and search
  /// across conversations without shelling out to sqlite3.
  void registerDefaults(
    FileReadTracker tracker, {
    required SessionStore sessionStore,
    dynamic lsp,
  }) {
    // Tool registration order = order the LLM sees in the API tools list.
    // Tier 1 first so the model's first scan of the list lands on the
    // specialized tools (see the "Tool tiers" + "Codebase exploration"
    // rules in the system prompt), Tier 2 next (file ops the agent
    // needs once it has a specific path or pattern in hand), then
    // Tier 3 (general shell — last resort), then meta.
    register(SemanticSearchTool());
    register(FindSimilarCodeTool());
    register(WebFetchTool());
    register(ReadTool(tracker: tracker, lsp: lsp));
    register(WriteTool(tracker: tracker, lsp: lsp));
    register(EditTool(tracker: tracker, lsp: lsp));
    register(GrepTool());
    register(GlobTool());
    if (Platform.isWindows) {
      register(CmdTool());
      register(PowerShellTool());
    } else {
      register(BashTool());
    }
    register(SessionTool(store: sessionStore));
  }
}

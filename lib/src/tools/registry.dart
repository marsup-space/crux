import 'dart:io';

import '../services/web_provider_registry.dart';
import '../storage/session_store.dart';
import 'ask_tool.dart';
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
import 'skill_tool.dart';
import 'tool_def.dart';
import 'webfetch_tool.dart';
import 'websearch_tool.dart';
import 'write_tool.dart';

class ToolRegistry {
  final Map<String, ToolDef> _tools = {};

  void register(ToolDef tool) {
    _tools[tool.name.toLowerCase()] = tool;
  }

  /// Remove a tool by name. No-op if the name isn't registered.
  /// Used by the `/web-provider <name> key …` command to flip
  /// `websearch` in and out of the LLM's tool list when the
  /// key state changes.
  void unregister(String name) {
    _tools.remove(name.toLowerCase());
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
  ///
  /// [webProviderRegistry] powers `webfetch` (routes through a
  /// configured provider when available, falls back to raw HTML
  /// otherwise) and `websearch` (only registered when at least
  /// one search-capable provider is configured). See
  /// [rebuildWebTools] for the dynamic-update path used when
  /// the user runs `/web-provider <name> key <value>`.
  void registerDefaults(
    FileReadTracker tracker, {
    required SessionStore sessionStore,
    required WebProviderRegistry webProviderRegistry,
    dynamic lsp,
    PendingAskCubit? pendingAskCubit,
  }) {
    // Tool registration order = order the LLM sees in the API tools list.
    // Tier 1 first so the model's first scan of the list lands on the
    // specialized tools (see the "Tool tiers" + "Codebase exploration"
    // rules in the system prompt), Tier 2 next (file ops the agent
    // needs once it has a specific path or pattern in hand), then
    // Tier 3 (general shell — last resort), then meta.
    register(SemanticSearchTool());
    register(FindSimilarCodeTool());
    registerWebTools(webProviderRegistry);
    register(ReadTool(tracker: tracker, lsp: lsp));
    register(WriteTool(tracker: tracker, lsp: lsp));
    register(EditTool(tracker: tracker, lsp: lsp));
    register(GrepTool());
    register(GlobTool());
    register(SkillTool());
    if (Platform.isWindows) {
      register(CmdTool());
      register(PowerShellTool());
    } else {
      register(BashTool());
    }
    register(SessionTool(store: sessionStore));
    // `ask` is registered only when a [PendingAskCubit] is supplied —
    // i.e. in the real TUI. Tests and standalone tools that build a
    // registry without UI plumbing get no `ask` tool, so the model
    // falls back to `ask://` inline tokens (which need no UI at all).
    if (pendingAskCubit != null) {
      register(AskTool(pendingAskCubit: pendingAskCubit));
    }
  }

  /// Re-register the web tools to match the current provider
  /// state. Call this after any change to the
  /// [WebProviderRegistry]'s key set — typically wired up via
  /// `webProviderRegistry.changes` so the LLM sees the new tool
  /// list on its very next turn.
  ///
  /// - `webfetch` is always registered (it works without a
  ///   provider, just noisier).
  /// - `websearch` is only registered when at least one
  ///   search-capable provider reports `isConfigured`.
  void registerWebTools(WebProviderRegistry webProviderRegistry) {
    // Drop any previous web tools so a stale instance never
    // lingers — the closure over the registry means a new
    // instance picks up the latest key state.
    unregister('webfetch');
    unregister('websearch');

    register(WebFetchTool(webProviderRegistry));
    if (webProviderRegistry.isAnySearchProviderConfigured) {
      register(WebSearchTool(webProviderRegistry));
    }
  }
}

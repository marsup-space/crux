import 'dart:convert';

import 'package:path/path.dart' as p;

import '../i18n/reply_language.dart';
import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../storage/session_store.dart';
import 'tool_executor.dart';
import '../utils/token_estimate.dart';
import 'prompts/system_prompt.dart';
import 'prompts/environment_meta.dart';
import 'provider_service.dart';

/// Wire-format conversion and token math for the chat subsystem.
///
/// Extracted from `chat_service.dart` so the LLM-API message building
/// and context-size accounting live in their own file, independent
/// of the agentic loop and compaction engine.

/// Build the LLM-API-compatible message list from the internal
/// message history. Handles:
///   - System prompt injection
///   - Compaction-aware history pruning (skip messages before the
///     latest compaction)
///   - Multi-modal image content (Anthropic vs OpenAI format)
///   - Thinking/reasoning blocks (Anthropic format)
///   - Tool call + tool result pairing (Anthropic vs OpenAI format)
///
/// [includeImages] is the model-capability gate for image parts: pass `false`
/// when the target model declares `image_support = false`, which turns every
/// user row into its text only. A model that cannot read images rejects the
/// whole request over them — Zhipu answers `400 / 1210 messages.content.type
/// 参数非法，取值范围 ['text']` — and because attached images live on the
/// history rows, one such row would otherwise fail every later turn too. The
/// `[ image N ]` markers stay in the text: they are the user's own message.
List<Map<String, dynamic>> buildApiMessages(
  List<Message> history,
  WireFamily wireFamily, {
  String? systemPrompt,
  bool includeImages = true,
}) {
  final result = <Map<String, dynamic>>[];

  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    result.add({'role': 'system', 'content': systemPrompt});
  }

  var lastCompactionIdx = -1;
  for (var i = 0; i < history.length; i++) {
    if (history[i].role == 'compaction' &&
        _isCompleteCompactionMessage(history[i])) {
      lastCompactionIdx = i;
    }
  }

  for (var i = 0; i < history.length; i++) {
    final m = history[i];

    if (lastCompactionIdx >= 0 && i < lastCompactionIdx) {
      continue;
    }

    switch (m.role) {
      case 'user':
        // UI-only rows never reach the model. A worker→commander report is
        // persisted as `role: 'user'` + empty content + `agentBubble` meta
        // (see `subagent_meta.dart`) purely so the chat log can draw the
        // bubble; the wake turn that follows reads its payload from the
        // system prompt's "Internal Subagent events" section. Emitting the
        // row as an empty user message makes the request malformed on the
        // OpenAI-compatible wire — Zhipu rejects it with `400 / 1213
        // 未正常接收到prompt参数` ("parameter prompt was not received") and
        // Anthropic refuses an empty text block outright. The wire layer is
        // the single gate that decides what the model sees, so the drop
        // belongs here; the row stays in the store for the UI.
        if (m.content.trim().isEmpty && m.images.isEmpty) break;
        if (includeImages && m.images.isNotEmpty) {
          final content = <Map<String, dynamic>>[];
          for (final img in m.images) {
            if (wireFamily == WireFamily.anthropicCompatible) {
              content.add({
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': img.mediaType,
                  'data': img.base64Data,
                },
              });
            } else {
              content.add({
                'type': 'image_url',
                'image_url': {
                  'url': 'data:${img.mediaType};base64,${img.base64Data}',
                },
              });
            }
          }
          if (m.content.isNotEmpty) {
            content.add({'type': 'text', 'text': m.content});
          }
          result.add({'role': 'user', 'content': content});
        } else {
          result.add({'role': 'user', 'content': m.content});
        }
      case 'compaction':
        if (_isCompleteCompactionMessage(m)) {
          result.add({
            'role': 'user',
            'content': _renderCompactionSummaryForModel(m.content),
          });
        }
      case 'system':
        result.add({'role': 'system', 'content': m.content});
      case 'ai':
        if (wireFamily == WireFamily.anthropicCompatible &&
            m.reasoningContent.isNotEmpty &&
            m.reasoningSignature.isNotEmpty) {
          result.add({
            'role': 'assistant',
            'content': [
              {
                'type': 'thinking',
                'thinking': m.reasoningContent,
                'signature': m.reasoningSignature,
              },
              if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
            ],
          });
        } else {
          result.add({
            'role': 'assistant',
            'content': m.content.isEmpty ? null : m.content,
            // Responses API (DeepSeek): the assistant's chain-of-thought
            // must be passed back on tool-call rounds or the API 400s
            // ("The reasoning_text in the thinking mode must be passed
            // back to the API"). Non-Anthropic wires keep the OpenAI-IR
            // `reasoning_content` field for the provider's
            // buildRequestBody to emit.
            if (wireFamily == WireFamily.responsesApi &&
                m.reasoningContent.isNotEmpty)
              'reasoning_content': m.reasoningContent,
          });
        }
      case 'tool_call':
        if (wireFamily == WireFamily.anthropicCompatible) {
          final content = <Map<String, dynamic>>[];
          if (m.reasoningContent.isNotEmpty &&
              m.reasoningSignature.isNotEmpty) {
            content.add({
              'type': 'thinking',
              'thinking': m.reasoningContent,
              'signature': m.reasoningSignature,
            });
          }
          if (m.content.isNotEmpty) {
            content.add({'type': 'text', 'text': m.content});
          }
          for (final call in m.toolCalls) {
            content.add({
              'type': 'tool_use',
              'id': call.callId,
              'name': call.name,
              'input': call.input,
            });
          }
          result.add({'role': 'assistant', 'content': content});
        } else {
          final toolCalls = m.toolCalls
              .map(
                (call) => {
                  'id': call.callId,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': jsonEncode(call.input),
                  },
                },
              )
              .toList();
          result.add({
            'role': 'assistant',
            'content': m.content.isNotEmpty ? m.content : null,
            // Same reasoning pass-back requirement as the `ai` role:
            // tool-call rounds must carry the assistant's CoT for the
            // Responses API (DeepSeek).
            if (wireFamily == WireFamily.responsesApi &&
                m.reasoningContent.isNotEmpty)
              'reasoning_content': m.reasoningContent,
            'tool_calls': toolCalls,
          });
        }
      case 'tool':
        if (wireFamily == WireFamily.anthropicCompatible) {
          final last = result.isNotEmpty ? result.last : null;
          final toolResult = {
            'type': 'tool_result',
            'tool_use_id': m.toolCallId,
            'content': m.content,
          };
          if (last != null &&
              last['role'] == 'user' &&
              last['content'] is List) {
            (last['content'] as List<dynamic>).add(toolResult);
          } else {
            result.add({
              'role': 'user',
              'content': [toolResult],
            });
          }
        } else {
          result.add({
            'role': 'tool',
            'tool_call_id': m.toolCallId,
            'content': m.content,
          });
        }
    }
  }

  return result;
}

/// Single source of truth: the size of the prompt the LLM will see
/// for [messages] on the next turn, including system + tool defs
/// (implicitly, via the last AI's `tokensIn`) and any
/// [incomingUserContent] the user has typed but not yet sent.
int currentContextTokens({
  required List<Message> messages,
  String? systemPrompt,
  List<Map<String, dynamic>>? toolDefs,
  String? incomingUserContent,
}) {
  int lastAiIdx = -1;
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m.role == 'ai' && m.tokensIn > 0) {
      lastAiIdx = i;
      break;
    }
  }
  if (lastAiIdx < 0) {
    var total =
        estimateTokens(systemPrompt ?? '') +
        estimateToolDefsTokens(toolDefs ?? const []);
    for (final m in messages) {
      total += _contentOnlyMessageTokens(m);
    }
    if (incomingUserContent != null && incomingUserContent.isNotEmpty) {
      total += estimateTokens(incomingUserContent);
    }
    return total;
  }
  final lastAi = messages[lastAiIdx];
  final visibleResponse = (lastAi.tokensOut - lastAi.reasoningTokens).clamp(
    0,
    1 << 31,
  );
  var total = lastAi.tokensIn + visibleResponse;
  for (var i = lastAiIdx + 1; i < messages.length; i++) {
    total += _contentOnlyMessageTokens(messages[i]);
  }
  if (incomingUserContent != null && incomingUserContent.isNotEmpty) {
    total += estimateTokens(incomingUserContent);
  }
  return total;
}

/// Compute the next-turn projected prompt size in tokens.
int estimateProjectedContextTokens({
  required Session session,
  required String? systemPrompt,
  required List<Message> history,
  required String? incomingUserContent,
  required List<Map<String, dynamic>> toolDefs,
}) {
  if (session.contextTokens > 0) {
    return session.contextTokens +
        (incomingUserContent != null && incomingUserContent.isNotEmpty
            ? estimateTokens(incomingUserContent)
            : 0);
  }
  return currentContextTokens(
    messages: history,
    systemPrompt: systemPrompt,
    toolDefs: toolDefs,
    incomingUserContent: incomingUserContent,
  );
}

/// Compute the reserve and threshold for auto-compaction.
({int reserve, int threshold}) computeCompactionReserveAndThreshold({
  required int contextSize,
}) {
  const reserve = 10000;
  final threshold = contextSize - reserve;
  return (reserve: reserve, threshold: threshold);
}

// ── Private helpers ────────────────────────────────────────────────

int _contentOnlyMessageTokens(Message m) {
  var total = estimateTokens(m.content);
  if (m.reasoningContent.isNotEmpty) {
    total += estimateTokens(m.reasoningContent);
  }
  for (final call in m.toolCalls) {
    total += estimateToolRoundTripTokens(
      toolName: call.name,
      args: call.input,
      resultOutput: '',
    );
  }
  return total;
}

String _renderCompactionSummaryForModel(String summary) {
  return '## Compacted history (from earlier in this session)\n\n$summary';
}

bool _isCompleteCompactionMessage(Message message) {
  if (message.meta.isEmpty) return true;
  try {
    final decoded = jsonDecode(message.meta);
    if (decoded is Map<String, dynamic>) {
      return (decoded['status'] as String? ?? 'complete') == 'complete';
    }
  } catch (_) {
    return true;
  }
  return true;
}

/// Compute a project-relative path for the file referenced by a tool
/// call, used by the LSP-diagnostics bubble.
String relativeFilePathFromCall(ToolCall call, String projectPath) {
  final raw = call.input['filePath'];
  if (raw is! String || raw.isEmpty) return '';
  final abs = p.isAbsolute(raw)
      ? p.normalize(raw)
      : p.normalize(p.join(projectPath, raw));
  final rel = p.relative(abs, from: projectPath);
  if (rel.startsWith('..') || p.isAbsolute(rel)) return abs;
  return rel;
}

/// Resolved provider + model + API key for a chat turn. Built by
/// [ResolvedChatTarget.resolve] and consumed by both the turn executor
/// and the compaction engine.
class ResolvedChatTarget {
  final String providerName;
  final String modelId;
  final ProviderConfig provider;
  final String apiKey;
  final ModelConfig modelConfig;
  final String? systemPrompt;

  const ResolvedChatTarget({
    required this.providerName,
    required this.modelId,
    required this.provider,
    required this.apiKey,
    required this.modelConfig,
    required this.systemPrompt,
  });

  /// Resolve the chat target for [session], building + caching the
  /// system prompt when it isn't already on the session row.
  static Future<ResolvedChatTarget?> resolve(
    Session session,
    ProviderService providerService,
    SessionStore store, {
    ReplyLanguageSettings replyLanguage = ReplyLanguageSettings.fallback,
  }) async {
    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    final providerName = slashIndex > 0
        ? compositeKey.substring(0, slashIndex)
        : '';
    final modelId = slashIndex > 0
        ? compositeKey.substring(slashIndex + 1)
        : compositeKey;

    final provider = providerService.providerByName(providerName);
    final apiKey = providerService.getApiKey(providerName);
    final modelConfig = provider?.modelById(modelId);
    if (provider == null ||
        apiKey == null ||
        apiKey.isEmpty ||
        modelConfig == null) {
      return null;
    }

    String? systemPrompt = session.systemPrompt;
    final staleChat = session.isChat && isStaleChatSystemPrompt(systemPrompt);
    final staleWorkspace =
        !session.isChat && isStaleWorkspaceSystemPrompt(systemPrompt);
    // Detect model change: if the cached prompt's env block names a
    // different model than the session's current model, rebuild so the
    // env block reflects the active model. This handles the case where
    // the user switches models via /model but doesn't send a message
    // before switching back — the prompt is rebuilt on the next turn
    // with whichever model is current at send time.
    final cachedModelId = extractModelIdFromPrompt(systemPrompt);
    final modelChanged = cachedModelId != null && cachedModelId != modelId;
    if (systemPrompt == null ||
        systemPrompt.isEmpty ||
        staleChat ||
        staleWorkspace ||
        modelChanged) {
      systemPrompt = session.isChat
          ? buildChatSystemPrompt(
              provider: provider,
              model: modelConfig,
              sessionStarted: session.createdAt,
              replyLanguage: replyLanguage,
            )
          : buildSystemPrompt(
              provider: provider,
              model: modelConfig,
              cwd: session.projectPath,
              worktree: session.projectPath,
              sessionStarted: session.createdAt,
              replyLanguage: replyLanguage,
            );
      session.systemPrompt = systemPrompt;
      await store.update(session.id, systemPrompt: systemPrompt);
    }

    return ResolvedChatTarget(
      providerName: providerName,
      modelId: modelId,
      provider: provider,
      apiKey: apiKey,
      modelConfig: modelConfig,
      systemPrompt: systemPrompt,
    );
  }
}

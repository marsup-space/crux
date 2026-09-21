import 'dart:async';

import '../../models/provider_config.dart';
import '../../models/subagent.dart';
import '../../storage/database.dart' as db;
import '../../tools/tool_def.dart';
import '../llm_client.dart';
import '../llm_error.dart';
import '../provider_service.dart';
import '../tool_executor.dart';
import 'subagent_distiller.dart';
import 'subagent_prompts.dart';

/// A single in-memory subagent run — one assignment executing in the
/// background with its own isolated turn loop.
///
/// The runner reuses the app's production LLM plumbing ([LlmClient]
/// streaming + [ToolExecutor] for tool calls) but owns none of the
/// session persistence: a run lives only in memory and ends with a
/// report string handed to a callback. The main agent is never
/// blocked — `send_agent` / `hire_agent` return before the first
/// token streams.
///
/// Lifecycle (owned by [SubagentManager]):
///
///     created ──▶ streaming (round 1..N tool loop) ──▶ done
///                    │ cancel()                          │ onDone
///                    ▼                                   ▼
///                 cancelled                            report envelope
///
/// Round cap: a run that needs more than [maxRounds] LLM rounds is
/// stopped and told to report what it has (the report says so).
/// `null` means no cap — the run only ends when the model answers
/// without tool calls, fails, or is cancelled.
class SubagentRunner {
  final String agentName;
  final db.Agent profile;
  final SubagentRole role;
  final String intention;
  final String message;
  final ProviderService providerService;
  final ToolExecutor toolExecutor;

  /// Tools this run may use — already filtered by role (worker:
  /// everything except subagent tools; expert: [kExpertToolNames]).
  final List<ToolDef> tools;

  /// Completed-report callback. Receives the status word
  /// (`completed` / `failed` / `cancelled`) and the report body.
  final void Function(String status, String report) onDone;

  /// Streaming-status callback for check_agent / UI chips.
  final void Function(SubagentRunStatus status)? onStatus;

  /// Maximum LLM rounds before the run is stopped and told to report.
  /// Null = unlimited (the run ends only on a terminal answer, an
  /// error, or cancel).
  final int? maxRounds;
  final String userLanguage;
  final String workingDirectory;
  final int sessionId;

  /// The bound model's context capacity (tokens). The three-stage
  /// gate estimates the running history against a fraction of this
  /// (tools definitions + response headroom consume the rest).
  final int contextCapacity;

  /// Write path for distillation products (the roster's
  /// knowledge / worklog columns). Optional — null keeps the run
  /// self-contained (tests).
  final Future<void> Function(String name, DistillationProducts products)?
  onDistilled;

  /// Client seam: production runs leave this null and a plain
  /// [LlmClient] is built lazily; tests inject a scriptable fake.
  final LlmClient? clientOverride;
  late final LlmClient _client = clientOverride ?? LlmClient();

  final AbortSignal _abort = AbortSignal();
  StreamSubscription<LlmChunk>? _sub;
  bool _cancelled = false;
  bool _finished = false;

  SubagentRunner({
    required this.agentName,
    required this.profile,
    required this.role,
    required this.intention,
    required this.message,
    required this.providerService,
    required this.toolExecutor,
    required this.tools,
    required this.onDone,
    required this.sessionId,
    required this.workingDirectory,
    this.onStatus,
    this.clientOverride,
    this.maxRounds = 40,
    this.userLanguage = 'English',
    this.contextCapacity = 128000,
    this.onDistilled,
  });

  bool get isFinished => _finished;

  /// Live progress snapshot for check_agent and the toolbar chips.
  SubagentRunStatus snapshot() => SubagentRunStatus(
    agentName: agentName,
    round: _round,
    lastTool: _lastTool,
    status: _cancelled
        ? 'cancelled'
        : (_finished ? 'done' : (_round == 0 ? 'starting' : 'running')),
  );

  int _round = 0;
  String? _lastTool;

  /// Start the background run. Returns immediately; progress and the
  /// final report arrive via [onStatus] / [onDone].
  Future<void> start() async {
    // NOTE: do NOT abort here — the abort signal is the cancellation
    // channel (cancel() sets it). Aborting at start would make every
    // tool call observe isAborted and return immediately, so the run
    // could never do any work.
    await _runLoop();
  }

  /// Cancel the run: force-close the stream, mark cancelled. The
  /// loop's await-points observe the abort and exit; [onDone] fires
  /// with `cancelled` and a partial-progress report.
  void cancel() {
    if (_finished) return;
    _cancelled = true;
    _abort.abort();
    _sub?.cancel();
  }

  Future<void> _runLoop() async {
    final resolved = _resolveModel();
    if (resolved == null) {
      _finish(
        'failed',
        'No provider serves model ${profile.model} — '
            'cannot start the run.',
      );
      return;
    }
    final (provider, apiKey, modelId) = resolved;
    // Local copy so the nullable round cap promotes in the comparisons
    // below (a public field never promotes).
    final cap = maxRounds;

    // Build the opening context: system prompt (identity + distilled
    // memory + assignment) followed by the dispatching message.
    final history = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': subagentSystemPrompt(
          agentName: agentName,
          role: role,
          domain: profile.domain,
          knowledge: profile.knowledge,
          worklog: profile.worklog,
          intention: intention,
          userLanguage: userLanguage,
        ),
      },
      {'role': 'user', 'content': message},
    ];

    var systemText = '';
    var roundReport = '';
    var fullEvents = 0;

    while ((cap == null || _round < cap) && !_cancelled) {
      // ── Three-stage context gate (plan §上下文与蒸馏) ──────────
      // Estimate the running history against a working fraction of
      // the model's window (the tool definitions and the response
      // headroom claim the rest). On pressure, escalate: compact
      // twice, then distill-and-resume on the third event.
      final pressure = history.estimatedTokens > contextCapacity * 0.75;
      if (pressure) {
        final stage = stageFor(fullEvents);
        if (stage == DistillationStage.distill) {
          final resumed = await _distillAndResume(
            provider,
            apiKey,
            modelId,
            history,
          );
          if (resumed == null) {
            _finish(
              'failed',
              'Context filled a third time and distillation failed. '
                  'Partial work:\n$roundReport',
            );
            return;
          }
          history
            ..clear()
            ..addAll(resumed);
          fullEvents++;
          continue; // Round counter unchanged: resumption is not a round.
        }
        // Stage 1–2: drop tool-result payloads (keep the call lines),
        // the lightweight in-run "compact".
        _compactHistory(history);
        fullEvents++;
      }

      _round++;
      onStatus?.call(snapshot());

      final chunks = <LlmChunk>[];
      LlmError? streamError;

      try {
        final stream = _client.streamChat(
          endpointUrl: provider.endpointUrl,
          config: provider,
          apiKey: apiKey,
          modelId: modelId,
          messages: history,
          thinkingMode: 'enabled',
          tools: _toolsDefinition(),
          userId: 'subagent-$agentName',
          cancelToken: _cancelToken(),
        );
        _sub = stream.listen((chunk) {
          if (chunk.error != null) {
            streamError = chunk.error;
            return;
          }
          chunks.add(chunk);
        }, cancelOnError: true);
        await _sub!.asFuture().catchError((Object e) {});
      } catch (e) {
        streamError = LlmError(
          kind: LlmErrorKind.unknown,
          vendor: LlmVendor.unknown,
          message: '$e',
        );
      }
      _sub = null;

      if (_cancelled) break;

      if (streamError != null) {
        // One retry round is built into the loop: a stream error on a
        // round with no collected tool calls ends the run as failed;
        // otherwise we keep the tool results and report the failure.
        _finish(
          'failed',
          'Model stream failed at round $_round: '
              '${streamError!.toUserMessage()}',
        );
        return;
      }

      systemText = _textOf(chunks);
      final calls = ToolExecutor.parseToolUseFromChunks(chunks);
      final finish = ToolExecutor.parseFinishReason(chunks);

      if (calls.isEmpty || finish != 'tool_use') {
        // Terminal round: the model answered with no tool calls.
        roundReport = systemText;
        break;
      }

      // Execute the round's tool calls, then continue the loop.
      history.add(
        toolExecutor.formatAssistantToolCallsMessage(
          calls,
          systemText,
          provider.wireFamily,
        ),
      );
      for (final call in calls) {
        _lastTool = call.name;
        onStatus?.call(snapshot());
        final result = await toolExecutor.executeTool(
          call,
          ToolContext(
            sessionId: sessionId,
            messageId: 0,
            abort: _abort,
            callId: call.callId,
            workingDirectory: workingDirectory,
          ),
        );
        history.add(
          toolExecutor.formatToolResultForApi(
            call,
            result,
            provider.wireFamily,
          ),
        );
        if (_cancelled) break;
      }
    }

    if (_cancelled) {
      _finish(
        'cancelled',
        roundReport.isEmpty
            ? 'Cancelled at round $_round before any output.'
            : 'Cancelled at round $_round. Partial work:\n$roundReport',
      );
      return;
    }
    if (cap != null && _round >= cap) {
      // Out of rounds: ONE final LLM exchange collects the interim
      // report instead of hard-cutting the run. A hard cut at this
      // point usually lands mid-tool-work and loses everything since
      // the model's last prose. The stop notice forbids further tool
      // use; the model's plain-text answer becomes the report. See
      // [_requestInterimReport] for the failure fallback.
      final interim = await _requestInterimReport(
        provider,
        apiKey,
        modelId,
        history,
        systemText,
        cap,
      );
      _finish(
        interim == null ? 'round_cap_no_report' : 'round_cap',
        interim ?? '(no interim report — the round-capped run could not '
            'produce one; partial text below if any)\n$systemText',
      );
      return;
    }
    _finish('completed', roundReport);
  }

  /// Tools definition for every LLM request of this run. The main
  /// loop and the final stop-notice exchange send the IDENTICAL list
  /// (byte-for-byte) — dropping or reordering tools on the last
  /// request would invalidate the provider's prompt cache for the
  /// whole conversation.
  List<Map<String, dynamic>>? _toolsDefinition() => tools.isNotEmpty
      ? [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parametersSchema,
            },
        ]
      : null;

  /// Final exchanges after the round cap: append the stop notice (see
  /// [kSubagentRoundCapStopNotice]) to the history and stream replies
  /// with the SAME tools definition (never null — cache prefix must
  /// stay identical). A defying tool call is intercepted at the
  /// SYSTEM level: not executed, not written into the history as a
  /// tool_use; instead the stop notice is repeated verbatim and the
  /// model is asked again, up to [maxStopNoticeRepeats] times. The
  /// first plain-text reply becomes the interim report.
  ///
  /// Returns null when every attempt fails (stream error, cancel, or
  /// a model that keeps calling tools) — the caller falls back to the
  /// last prose it has.
  static const int maxStopNoticeRepeats = 2;

  Future<String?> _requestInterimReport(
    ProviderConfig provider,
    String apiKey,
    String modelId,
    List<Map<String, dynamic>> history,
    String lastProse,
    int cap,
  ) async {
    final notice = kSubagentRoundCapStopNotice(cap);
    final lastAssistantText = lastProse.trim().isNotEmpty
        ? lastProse.trim()
        : '(mid-work, no prose yet)';
    history
      ..add({'role': 'assistant', 'content': lastAssistantText})
      ..add({'role': 'user', 'content': notice});

    for (var attempt = 0; attempt <= maxStopNoticeRepeats; attempt++) {
      final chunks = <LlmChunk>[];
      LlmError? streamError;
      try {
        final stream = _client.streamChat(
          endpointUrl: provider.endpointUrl,
          config: provider,
          apiKey: apiKey,
          modelId: modelId,
          messages: history,
          thinkingMode: 'enabled',
          tools: _toolsDefinition(), // Same list: cache-friendly.
          userId: 'subagent-$agentName',
          cancelToken: _cancelToken(),
        );
        _sub = stream.listen((chunk) {
          if (chunk.error != null) {
            streamError = chunk.error;
            return;
          }
          chunks.add(chunk);
        }, cancelOnError: true);
        await _sub!.asFuture().catchError((Object e) {});
      } catch (e) {
        streamError = LlmError(
          kind: LlmErrorKind.unknown,
          vendor: LlmVendor.unknown,
          message: '$e',
        );
      }
      _sub = null;
      if (_cancelled || streamError != null) return null;

      final text = _textOf(chunks).trim();
      final calls = ToolExecutor.parseToolUseFromChunks(chunks);

      if (calls.isNotEmpty) {
        // The model defied the ban. Intercept at the system level:
        // answer its tool call with a refusal the wire format
        // understands, then repeat the stop notice verbatim.
        if (attempt == maxStopNoticeRepeats) return null;
        history
          ..add(toolExecutor.formatAssistantToolCallsMessage(
            calls,
            text,
            provider.wireFamily,
          ))
          ..addAll([
            for (final call in calls)
              toolExecutor.formatToolResultForApi(
                call,
                ToolResult.error(
                  'Tool call refused: the run hit its round limit. Do '
                  'NOT call any tool — reply with your interim report '
                  'as plain text.',
                ),
                provider.wireFamily,
              ),
          ])
          ..add({'role': 'user', 'content': notice});
        continue;
      }

      if (text.isNotEmpty) return text;
      // Empty reply with no tool call: ask once more via the loop
      // (consumes an attempt, same as a defying call).
    }
    return null;
  }

  LlmStreamCancelToken? _cancelToken() => null;

  /// Stage-1/2 lightweight compact: replace each tool result's
  /// content with a one-line placeholder (the call line keeps the
  /// tool name + args), halving the history without a model call.
  /// Deliberately lossy — the durable record lives in the report.
  void _compactHistory(List<Map<String, dynamic>> history) {
    for (final message in history) {
      if (message['role'] == 'tool') {
        final content = message['content'];
        if (content is String && content.length > 200) {
          message['content'] =
              '[compacted — ${content.length} chars, read again if needed]';
        }
      }
    }
  }

  /// Stage-3 distill-and-resume (plan §上下文与蒸馏 item 2–3): one
  /// extra LLM call over the full history produces the three
  /// products; the run then continues on a clean
  /// `system + CONTINUATION` context. Products also land in the
  /// roster (knowledge / worklog) via [onDistilled]. Returns the
  /// resume history, or null when the distillation call failed /
  /// produced an unparseable reply.
  Future<List<Map<String, dynamic>>?> _distillAndResume(
    ProviderConfig provider,
    String apiKey,
    String modelId,
    List<Map<String, dynamic>> history,
  ) async {
    final request = SubagentDistiller.buildRequest(
      agentName: agentName,
      domain: profile.domain,
      intention: intention,
      history: history,
    );
    final reply = await _oneShot(
      provider,
      apiKey,
      modelId,
      request,
      tools: null,
    );
    if (reply == null) return null;
    final products = SubagentDistiller.parse(reply);
    if (!products.isValid) return null;

    if (onDistilled != null) {
      try {
        await onDistilled!(agentName, products);
      } catch (_) {
        // Roster write is best-effort: the resume must proceed even
        // if persistence hiccups.
      }
    }

    return buildResumeHistory(
      systemPrompt: subagentSystemPrompt(
        agentName: agentName,
        role: role,
        domain: profile.domain,
        knowledge: products.knowledge,
        worklog: products.worklog,
        intention: intention,
        userLanguage: userLanguage,
      ),
      products: products,
    );
  }

  /// Single non-streaming-equivalent call: stream without tools and
  /// collect the text. Shared by the distillation pass.
  Future<String?> _oneShot(
    ProviderConfig provider,
    String apiKey,
    String modelId,
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
  }) async {
    final chunks = <LlmChunk>[];
    try {
      final stream = _client.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: messages,
        thinkingMode: 'disabled',
        tools: tools,
        userId: 'subagent-distill-$agentName',
        cancelToken: _cancelToken(),
      );
      await for (final chunk in stream) {
        if (chunk.error != null) return null;
        chunks.add(chunk);
      }
    } catch (_) {
      return null;
    }
    final text = _textOf(chunks);
    return text.isEmpty ? null : text;
  }

  (ProviderConfig, String, String)? _resolveModel() {
    final model = profile.model;
    final slash = model.indexOf('/');
    if (slash <= 0) return null;
    final providerName = model.substring(0, slash);
    final modelId = model.substring(slash + 1);
    final provider = providerService.providerByName(providerName);
    if (provider == null) return null;
    final apiKey = providerService.getApiKey(providerName);
    if (apiKey == null || apiKey.isEmpty) return null;
    return (provider, apiKey, modelId);
  }

  static String _textOf(List<LlmChunk> chunks) {
    final buffer = StringBuffer();
    for (final chunk in chunks) {
      if (chunk.textDelta != null) buffer.write(chunk.textDelta);
    }
    return buffer.toString();
  }

  void _finish(String status, String report) {
    if (_finished) return;
    _finished = true;
    _client.dispose();
    onDone(status, report.trim());
  }
}

/// Live progress of one run, surfaced by check_agent and chips.
class SubagentRunStatus {
  final String agentName;
  final int round;
  final String? lastTool;

  /// `starting` / `running` / `done` / `cancelled`.
  final String status;

  const SubagentRunStatus({
    required this.agentName,
    required this.round,
    required this.lastTool,
    required this.status,
  });
}

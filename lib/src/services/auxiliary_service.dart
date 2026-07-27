import 'dart:async';

import '../models/provider_config.dart';
import '../storage/message_store.dart';
import '../tools/shell_monitor.dart';
import '../tools/shell_risk.dart';
import 'auxiliary_prompts.dart';
import 'auxiliary_task_tracker.dart';
import 'llm_client.dart';
import 'llm_error.dart';
import 'provider_service.dart';

/// Lightweight LLM calls that use the auxiliary model (title generation,
/// TLDR summarization). Runs on a single long-lived [LlmClient] instead
/// of creating and disposing one per call — avoids the overhead of a
/// fresh `HttpClient` per auxiliary request.
class AuxiliaryService {
  final ProviderService _providerService;
  final MessageStore _messageStore;
  final LlmClient _client = LlmClient();

  AuxiliaryService(this._providerService, this._messageStore);

  /// Resolve the auxiliary model's provider, api key, and model id.
  /// Returns null if no auxiliary model is configured or if the
  /// provider/key is missing.
  _AuxModel? _resolve() {
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return null;

    final slashIndex = auxKey.indexOf('/');
    final providerName =
        slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final modelId =
        slashIndex > 0 ? auxKey.substring(slashIndex + 1) : auxKey;

    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) return null;

    return _AuxModel(
      provider: provider,
      apiKey: apiKey,
      modelId: modelId,
    );
  }

  /// Stream a single-shot auxiliary call (no tools, no thinking).
  /// Collects the full text response and returns it, or null on
  /// error / empty / too long.
  ///
  /// By default builds a two-message `[system, user]` exchange
  /// from [systemPrompt] + [userMessage]. When [messages] is
  /// provided it is used verbatim instead — callers that need a
  /// richer conversation shape (e.g. TLDR, which passes the
  /// user question + assistant response as a Q→A pair) pass
  /// the full list and we skip the default builder. In that
  /// mode [systemPrompt] is unused.
  ///
  /// [cancelToken] lets the caller abort the underlying HTTP stream
  /// (e.g. on a caller-side timeout). Cancellation surfaces here as
  /// a stream error or truncated body, which this method reports as
  /// `null` — callers cannot distinguish "cancelled" from "failed".
  Future<String?> _streamAuxiliaryCall({
    required String systemPrompt,
    String? userMessage,
    List<Map<String, dynamic>>? messages,
    required String logTag,
    int? maxLength,
    LlmStreamCancelToken? cancelToken,
  }) async {
    final aux = _resolve();
    if (aux == null) return null;

    final effectiveMessages = messages ??
        <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          if (userMessage != null && userMessage.isNotEmpty)
            <String, dynamic>{'role': 'user', 'content': userMessage},
        ];

    try {
      final stream = _client.streamChat(
        endpointUrl: aux.provider.endpointUrl,
        config: aux.provider,
        apiKey: aux.apiKey,
        modelId: aux.modelId,
        messages: effectiveMessages,
        thinkingMode: 'disabled',
        reasoningEffort: null,
        cancelToken: cancelToken,
      );

      final buffer = StringBuffer();
      LlmError? streamError;
      await for (final chunk in stream) {
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        if (chunk.textDelta != null) buffer.write(chunk.textDelta);
      }
      if (streamError != null) {
        // Auxiliary calls are background work (title generation, TLDR)
        // — we don't surface errors as a persistent bubble, only log
        // the structured error so debugging has the kind/code/context.
        print('[$logTag] ${streamError.kind.name}'
            '${streamError.vendorCode != null ? "(${streamError.vendorCode})" : ""}'
            ': ${streamError.toUserMessage()}');
        return null;
      }
      final result = buffer.toString().trim();
      if (result.isEmpty) return null;
      if (maxLength != null && result.length > maxLength) return null;
      return result;
    } catch (e) {
      print('[$logTag] generation failed: $e');
      return null;
    }
  }

  Future<String?> generateTitle(
    int sessionId, {
    String? userContent,
  }) async {
    final lease = AuxiliaryTaskTracker.instance.start(AuxiliaryTaskKind.title);
    try {
      return await _generateTitle(sessionId, userContent: userContent);
    } finally {
      lease.end();
    }
  }

  Future<String?> _generateTitle(
    int sessionId, {
    String? userContent,
  }) async {
    // Use the provided userContent directly when available (e.g. when
    // generating the title early, before the message has been persisted).
    // Otherwise fall back to reading from the store.
    String userText;
    if (userContent != null && userContent.trim().isNotEmpty) {
      userText = userContent;
    } else {
      final messages = await _messageStore.getMessages(sessionId);
      final userMessage = messages.firstWhere(
        (m) => m.role == 'user',
        orElse: () => messages.first,
      );
      if (userMessage.content.trim().isEmpty) return null;
      userText = userMessage.content;
    }

    final title = await _streamAuxiliaryCall(
      systemPrompt: titleSystemPrompt,
      userMessage: userText,
      logTag: 'auxiliary',
      maxLength: 80,
    );
    if (title == null) return null;
    // Collapse newlines into spaces for single-line display.
    final collapsed = title.replaceAll(RegExp(r'[\r\n]+'), ' ');
    print('[auxiliary] generated title: $collapsed');
    return collapsed;
  }

  Future<String?> generateTldr(
    String responseContent, {
    String? userQuestion,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    final lease = AuxiliaryTaskTracker.instance.start(AuxiliaryTaskKind.tldr);
    try {
      return await _generateTldr(
        responseContent,
        userQuestion: userQuestion,
        detail: detail,
      );
    } finally {
      lease.end();
    }
  }

  Future<String?> _generateTldr(
    String responseContent, {
    String? userQuestion,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    // Build a tiny Q→A exchange so the auxiliary model has the
    // user's question in its context window. This lets it (a)
    // prioritize the parts of the long response that actually
    // answer what was asked and (b) anchor the language of the
    // summary to the user's question (see the system prompt).
    // Falls back to the historical single-user-message layout
    // when no question is supplied (e.g. summarising a synthetic
    // AI bubble).
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content': tldrSystemPromptFor(detail),
      },
      if (userQuestion != null && userQuestion.trim().isNotEmpty)
        <String, dynamic>{'role': 'user', 'content': userQuestion},
      <String, dynamic>{'role': 'assistant', 'content': responseContent},
    ];
    final tldr = await _streamAuxiliaryCall(
      systemPrompt: tldrSystemPromptFor(detail),
      messages: messages,
      logTag: 'tldr',
    );
    if (tldr == null) return null;
    print('[tldr] generated: ${tldr.length} chars');
    return tldr;
  }

  /// Assess the risk of a shell command the agent is about to run
  /// (layer 2 of the shell high-risk guardrail — see
  /// `shell_risk.dart` for the shared contract and
  /// [shellRiskSystemPrompt] for the model's instructions).
  ///
  /// Verdict mapping:
  ///
  ///   * No auxiliary model configured →
  ///     [ShellRiskVerdictKind.unavailable]. The caller (shell_base)
  ///     deliberately fails OPEN on `unavailable` — the command runs
  ///     with a warning appended — because an unconfigured or
  ///     unreachable reviewer must not silently block work it cannot
  ///     judge. The fail-closed side of the policy applies to the
  ///     model's own output instead: a reply that doesn't follow the
  ///     SAFE / UNSAFE / UNCERTAIN contract parses as `uncertain`
  ///     and is rejected.
  ///   * Timeout / transport error / empty response → `unavailable`.
  ///     The default 10s [timeout] is far below the 120s LLM
  ///     watchdog: this check sits on the pre-execution path, so a
  ///     slow auxiliary model must not stall the shell tool.
  ///   * Model output that doesn't follow the SAFE / UNSAFE /
  ///     UNCERTAIN contract → `uncertain` (fail-closed).
  Future<ShellRiskVerdict> assessShellCommand({
    required String command,
    required String intent,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final lease =
        AuxiliaryTaskTracker.instance.start(AuxiliaryTaskKind.shellRisk);
    try {
      return await _assessShellCommand(
        command: command,
        intent: intent,
        timeout: timeout,
      );
    } finally {
      lease.end();
    }
  }

  Future<ShellRiskVerdict> _assessShellCommand({
    required String command,
    required String intent,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_resolve() == null) {
      return const ShellRiskVerdict(ShellRiskVerdictKind.unavailable);
    }

    // The working directory is intentionally not included — this
    // method's callers don't always have one, and the system prompt
    // teaches the model to judge scope from the command itself.
    final userMessage = 'Command: $command\nIntent: $intent';

    // Enforce the timeout by cancelling the underlying HTTP stream,
    // not just abandoning the future — the LlmClient is long-lived
    // and shared, so a leaked stream would hold a connection open.
    final cancelToken = LlmStreamCancelToken();
    final timer = Timer(timeout, () {
      unawaited(cancelToken.cancelActiveStream(
        reason: 'shell-risk assessment timed out after $timeout',
      ));
    });

    String? raw;
    try {
      raw = await _streamAuxiliaryCall(
        systemPrompt: shellRiskSystemPrompt,
        userMessage: userMessage,
        logTag: 'shell-risk',
        cancelToken: cancelToken,
      );
    } finally {
      timer.cancel();
    }

    // Timeout, transport error, and empty responses all surface as
    // null from _streamAuxiliaryCall — the assessment is unavailable.
    if (raw == null) {
      return const ShellRiskVerdict(ShellRiskVerdictKind.unavailable);
    }
    return _parseShellRiskVerdict(raw);
  }

  /// Ask the auxiliary model to judge one monitor check for a
  /// running shell process (the runtime counterpart to
  /// [assessShellCommand], which judges a command before it runs).
  ///
  /// [messages] is the FULL continuing conversation: the system
  /// prompt plus the static first user turn (command / intent /
  /// platform) plus the running history of prior snapshot turns and
  /// assistant verdicts, ending in the new snapshot turn. The
  /// monitor loop in `shell_base.dart` owns this list across checks
  /// and appends to it, so the model sees its own prior verdicts
  /// and can reason about rate of progress — and the long static
  /// prefix stays byte-identical, which providers with prefix
  /// caching reuse as KV cache. This method is transport-only: it
  /// streams the reply and parses the verdict, holding no
  /// per-process state.
  ///
  /// Verdict mapping:
  ///
  ///   * No auxiliary model configured / timeout / transport error /
  ///     empty response → [ShellMonitorVerdictKind.uncertain]. The
  ///     monitor is fail-OPEN: an unavailable reviewer must not kill
  ///     a running process (a false kill discards real work), so
  ///     every failure path degrades to "keep running". The monitor
  ///     loop additionally treats a null/uncertain streak as the
  ///     signal to arm the static-timeout fallback.
  ///   * Output that doesn't follow the PROGRESS / STUCK /
  ///     UNCERTAIN contract → `uncertain` (fail-open), mirroring how
  ///     `_parseShellRiskVerdict` maps unparseable output to its own
  ///     safe default.
  ///
  /// The default 10s [timeout] keeps a slow auxiliary model from
  /// stalling the monitor loop; it cancels the underlying HTTP
  /// stream rather than just abandoning the future because the
  /// [LlmClient] is long-lived and shared.
  Future<ShellMonitorVerdict> assessShellProgress({
    required List<Map<String, dynamic>> messages,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final lease =
        AuxiliaryTaskTracker.instance.start(AuxiliaryTaskKind.shellMonitor);
    try {
      return await _assessShellProgress(messages: messages, timeout: timeout);
    } finally {
      lease.end();
    }
  }

  Future<ShellMonitorVerdict> _assessShellProgress({
    required List<Map<String, dynamic>> messages,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_resolve() == null) {
      return const ShellMonitorVerdict(ShellMonitorVerdictKind.uncertain);
    }

    final cancelToken = LlmStreamCancelToken();
    final timer = Timer(timeout, () {
      unawaited(cancelToken.cancelActiveStream(
        reason: 'shell-monitor check timed out after $timeout',
      ));
    });

    String? raw;
    try {
      raw = await _streamAuxiliaryCall(
        // systemPrompt is unused when `messages` is provided
        // verbatim — the monitor loop already placed the monitor
        // system prompt at the head of the conversation.
        systemPrompt: '',
        messages: messages,
        logTag: 'shell-monitor',
        cancelToken: cancelToken,
      );
    } finally {
      timer.cancel();
    }

    // Timeout, transport error, and empty responses all surface as
    // null — fail open to `uncertain` (keep running).
    if (raw == null) {
      return const ShellMonitorVerdict(ShellMonitorVerdictKind.uncertain);
    }
    return _parseShellMonitorVerdict(raw);
  }

  void dispose() {
    _client.dispose();
  }
}

class _AuxModel {
  final ProviderConfig provider;
  final String apiKey;
  final String modelId;
  const _AuxModel({
    required this.provider,
    required this.apiKey,
    required this.modelId,
  });
}

/// Parse the auxiliary model's raw reply for [assessShellCommand]
/// into a verdict. Kept pure and private so the parsing rules are
/// unit-testable without any network access (tests go through
/// [parseShellRiskVerdictForTesting]).
///
/// Contract (see [shellRiskSystemPrompt]): the model is asked for
/// a single verdict word — SAFE / UNSAFE / UNCERTAIN. Anything
/// beyond it — a same-line separator or trailing lines — is
/// tolerated and treated as an optional reason, so a chatty model
/// degrades gracefully instead of breaking the parse.
///
/// Tolerates case (`safe`, `Unsafe`) and trailing punctuation
/// (`SAFE.`, `unsafe:`). Anything that doesn't start with a
/// recognizable verdict token — empty input, prose, a different
/// token — maps to [ShellRiskVerdictKind.uncertain], the fail-
/// closed default: a model that can't follow the contract is
/// treated as "cannot confirm safe", never as "safe".
ShellRiskVerdict _parseShellRiskVerdict(String raw) {
  const unparsable = ShellRiskVerdict(ShellRiskVerdictKind.uncertain);

  final trimmed = raw.trim();
  if (trimmed.isEmpty) return unparsable;

  final lines = trimmed.split(RegExp(r'\r\n|\r|\n'));
  final firstLine = lines.first.trim();
  final tokenMatch = RegExp(r'^[A-Za-z]+').firstMatch(firstLine);
  if (tokenMatch == null) return unparsable;

  final kind = switch (tokenMatch.group(0)!.toUpperCase()) {
    'SAFE' => ShellRiskVerdictKind.safe,
    'UNSAFE' => ShellRiskVerdictKind.unsafe,
    'UNCERTAIN' => ShellRiskVerdictKind.uncertain,
    // e.g. "SAFELY ..." — the token is longer than the keyword,
    // so the line doesn't follow the contract.
    _ => null,
  };
  if (kind == null) return unparsable;

  // Reason: whatever trails the token on the first line (after
  // stripping the separator) plus any subsequent lines.
  final remainder = firstLine
      .substring(tokenMatch.end)
      .replaceAll(RegExp(r'^[\s:：;；,，.\-—]+'), '');
  final reason = <String>[remainder, ...lines.skip(1)]
      .join('\n')
      .trim();
  return ShellRiskVerdict(kind, reason.isEmpty ? null : reason);
}

/// Test-only access to [_parseShellRiskVerdict] (visible for
/// testing — the meta package isn't a direct dependency of this
/// package, so the marker is documentation rather than the
/// annotation). Production code must call
/// [AuxiliaryService.assessShellCommand] instead.
ShellRiskVerdict parseShellRiskVerdictForTesting(String raw) =>
    _parseShellRiskVerdict(raw);

/// Parse the auxiliary model's raw reply for [assessShellProgress]
/// into a verdict. Same tolerant style as [_parseShellRiskVerdict]:
/// the contract (see [shellMonitorSystemPrompt]) is a verdict word
/// first — PROGRESS / STUCK / UNCERTAIN — optionally followed by a
/// number of seconds until the next check and a free-text reason.
///
/// Tolerates case (`progress`, `Stuck`) and trailing punctuation
/// (`PROGRESS.`, `stuck:`). The interval is extracted from anywhere
/// on the first line, clamped to
/// [kMonitorMinIntervalSeconds]–[kMonitorMaxIntervalSeconds], and
/// defaults to [kMonitorDefaultIntervalSeconds] when absent or
/// unparseable — a model that omits it just gets the standard 30s
/// cadence. Anything whose first token isn't a recognizable verdict
/// maps to [ShellMonitorVerdictKind.uncertain], the fail-open
/// default: a model that can't follow the contract is treated as
/// "cannot confirm", never as "stuck" — fail-open at runtime means
/// keep running, never kill on a parse failure.
ShellMonitorVerdict _parseShellMonitorVerdict(String raw) {
  const unparsable = ShellMonitorVerdict(ShellMonitorVerdictKind.uncertain);

  final trimmed = raw.trim();
  if (trimmed.isEmpty) return unparsable;

  final lines = trimmed.split(RegExp(r'\r\n|\r|\n'));
  final firstLine = lines.first.trim();
  final tokenMatch = RegExp(r'^[A-Za-z]+').firstMatch(firstLine);
  if (tokenMatch == null) return unparsable;

  final kind = switch (tokenMatch.group(0)!.toUpperCase()) {
    'PROGRESS' => ShellMonitorVerdictKind.progress,
    'STUCK' => ShellMonitorVerdictKind.stuck,
    'UNCERTAIN' => ShellMonitorVerdictKind.uncertain,
    _ => null,
  };
  if (kind == null) return unparsable;

  // Interval: the first integer on the first line, clamped to the
  // agreed bounds. Searched after the verdict token so a number in
  // the reason text (e.g. "900 crates") isn't mistaken for it — but
  // only the FIRST integer, so "PROGRESS 60 — 900 crates" still
  // parses as 60s.
  int intervalSeconds = kMonitorDefaultIntervalSeconds;
  final afterToken = firstLine.substring(tokenMatch.end);
  final intMatch = RegExp(r'\d+').firstMatch(afterToken);
  if (intMatch != null) {
    final parsed = int.tryParse(intMatch.group(0)!);
    if (parsed != null) {
      intervalSeconds = parsed.clamp(
        kMonitorMinIntervalSeconds,
        kMonitorMaxIntervalSeconds,
      );
    }
  }

  // Reason: whatever trails the token (and the interval) on the
  // first line, plus any subsequent lines. Reuses the risk verdict's
  // separator-stripping so "PROGRESS 60 — on track" yields "on
  // track". The interval digits are removed from the reason text.
  final remainder = afterToken
      .replaceFirst(RegExp(r'\d+'), '')
      .replaceAll(RegExp(r'^[\s:：;；,，.\-—]+'), '');
  final reason = <String>[remainder, ...lines.skip(1)].join('\n').trim();

  return ShellMonitorVerdict(
    kind,
    intervalSeconds: intervalSeconds,
    reason: reason.isEmpty ? null : reason,
  );
}

/// Test-only access to [_parseShellMonitorVerdict], same pattern as
/// [parseShellRiskVerdictForTesting].
ShellMonitorVerdict parseShellMonitorVerdictForTesting(String raw) =>
    _parseShellMonitorVerdict(raw);

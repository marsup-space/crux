import 'dart:async';

import '../models/provider_config.dart';
import '../storage/message_store.dart';
import '../tools/shell_risk.dart';
import 'auxiliary_prompts.dart';
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

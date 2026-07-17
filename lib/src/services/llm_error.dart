// ignore_for_file: prefer_const_constructors
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Unified taxonomy of LLM error conditions, regardless of vendor.
///
/// Funnels all three upstream error schemas (Anthropic HTTP+type,
/// OpenAI HTTP+code, MiniMax numeric base_resp.status_code) into a
/// single enum so the rest of Crux — toasts, persisted error
/// bubbles, retry buttons, tests — can switch on one symbol.
///
/// New variants are appended, never inserted or reordered: the index
/// is serialised into the persisted error JSON (see
/// [LlmError.toJson]).
enum LlmErrorKind {
  /// 401 / `authentication_error` / MiniMax 1004, 2049.
  /// Invalid or missing API key. NOT retriable — user must fix the
  /// key in the provider config.
  auth,

  /// 403 / `permission_error` / MiniMax 2042. Key valid but lacks
  /// scope, or the request came from a disallowed region.
  permission,

  /// 402 / `billing_error` / MiniMax 1008. Account has a payment
  /// or plan problem. NOT retriable.
  billing,

  /// 429 quota variant / MiniMax 2056 (5h-window usage cap).
  /// Distinct from `rateLimit`: the user has run out of credits,
  /// not just hit a RPM/TPM ceiling. NOT retriable.
  quota,

  /// 429 / `rate_limit_error` / MiniMax 1002, 2045. RPM or TPM
  /// ceiling hit. Retriable — slow down and try again.
  rateLimit,

  /// 400 / `invalid_request_error` / MiniMax 2013, 1042.
  /// Malformed payload, bad parameter, wrong model name. NOT
  /// retriable — code must change.
  invalidRequest,

  /// MiniMax 1026 (input sensitive) / 1027 (output sensitive).
  /// Anthropic and OpenAI surface content refusals via
  /// `stop_reason: "refusal"` inside a normal 200 response, not as
  /// HTTP errors — those paths are handled separately in
  /// `chat_service.dart` and never reach this enum.
  contentPolicy,

  /// 413 / `request_too_large` / MiniMax 1039 /
  /// OpenAI `context_length_exceeded`. Input exceeded the model's
  /// context window. NOT retriable — user must /compact.
  contextLength,

  /// 529 / `overloaded_error` (also mid-stream after a 200) /
  /// MiniMax 1041 / OpenAI 503 overloaded. Retriable — try again.
  overloaded,

  /// 500 / `api_error` / MiniMax 1000, 1024, 1033 / OpenAI 500.
  /// Upstream had an internal failure. Retriable.
  serverError,

  /// 504 / `timeout_error` / MiniMax 1001 / OpenAI
  /// `APITimeoutError`. Retriable.
  timeout,

  /// 404 / `not_found_error` / OpenAI 404. Endpoint or model name
  /// doesn't exist. NOT retriable.
  notFound,

  /// 409 / OpenAI ConflictError / MiniMax 2039 (voice clone dup).
  /// Resource conflict. NOT retriable.
  conflict,

  /// Socket / TLS / DNS / proxy unreachable. Thrown as a
  /// `SocketException`, `HandshakeException`, or `HttpException`
  /// and classified by [classifyThrownError]. Retriable.
  network,

  /// User or guard cancelled mid-stream. Distinct from [timeout]
  /// because the upstream didn't fail — we walked away. Never
  /// retriable implicitly; user must explicitly re-submit.
  cancelled,

  /// Could not classify into any of the above. Default value when
  /// the upstream body is empty, unparseable, or in an
  /// unrecognised shape. NOT retriable.
  unknown,
}

extension LlmErrorKindX on LlmErrorKind {
  /// `true` when the same request could plausibly succeed on a
  /// retry without user intervention. Drives whether the persisted
  /// error bubble shows the "Retry (/continue)" button.
  ///
  /// Conservative: only clearly-transient categories are flagged.
  /// Auth, billing, quota, content policy, invalid request,
  /// not-found, conflict, cancelled, and unknown are *not*
  /// retriable — retrying with the same payload is either useless
  /// or actively misleading.
  bool get isRetriable => switch (this) {
    LlmErrorKind.rateLimit ||
    LlmErrorKind.overloaded ||
    LlmErrorKind.serverError ||
    LlmErrorKind.timeout ||
    LlmErrorKind.network => true,
    LlmErrorKind.auth ||
    LlmErrorKind.permission ||
    LlmErrorKind.billing ||
    LlmErrorKind.quota ||
    LlmErrorKind.invalidRequest ||
    LlmErrorKind.contentPolicy ||
    LlmErrorKind.contextLength ||
    LlmErrorKind.notFound ||
    LlmErrorKind.conflict ||
    LlmErrorKind.cancelled ||
    LlmErrorKind.unknown => false,
  };

  /// Short, capitalised label for UI / logs. Kept singular so it
  /// reads naturally in a sentence ("Rate limited — …").
  String get displayLabel => switch (this) {
    LlmErrorKind.auth => 'Authentication error',
    LlmErrorKind.permission => 'Permission error',
    LlmErrorKind.billing => 'Billing error',
    LlmErrorKind.quota => 'Quota exceeded',
    LlmErrorKind.rateLimit => 'Rate limited',
    LlmErrorKind.invalidRequest => 'Invalid request',
    LlmErrorKind.contentPolicy => 'Content policy',
    LlmErrorKind.contextLength => 'Context too long',
    LlmErrorKind.overloaded => 'Upstream overloaded',
    LlmErrorKind.serverError => 'Upstream server error',
    LlmErrorKind.timeout => 'Timed out',
    LlmErrorKind.notFound => 'Not found',
    LlmErrorKind.conflict => 'Conflict',
    LlmErrorKind.network => 'Network error',
    LlmErrorKind.cancelled => 'Cancelled',
    LlmErrorKind.unknown => 'Unknown error',
  };
}

/// Which vendor produced the error. Affects how the vendor-specific
/// code in [LlmError.vendorCode] is interpreted by humans (MiniMax
/// 1002 → "rate limit"; OpenAI "slow_down" → "throttled").
enum LlmVendor { anthropic, openai, minimax, kimi, unknown }

extension LlmVendorX on LlmVendor {
  /// Display label for the vendor — used in `toUserMessage` so the
  /// hint ("check your Anthropic key") reads naturally.
  String get displayLabel => switch (this) {
    LlmVendor.anthropic => 'Anthropic',
    LlmVendor.openai => 'OpenAI',
    LlmVendor.minimax => 'MiniMax',
    LlmVendor.kimi => 'Kimi',
    LlmVendor.unknown => 'the upstream',
  };

  static LlmVendor fromProviderName(String name) {
    switch (name) {
      case 'anthropic':
      case 'anthropic_compatible':
        return LlmVendor.anthropic;
      case 'openai':
      case 'openai_compatible':
      case 'deepseek':
        return LlmVendor.openai;
      case 'minimax':
        return LlmVendor.minimax;
      case 'kimi':
        return LlmVendor.kimi;
      default:
        return LlmVendor.unknown;
    }
  }
}

/// A structured representation of an LLM-streaming error.
///
/// Produced by the parser functions in this file (or constructed
/// directly for throw-classified errors). Carries the unified
/// [kind] for UX policy, the vendor-specific [statusCode] /
/// [vendorCode] for debugging, the upstream [message] verbatim,
/// and the Anthropic [requestId] when available (useful for
/// support tickets).
///
/// [toUserMessage] flattens this into a single short sentence
/// suitable for a toast or a persisted error bubble.
class LlmError {
  /// Unified taxonomy entry — what UI/UX policy applies.
  final LlmErrorKind kind;

  /// Which vendor produced the error. `unknown` when classification
  /// didn't reach a vendor (e.g. an unparseable thrown exception).
  final LlmVendor vendor;

  /// HTTP status from the upstream response. `null` for:
  ///   - thrown exceptions (network / timeout / cancel);
  ///   - mid-stream SSE errors that arrived after a 200 response
  ///     (e.g. Anthropic's `overloaded_error` mid-stream event).
  final int? statusCode;

  /// Vendor-specific identifier:
  ///   - Anthropic: the `error.type` value (e.g. `overloaded_error`).
  ///   - OpenAI: the `error.code` or `error.type` value
  ///     (e.g. `slow_down`, `context_length_exceeded`).
  ///   - MiniMax: the numeric `base_resp.status_code`
  ///     (e.g. `1002`, `1008`).
  /// `null` when no identifier is available.
  final String? vendorCode;

  /// Upstream-provided error message, exactly as the vendor sent
  /// it. Always non-null (may be empty string for `null` upstream
  /// payloads).
  final String message;

  /// Anthropic `request-id` header, if the response carried one.
  /// Useful for support tickets. `null` for non-Anthropic or when
  /// the header wasn't captured.
  final String? requestId;

  /// Underlying exception when [kind] is `network`, `timeout`, or
  /// `cancelled`. Kept on the structured object so tests can
  /// assert exact class and so logs can dump the full chain.
  final Object? cause;

  /// Provider name from `ProviderConfig.name` (e.g. `minimax`,
  /// `openai`). Empty string when constructed without provider
  /// context (e.g. inside the auxiliary service before the
  /// provider name has been threaded through).
  final String providerName;

  const LlmError({
    required this.kind,
    required this.vendor,
    required this.message,
    this.statusCode,
    this.vendorCode,
    this.requestId,
    this.cause,
    this.providerName = '',
  });

  /// `true` when the same request could plausibly succeed on a
  /// retry without user intervention. Convenience passthrough to
  /// [LlmErrorKindX.isRetriable].
  bool get isRetriable => kind.isRetriable;

  @override
  String toString() =>
      'LlmError(kind=${kind.name}, vendor=${vendor.name}, '
      'status=$statusCode, code=$vendorCode, msg="$message")';

  /// Short, user-friendly message suitable for a toast or a
  /// persisted error bubble body. Vendor-aware — references the
  /// vendor by display name and includes a concrete actionable
  /// hint where one applies (e.g. "check your API key" for auth,
  /// "/compact or shorten the conversation" for context-length).
  ///
  /// Always single-sentence. Never includes the raw vendor code
  /// (that's debugging detail; persisted separately in the JSON
  /// payload so a future "view details" affordance can show it).
  String toUserMessage() {
    final hint = _hintForKind();
    final prefix = providerName.isEmpty ? '' : '[$providerName] ';
    if (hint == null) {
      // No actionable hint for this kind — fall back to the raw
      // upstream message, prefixed with the provider name.
      return message.isEmpty
          ? '$prefix${kind.displayLabel}.'
          : '$prefix$message';
    }
    return '$prefix$hint';
  }

  String? _hintForKind() {
    switch (kind) {
      case LlmErrorKind.auth:
        return 'Invalid or missing API key — check your ${vendor.displayLabel} '
            'key in the provider config.';
      case LlmErrorKind.permission:
        return 'Your API key does not have permission for this request.';
      case LlmErrorKind.billing:
        return 'Account has a billing issue — check your ${vendor.displayLabel} '
            'plan / billing page.';
      case LlmErrorKind.quota:
        return 'Quota exceeded — wait for the window to reset or upgrade '
            'your ${vendor.displayLabel} plan.';
      case LlmErrorKind.rateLimit:
        return 'Rate limited — slow down or wait a moment, then retry.';
      case LlmErrorKind.invalidRequest:
        return message.isEmpty
            ? 'The request was malformed.'
            : 'The request was malformed: $message';
      case LlmErrorKind.contentPolicy:
        return 'The request tripped the ${vendor.displayLabel} content '
            'policy${message.isEmpty ? "." : ": $message"}';
      case LlmErrorKind.contextLength:
        return 'Context too long — /compact or shorten the conversation.';
      case LlmErrorKind.overloaded:
        return '${vendor.displayLabel} is temporarily overloaded — '
            'retry in a moment.';
      case LlmErrorKind.serverError:
        return '${vendor.displayLabel} had an internal error — '
            'retry in a moment.';
      case LlmErrorKind.timeout:
        return 'Request timed out — retry or shorten the input.';
      case LlmErrorKind.notFound:
        return message.isEmpty
            ? 'Resource not found.'
            : 'Resource not found: $message';
      case LlmErrorKind.conflict:
        return message.isEmpty ? 'Conflict.' : 'Conflict: $message';
      case LlmErrorKind.network:
        return message.isEmpty ? 'Network error.' : 'Network error: $message';
      case LlmErrorKind.cancelled:
        return 'Cancelled.';
      case LlmErrorKind.unknown:
        return message.isEmpty ? 'An unknown error occurred.' : message;
    }
  }

  /// `true` when this error indicates that the upstream API
  /// rejected the request because a `tool_result` referenced a
  /// `tool_use_id` that doesn't appear in a preceding assistant
  /// `tool_use` — the canonical orphan-tool-history symptom on
  /// Anthropic-style wire families.
  ///
  /// Triggers an auto-repair-and-retry hook in the chat executor
  /// (gated to providers whose wire family is Anthropic-compatible
  /// via [LlmProvider.supportsOrphanToolRepair]). The check is
  /// intentionally narrow so unrelated `invalid_request_error`
  /// shapes (malformed JSON, schema failures, bad parameter
  /// names) don't accidentally trigger a session-wide repair.
  ///
  /// Returning `true` does NOT mean we'll actually repair — the
  /// executor additionally gates on the provider's wire family
  /// and on a one-shot per-round flag. This getter just classifies
  /// the *error shape*.
  bool get isOrphanToolUseError {
    if (kind != LlmErrorKind.invalidRequest) return false;
    if (vendor != LlmVendor.anthropic && vendor != LlmVendor.minimax) {
      return false;
    }
    // MiniMax encodes the orphan-tool case as
    // `base_resp.status_code == 2013` with a fixed message shape
    // — unambiguous when the code matches.
    if (vendor == LlmVendor.minimax && vendorCode == '2013') return true;
    // Anthropic and other variants: match the technical terms
    // that the upstream embeds in the error message. These are
    // the wire-format keys Anthropic's parser puts verbatim in
    // the message body (e.g. `"messages.N: tool_use ids were not
    // found in tool_result blocks"`, or the prose form
    // `"tool result for tool use call_x was not found"`),
    // so a substring match on a few exact phrasings is robust.
    final m = message.toLowerCase();
    return m.contains('tool_result') || // wire-format key
        m.contains('tool_result ') || // prose form (post-key)
        m.contains('tool use ') || // prose form (pre-id / post-id)
        m.contains('tool_use_id') || // wire-format key (other vendors)
        m.contains('tool use id'); // prose form
  }

  /// JSON encode for storage in the `messages.error` column.
  /// Round-trips through [LlmErrorCodec.fromJson].
  ///
  /// `cause` is intentionally NOT serialised — exceptions don't
  /// round-trip cleanly through JSON, and the structured fields
  /// carry enough information for the persisted bubble.
  Map<String, dynamic> toJsonMap() => {
    'kind': kind.name,
    'vendor': vendor.name,
    if (statusCode != null) 'statusCode': statusCode,
    if (vendorCode != null) 'vendorCode': vendorCode,
    'message': message,
    if (requestId != null) 'requestId': requestId,
    'providerName': providerName,
  };

  String toJson() => jsonEncode(toJsonMap());
}

/// Parsers that convert vendor-shaped payloads into [LlmError].
///
/// Each function is intentionally narrow: a single payload shape,
/// no auto-detection — the caller (LlmClient) picks the right one
/// based on the wire family and which layer the error came from
/// (HTTP body vs SSE event vs thrown exception). This keeps the
/// branches explicit and unit-testable.

/// Parse a non-200 HTTP error response body. Tries each known
/// shape in order:
///   1. MiniMax `{base_resp: {status_code, status_msg}, ...}` —
///      used on MiniMax's Anthropic-compatible endpoint even
///      though the rest of the wire format is Anthropic-shaped.
///   2. OpenAI `{error: {message, type, code, param}}`.
///   3. Anthropic `{type: "error", error: {type, message}}`.
///   4. Generic `{message: "..."}` fallback.
///
/// Returns a fresh [LlmError]. [body] may be empty (yields a
/// fallback with the status code as the message).
LlmError parseHttpError({
  required int statusCode,
  required String body,
  required LlmVendor vendor,
  String providerName = '',
  String? requestId,
}) {
  final json = _tryParseJsonObject(body);

  if (json != null) {
    // 1. MiniMax base_resp — check first because on MiniMax's
    // Anthropic-compatible endpoint, the body shape is MiniMax's
    // own (not Anthropic's) even though the rest of the request
    // used the Anthropic wire.
    final baseResp = json['base_resp'];
    if (baseResp is Map) {
      final rawCode = baseResp['status_code'];
      final rawMsg = baseResp['status_msg'];
      if (rawCode is int || rawCode is String) {
        return _fromMiniMax(
          code: rawCode.toString(),
          msg: rawMsg is String ? rawMsg : (json['message'] as String? ?? ''),
          statusCode: statusCode,
          providerName: providerName,
        );
      }
    }

    // 2. Anthropic {type: "error", error: {type, message}} —
    // check BEFORE the OpenAI branch because both vendors use a
    // top-level `error` map and we need Anthropic's stronger
    // `type: "error"` discriminator to avoid misclassifying
    // Anthropic bodies as OpenAI. The order matters.
    if (json['type'] == 'error' && json['error'] is Map) {
      final inner = json['error'] as Map;
      return _fromAnthropic(
        errorType: inner['type'] as String?,
        message: inner['message'] as String?,
        statusCode: statusCode,
        providerName: providerName,
        requestId: requestId,
      );
    }

    // 3. OpenAI {error: {message, type, code, param}}.
    final errorObj = json['error'];
    if (errorObj is Map) {
      return _fromOpenAi(
        errorType: errorObj['type'] as String?,
        errorCode: errorObj['code'] as String?,
        message: errorObj['message'] as String?,
        param: errorObj['param'] as String?,
        statusCode: statusCode,
        providerName: providerName,
        requestId: requestId,
      );
    }

    // 4. Generic {message: "..."} fallback.
    final genericMsg = json['message'];
    if (genericMsg is String && genericMsg.isNotEmpty) {
      return LlmError(
        kind: _kindFromStatus(statusCode),
        vendor: vendor,
        statusCode: statusCode,
        message: genericMsg,
        requestId: requestId,
        providerName: providerName,
      );
    }
  }

  // Plain-text body or unrecognised shape.
  final fallbackMsg = body.trim().isEmpty ? 'HTTP $statusCode' : body.trim();
  return LlmError(
    kind: _kindFromStatus(statusCode),
    vendor: vendor,
    statusCode: statusCode,
    message: fallbackMsg,
    requestId: requestId,
    providerName: providerName,
  );
}

/// Parse an Anthropic-format mid-stream SSE error event.
///
/// Per Anthropic's docs, `event: error` can fire after a 200
/// response (e.g. `overloaded_error` during high traffic). The
/// payload shape matches Anthropic's HTTP error body but with no
/// HTTP status to lean on — [statusCode] is left null and
/// classification comes from `error.type` alone.
LlmError parseAnthropicStreamError({
  required Map<String, dynamic> eventJson,
  String providerName = '',
  String? requestId,
}) {
  final errorObj = eventJson['error'];
  if (errorObj is Map) {
    return _fromAnthropic(
      errorType: errorObj['type'] as String?,
      message: errorObj['message'] as String?,
      statusCode: null,
      providerName: providerName,
      requestId: requestId,
    );
  }
  // Defensive: payload shape we don't recognise. Don't pretend we
  // know what it means.
  return LlmError(
    kind: LlmErrorKind.unknown,
    vendor: LlmVendorX.fromProviderName(providerName),
    message: eventJson.toString(),
    requestId: requestId,
    providerName: providerName,
  );
}

/// Parse an OpenAI-format mid-stream SSE error payload. OpenAI's
/// Chat Completions stream surfaces errors as a `data:` line whose
/// JSON contains an `error` object with `message` / `type` /
/// `code` / `param`.
LlmError parseOpenAiStreamError({
  required Map<String, dynamic> eventJson,
  String providerName = '',
}) {
  final errorObj = eventJson['error'];
  if (errorObj is Map) {
    return _fromOpenAi(
      errorType: errorObj['type'] as String?,
      errorCode: errorObj['code'] as String?,
      message: errorObj['message'] as String?,
      param: errorObj['param'] as String?,
      statusCode: null,
      providerName: providerName,
    );
  }
  return LlmError(
    kind: LlmErrorKind.unknown,
    vendor: LlmVendorX.fromProviderName(providerName),
    message: eventJson.toString(),
    providerName: providerName,
  );
}

/// Classify a thrown exception from the HTTP layer into an
/// [LlmError]. Handles the `dart:io` exceptions surfaced by
/// `HttpClient` plus a final fallback for anything else.
///
/// Mirrors the philosophy of [isConnectionError] in
/// `proxy_aware_http.dart`: network / TLS / timeout are
/// connection-class errors, anything else is [LlmErrorKind.unknown].
LlmError classifyThrownError(Object error, {String providerName = ''}) {
  if (error is TimeoutException) {
    return LlmError(
      kind: LlmErrorKind.timeout,
      vendor: LlmVendorX.fromProviderName(providerName),
      message: 'Request timed out',
      cause: error,
      providerName: providerName,
    );
  }
  if (error is SocketException ||
      error is HandshakeException ||
      error is HttpException) {
    return LlmError(
      kind: LlmErrorKind.network,
      vendor: LlmVendorX.fromProviderName(providerName),
      message: error.toString(),
      cause: error,
      providerName: providerName,
    );
  }
  return LlmError(
    kind: LlmErrorKind.unknown,
    vendor: LlmVendorX.fromProviderName(providerName),
    message: error.toString(),
    cause: error,
    providerName: providerName,
  );
}

// ─── internal: per-vendor kind mapping ──────────────────────────

LlmError _fromAnthropic({
  required String? errorType,
  required String? message,
  required int? statusCode,
  required String providerName,
  String? requestId,
}) {
  return LlmError(
    kind: _anthropicKind(errorType, statusCode),
    vendor: LlmVendor.anthropic,
    statusCode: statusCode,
    vendorCode: errorType,
    message: message ?? '',
    requestId: requestId,
    providerName: providerName,
  );
}

LlmError _fromOpenAi({
  required String? errorType,
  required String? errorCode,
  required String? message,
  required String? param,
  required int? statusCode,
  required String providerName,
  String? requestId,
}) {
  return LlmError(
    kind: _openAiKind(errorType, errorCode, statusCode),
    vendor: LlmVendor.openai,
    statusCode: statusCode,
    vendorCode: errorCode ?? errorType,
    message: message ?? '',
    requestId: requestId,
    providerName: providerName,
  );
}

LlmError _fromMiniMax({
  required String code,
  required String msg,
  required int? statusCode,
  required String providerName,
}) {
  return LlmError(
    kind: _minimaxKind(code),
    vendor: LlmVendor.minimax,
    statusCode: statusCode,
    vendorCode: code,
    message: msg,
    providerName: providerName,
  );
}

LlmErrorKind _anthropicKind(String? type, int? statusCode) {
  switch (type) {
    case 'authentication_error':
      return LlmErrorKind.auth;
    case 'permission_error':
      return LlmErrorKind.permission;
    case 'billing_error':
      return LlmErrorKind.billing;
    case 'rate_limit_error':
      return LlmErrorKind.rateLimit;
    case 'invalid_request_error':
      return LlmErrorKind.invalidRequest;
    case 'request_too_large':
      return LlmErrorKind.contextLength;
    case 'not_found_error':
      return LlmErrorKind.notFound;
    case 'overloaded_error':
      return LlmErrorKind.overloaded;
    case 'api_error':
      return LlmErrorKind.serverError;
    case 'timeout_error':
      return LlmErrorKind.timeout;
  }
  // No `error.type` we recognise — fall back to the HTTP status.
  return _kindFromStatus(statusCode);
}

LlmErrorKind _openAiKind(String? type, String? code, int? statusCode) {
  // OpenAI's `error.type` is mostly a coarse bucket (often
  // `invalid_request_error` for both auth and bad-param cases),
  // so we lean on the HTTP status for the primary mapping and
  // override only when the code/type carries more specific
  // information than the status can express.

  // Code-based overrides (more specific than status).
  if (code == 'context_length_exceeded') return LlmErrorKind.contextLength;
  if (code == 'insufficient_quota') return LlmErrorKind.quota;
  if (code == 'invalid_api_key') return LlmErrorKind.auth;
  if (code == 'organization_not_found') return LlmErrorKind.auth;

  // `slow_down` is the shared-tier 503 throttle signal — treat as
  // overloaded regardless of whether it arrived via `error.type`
  // or `error.code`.
  if (type == 'slow_down' || code == 'slow_down') {
    return LlmErrorKind.overloaded;
  }

  // Fall back to the HTTP status. This handles the common
  // cases cleanly: 401 → auth, 403 → permission, 429 → rateLimit,
  // 500 → serverError, 503 → overloaded, etc. — and doesn't get
  // fooled by `type: 'invalid_request_error'` arriving on a 401
  // (which the type-based branch above would otherwise mis-route
  // to invalidRequest).
  return _kindFromStatus(statusCode);
}

LlmErrorKind _minimaxKind(String code) {
  switch (code) {
    // Auth
    case '1004':
    case '2049':
      return LlmErrorKind.auth;
    // Permission
    case '2042':
      return LlmErrorKind.permission;
    // Billing / quota
    case '1008':
      return LlmErrorKind.billing;
    case '2056':
      return LlmErrorKind.quota;
    // Rate-limit
    case '1002':
    case '2045':
      return LlmErrorKind.rateLimit;
    // Content policy
    case '1026':
    case '1027':
      return LlmErrorKind.contentPolicy;
    // Context length
    case '1039':
      return LlmErrorKind.contextLength;
    // Overloaded
    case '1041':
      return LlmErrorKind.overloaded;
    // Server errors
    case '1000':
    case '1024':
    case '1033':
      return LlmErrorKind.serverError;
    // Timeout
    case '1001':
      return LlmErrorKind.timeout;
    // Invalid request (LLM-streaming codes only; voice/clone codes
    // never reach this path).
    case '2013':
    case '1042':
    case '20132':
    case '2037':
      return LlmErrorKind.invalidRequest;
    // Conflict
    case '2039':
      return LlmErrorKind.conflict;
    default:
      return LlmErrorKind.unknown;
  }
}

LlmErrorKind _kindFromStatus(int? status) {
  if (status == null) return LlmErrorKind.unknown;
  if (status == 401) return LlmErrorKind.auth;
  if (status == 403) return LlmErrorKind.permission;
  if (status == 404) return LlmErrorKind.notFound;
  if (status == 408) return LlmErrorKind.timeout;
  if (status == 409) return LlmErrorKind.conflict;
  if (status == 413) return LlmErrorKind.contextLength;
  if (status == 429) return LlmErrorKind.rateLimit;
  if (status == 500) return LlmErrorKind.serverError;
  if (status == 502 || status == 503) return LlmErrorKind.overloaded;
  if (status == 504) return LlmErrorKind.timeout;
  if (status >= 500) return LlmErrorKind.serverError;
  if (status >= 400) return LlmErrorKind.invalidRequest;
  return LlmErrorKind.unknown;
}

Map<String, dynamic>? _tryParseJsonObject(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    return null;
  }
}

/// Decode a previously-persisted [LlmError] JSON blob from the
/// `messages.error` column. Tolerant of unknown enum values (e.g.
/// from a future Crux version that adds a new [LlmErrorKind]) —
/// unmapped kinds fall back to [LlmErrorKind.unknown] rather than
/// throwing, so old sessions can still be opened.
LlmError decodeLlmErrorJson(String src) {
  if (src.trim().isEmpty) {
    return const LlmError(
      kind: LlmErrorKind.unknown,
      vendor: LlmVendor.unknown,
      message: '',
    );
  }
  try {
    final map = jsonDecode(src) as Map<String, dynamic>;
    final kindName = map['kind'] as String?;
    final vendorName = map['vendor'] as String?;
    final kind = LlmErrorKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => LlmErrorKind.unknown,
    );
    final vendor = LlmVendor.values.firstWhere(
      (v) => v.name == vendorName,
      orElse: () => LlmVendor.unknown,
    );
    return LlmError(
      kind: kind,
      vendor: vendor,
      statusCode: map['statusCode'] as int?,
      vendorCode: map['vendorCode'] as String?,
      message: map['message'] as String? ?? '',
      requestId: map['requestId'] as String?,
      providerName: map['providerName'] as String? ?? '',
    );
  } catch (_) {
    // Defensive: malformed JSON. Don't crash the chat history
    // render — surface a generic unknown error instead.
    return const LlmError(
      kind: LlmErrorKind.unknown,
      vendor: LlmVendor.unknown,
      message: '',
    );
  }
}

import 'dart:convert';

import 'image_attachment.dart';

class ToolCallData {
  final String callId;
  final String name;
  final Map<String, dynamic> input;

  const ToolCallData({
    required this.callId,
    required this.name,
    required this.input,
  });

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'name': name,
    'input': input,
  };

  static ToolCallData fromJson(Map<String, dynamic> json) => ToolCallData(
    callId: json['callId'] as String,
    name: json['name'] as String,
    input: json['input'] as Map<String, dynamic>,
  );
}

class Message {
  final int id;
  final int sessionId;
  final String role;
  final String content;
  final String reasoningContent;
  final String reasoningSignature;
  final int reasoningTokens;
  final int thinkingDurationMs;
  final String? reasoningEffort;
  final String model;
  final int tokensIn;
  final int tokensOut;
  final String? error;
  final int? parentMsgId;
  final DateTime createdAt;
  final List<ToolCallData> toolCalls;
  final String toolCallId;
  final String tldr;
  final List<ImageAttachment> images;

  /// Free-form JSON metadata for inline UI affordances (e.g.
  /// `{"routing":"system-proxy"}` on a `webfetch` that fell back
  /// to the system proxy). Read by the chat-history bubble
  /// renderer; **never** sent to the LLM as part of the tool
  /// result body. Empty string when no UI metadata applies.
  final String meta;

  /// Telemetry-int column for system-role bubbles. Always `0` for
  /// content-bearing roles (`user`, `assistant`, `tool`, `tool_call`).
  /// Carries role-specific count data for the two system bubbles:
  ///
  ///   * `parallel_praise` rows — number of *successful* tool calls
  ///     in the round. Drives the "N tool calls parallelized" bubble
  ///     label and the ✦ glyph's success text.
  ///   * `single_call_reminder` rows — number of *consecutive*
  ///     single-tool-call rounds at the moment the modulo gate fired
  ///     (≥ threshold, so ≥ 10 with default). Drives the
  ///     "N consecutive single-tool-call rounds" bubble label.
  ///
  /// Same column, different meaning per role — the renderer dispatches
  /// on `role` and reads this field with the role-appropriate
  /// interpretation. Kept as a single column (rather than two
  /// role-specific ones) to avoid a schema migration and to mirror the
  /// existing pattern of one int payload column for system bubbles.
  final int parallelCount;

  Message({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.reasoningContent = '',
    this.reasoningSignature = '',
    this.reasoningTokens = 0,
    this.thinkingDurationMs = 0,
    this.reasoningEffort,
    this.model = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.error,
    this.parentMsgId,
    DateTime? createdAt,
    this.toolCalls = const [],
    this.toolCallId = '',
    this.tldr = '',
    this.images = const [],
    this.parallelCount = 0,
    this.meta = '',
  }) : createdAt = createdAt ?? DateTime.now();

  static List<ToolCallData> parseToolCallsJson(String json) {
    if (json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => ToolCallData.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Create a copy of this message with optional field overrides.
  /// Eliminates the repeated manual-copy pattern where callers re-list
  /// every field just to change one (e.g. updating `tldr`).
  Message copyWith({
    int? id,
    int? sessionId,
    String? role,
    String? content,
    String? reasoningContent,
    String? reasoningSignature,
    int? reasoningTokens,
    int? thinkingDurationMs,
    String? reasoningEffort,
    String? model,
    int? tokensIn,
    int? tokensOut,
    String? error,
    int? parentMsgId,
    DateTime? createdAt,
    List<ToolCallData>? toolCalls,
    String? toolCallId,
    String? tldr,
    List<ImageAttachment>? images,
    int? parallelCount,
    String? meta,
  }) {
    return Message(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      reasoningSignature: reasoningSignature ?? this.reasoningSignature,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
      thinkingDurationMs: thinkingDurationMs ?? this.thinkingDurationMs,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      model: model ?? this.model,
      tokensIn: tokensIn ?? this.tokensIn,
      tokensOut: tokensOut ?? this.tokensOut,
      error: error ?? this.error,
      parentMsgId: parentMsgId ?? this.parentMsgId,
      createdAt: createdAt ?? this.createdAt,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      tldr: tldr ?? this.tldr,
      images: images ?? this.images,
      parallelCount: parallelCount ?? this.parallelCount,
      meta: meta ?? this.meta,
    );
  }

  static String encodeToolCalls(List<ToolCallData> calls) {
    if (calls.isEmpty) return '';
    return jsonEncode(calls.map((c) => c.toJson()).toList());
  }
}

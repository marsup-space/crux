import 'dart:convert';

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
  final double cost;
  final int tokensIn;
  final int tokensOut;
  final String? error;
  final int? parentMsgId;
  final DateTime createdAt;
  final int? preCompressTokens;
  final List<ToolCallData> toolCalls;
  final String toolCallId;
  final String tldr;

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
    this.cost = 0.0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.error,
    this.parentMsgId,
    this.preCompressTokens,
    DateTime? createdAt,
    this.toolCalls = const [],
    this.toolCallId = '',
    this.tldr = '',
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
    double? cost,
    int? tokensIn,
    int? tokensOut,
    String? error,
    int? parentMsgId,
    DateTime? createdAt,
    int? preCompressTokens,
    List<ToolCallData>? toolCalls,
    String? toolCallId,
    String? tldr,
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
      cost: cost ?? this.cost,
      tokensIn: tokensIn ?? this.tokensIn,
      tokensOut: tokensOut ?? this.tokensOut,
      error: error ?? this.error,
      parentMsgId: parentMsgId ?? this.parentMsgId,
      createdAt: createdAt ?? this.createdAt,
      preCompressTokens: preCompressTokens ?? this.preCompressTokens,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      tldr: tldr ?? this.tldr,
    );
  }

  static String encodeToolCalls(List<ToolCallData> calls) {
    if (calls.isEmpty) return '';
    return jsonEncode(calls.map((c) => c.toJson()).toList());
  }
}

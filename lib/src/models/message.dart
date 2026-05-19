class Message {
  final int id;
  final int sessionId;
  final String role;
  final String content;
  final String model;
  final double cost;
  final int tokensIn;
  final int tokensOut;
  final String? error;
  final int? parentMsgId;
  final DateTime createdAt;

  Message({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.model = '',
    this.cost = 0.0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.error,
    this.parentMsgId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

import 'dart:convert';

enum PartType {
  text,
  tool,
  reasoning,
  snapshot,
  stepStart,
  stepFinish,
}

class Part {
  final int id;
  final int messageId;
  final int sessionId;
  final PartType type;
  final Map<String, dynamic> data;
  final DateTime createdAt;

  Part({
    required this.id,
    required this.messageId,
    required this.sessionId,
    required this.type,
    Map<String, dynamic>? data,
    DateTime? createdAt,
  })  : data = data ?? {},
        createdAt = createdAt ?? DateTime.now();

  String get dataJson => jsonEncode(data);

  static Map<String, dynamic> parseDataJson(String json) {
    if (json.isEmpty) return {};
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  String? get text => data['text'] as String?;
  String? get toolName => data['name'] as String?;
  Map<String, dynamic>? get toolInput => data['input'] as Map<String, dynamic>?;
  String? get toolOutput => data['output'] as String?;
  String? get toolStatus => data['status'] as String?;
}

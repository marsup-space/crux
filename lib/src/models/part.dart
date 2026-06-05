import 'dart:convert';

enum PartType { text, tool }

extension PartTypeValue on PartType {
  String get value => name;
}

class PartData {
  final PartType type;
  final Map<String, dynamic> data;

  const PartData({required this.type, required this.data});
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
  }) : data = data ?? {},
       createdAt = createdAt ?? DateTime.now();

  static Map<String, dynamic> parseDataJson(String json) {
    if (json.isEmpty) return {};
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

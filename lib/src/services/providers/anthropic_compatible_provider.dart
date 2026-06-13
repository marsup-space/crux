import '../../models/provider_config.dart';
import '../llm_provider.dart';

class AnthropicCompatibleProvider extends LlmProvider {
  @override
  String get name => 'anthropic_compatible';

  @override
  WireFamily get wire => WireFamily.anthropicCompatible;

  @override
  AuthStyle get authStyle => AuthStyle.anthropicApiKey;

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final body = <String, dynamic>{
      'model': modelId,
      'messages': injectCacheBreakpoints(chatMsgs),
      'max_tokens': maxTokens ?? 16384,
      'stream': true,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = buildCachedSystemBlocks(systemMsg);
    }
    if (thinkingMode == 'enabled') {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget ?? 10000,
      };
      if (reasoningEffort != null) {
        body['output_config'] = {
          'effort': mapEffort(reasoningEffort),
        };
      }
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = buildCachedTools(tools);
    }
    return body;
  }

  List<Map<String, dynamic>> buildCachedSystemBlocks(
    List<Map<String, dynamic>> systemMsg,
  ) {
    if (systemMsg.isEmpty) return [];
    final blocks = systemMsg
        .map((m) => <String, dynamic>{
              'type': 'text',
              'text': m['content'] as String,
            })
        .toList();
    blocks.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
    return blocks;
  }

  List<Map<String, dynamic>> buildCachedTools(
    List<Map<String, dynamic>> tools,
  ) {
    if (tools.isEmpty) return [];
    final result = tools
        .map((t) => <String, dynamic>{
              'name': t['name'],
              'description': t['description'],
              'input_schema': t['parameters'] as Map<String, dynamic>,
            })
        .toList();
    result.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
    return result;
  }

  List<Map<String, dynamic>> injectCacheBreakpoints(
    List<Map<String, dynamic>> chatMsgs,
  ) {
    if (chatMsgs.isEmpty) return chatMsgs;
    final result = chatMsgs
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final last = result.last;
    final content = last['content'];
    if (content == null) return result;
    if (content is String) {
      if (content.isEmpty) return result;
      last['content'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': content,
          'cache_control': <String, dynamic>{'type': 'ephemeral'},
        },
      ];
    } else if (content is List) {
      final blocks = content
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      if (blocks.isNotEmpty) {
        blocks.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
      }
      last['content'] = blocks;
    }
    return result;
  }

  String mapEffort(String? effort) {
    switch (effort) {
      case 'low':
        return 'low';
      case 'normal':
      case 'medium':
        return 'medium';
      case 'high':
        return 'high';
      case 'max':
        return 'max';
      default:
        return 'medium';
    }
  }
}

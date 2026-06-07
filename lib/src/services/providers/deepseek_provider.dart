import '../providers/openai_compatible_provider.dart';

class DeepSeekProvider extends OpenAICompatibleProvider {
  @override
  String get name => 'deepseek';

  @override
  String mapEffort(String? effort) {
    switch (effort) {
      case 'normal':
        return 'high';
      case 'high':
        return 'xhigh';
      case 'max':
        return 'max';
      default:
        return 'high';
    }
  }
}

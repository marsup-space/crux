import '../components/ui/toast.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'command_executor.dart';
Future<void> executeProject(List<String> parts, CommandContext ctx) async {
  if (parts.length > 1 && parts[1].isNotEmpty) {
    final expanded = _expandHome(parts[1]);
    final target = p.normalize(p.absolute(expanded));
    final dir = Directory(target);
    if (!dir.existsSync()) {
      ctx.showToast('Directory not found: $target', mode: ToastMode.error);
    } else {
      Directory.current = dir;
      await ctx.recentProjectsStore?.add(target);
      await ctx.initSessions();
      ctx.showToast('Switched to $target', mode: ToastMode.status);
    }
  } else {
    ctx.showToast('Usage: /project <path> (current: ${ctx.projectPath})');
  }
}
String _expandHome(String path) {
  final hasHomePrefix = path == '~' || path.startsWith('~/') || path.startsWith(r'~\');
  if (!hasHomePrefix) return path;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) return path;
  if (path == '~' || path.length == 2) return home;
  return p.join(home, path.substring(2));
}

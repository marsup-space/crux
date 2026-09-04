import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  const executable = '/Applications/Codex.app/Contents/Resources/codex';
  final process = await Process.start(executable, ['app-server', '--stdio']);
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final subscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        try {
          final message = jsonDecode(line) as Map<String, dynamic>;
          final id = message['id'];
          if (id is! int) return;
          final completer = pending.remove(id);
          if (completer == null) return;
          final result = message['result'];
          if (result is Map) {
            completer.complete(Map<String, dynamic>.from(result));
          } else {
            completer.completeError(StateError('RPC returned an error'));
          }
        } catch (_) {}
      });

  Future<Map<String, dynamic>> request(
    int id,
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final completer = Completer<Map<String, dynamic>>();
    pending[id] = completer;
    process.stdin.writeln(jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(const Duration(seconds: 10));
  }

  try {
    await request(1, 'initialize', {
      'clientInfo': {'name': 'crux', 'title': 'Crux', 'version': 'diagnostic'},
      'capabilities': {'experimentalApi': true},
    });
    process.stdin.writeln(jsonEncode({'method': 'initialized', 'params': {}}));
    final account = await request(2, 'account/read', {'refreshToken': false});
    final accountData = account['account'];
    stdout.writeln(
      'app_server_auth=${accountData is Map && accountData['type'] == 'chatgpt' ? 'chatgpt' : 'unavailable'}',
    );
    if (accountData is! Map || accountData['type'] != 'chatgpt') return;

    final limits = await request(3, 'account/rateLimits/read');
    stdout.writeln('rate_limits=${limits['rateLimits'] is Map ? 'available' : 'absent'}');
  } catch (_) {
    stdout.writeln('app_server_result=failed');
  } finally {
    await subscription.cancel();
    await process.stdin.close();
    process.kill(ProcessSignal.sigterm);
  }
}

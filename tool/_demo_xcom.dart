// Demonstration of the system-proxy auto-fallback against x.com,
// which is blocked from direct connections in mainland China.
//
// The script runs three attempts against https://x.com/:
//   1. Direct connection (no findProxy set) — should time out.
//   2. Explicitly routed through the detected system proxy —
//      should succeed.
//   3. withProxyRetry, which tries direct first and only falls
//      back to the system proxy on a connection error — the
//      "auto retry with system proxy if direct connection fails"
//      path used by the webfetch tool and LlmClient. Should
//      succeed via the fallback.
//
// Usage: dart run tool/_demo_xcom.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/utils/proxy_aware_http.dart';
import 'package:crux/src/utils/system_proxy.dart';

const String _url = 'https://x.com/';

class _Result {
  final bool ok;
  final int? status;
  final String? body;
  final String? error;
  final int ms;
  final bool usedProxy;
  _Result(
    this.ok,
    this.ms, {
    this.status,
    this.body,
    this.error,
    this.usedProxy = false,
  });
  @override
  String toString() {
    if (ok) {
      return '✓ $ms ms, status $status, ${body?.length ?? 0} bytes'
          '${usedProxy ? "  [via system proxy]" : ""}';
    }
    return '✗ $ms ms, error: $error';
  }
}

Future<_Result> _directAttempt() async {
  final sw = Stopwatch()..start();
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(_url));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    sw.stop();
    return _Result(
      true,
      sw.elapsedMilliseconds,
      status: resp.statusCode,
      body: body,
    );
  } catch (e) {
    sw.stop();
    return _Result(false, sw.elapsedMilliseconds, error: e.toString());
  } finally {
    client.close(force: true);
  }
}

Future<_Result> _proxyAttempt(SystemProxy proxy) async {
  final sw = Stopwatch()..start();
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  client.findProxy = proxy.findProxyFor;
  try {
    final req = await client.getUrl(Uri.parse(_url));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    sw.stop();
    return _Result(
      true,
      sw.elapsedMilliseconds,
      status: resp.statusCode,
      body: body,
      usedProxy: true,
    );
  } catch (e) {
    sw.stop();
    return _Result(
      false,
      sw.elapsedMilliseconds,
      error: e.toString(),
      usedProxy: true,
    );
  } finally {
    client.close(force: true);
  }
}

Future<_Result> _withProxyRetryAttempt() async {
  final sw = Stopwatch()..start();
  bool usedProxy = false;
  try {
    final resp = await withProxyRetry<HttpClientResponse>(
      attempt: (p) async {
        if (p != null) usedProxy = true;
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 8);
        if (p != null) client.findProxy = p.findProxyFor;
        try {
          final req = await client.getUrl(Uri.parse(_url));
          return req.close();
        } catch (e) {
          rethrow;
        }
      },
    );
    final body = await resp.transform(utf8.decoder).join();
    sw.stop();
    return _Result(
      true,
      sw.elapsedMilliseconds,
      status: resp.statusCode,
      body: body,
      usedProxy: usedProxy,
    );
  } catch (e) {
    sw.stop();
    return _Result(false, sw.elapsedMilliseconds, error: e.toString());
  }
}

Future<void> _section(String title) async {
  stdout.writeln('');
  stdout.writeln('─' * 70);
  stdout.writeln(title);
  stdout.writeln('─' * 70);
}

void main() async {
  final proxy = SystemProxyDetector.detect();
  stdout.writeln('System proxy detected: $proxy');
  stdout.writeln('Target URL: $_url');

  if (proxy == null) {
    stderr.writeln(
      '\nNo system proxy detected on this machine — demo cannot run.',
    );
    exit(1);
  }

  await _section('1) Direct connection (no findProxy)');
  final direct = await _directAttempt();
  stdout.writeln('  $direct');

  await _section('2) Explicit system proxy (findProxy set from the start)');
  final viaProxy = await _proxyAttempt(proxy);
  stdout.writeln('  $viaProxy');

  await _section('3) withProxyRetry — the webfetch / LlmClient path');
  final retried = await _withProxyRetryAttempt();
  stdout.writeln('  $retried');

  stdout.writeln('');
  if (!direct.ok && (viaProxy.ok || retried.ok)) {
    stdout.writeln('✓ Direct failed, but the system-proxy path works — ');
    stdout.writeln('  this is exactly what webfetch / LlmClient will use.');
  } else if (direct.ok) {
    stdout.writeln('Note: direct connection succeeded — x.com is not blocked ');
    stdout.writeln('  from this network. The fallback would still engage on ');
    stdout.writeln('  a real connection error.');
  } else {
    stdout.writeln('Both paths failed. The system proxy may not actually ');
    stdout.writeln('  be able to reach x.com from this machine.');
  }

  // Force-exit so the script doesn't wait for a lingering keep-alive
  // socket (the `withProxyRetry` attempt's HttpClient may still be
  // holding a connection to the proxy at the end).
  exit(0);
}

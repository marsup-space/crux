import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ChatGPT device-code OAuth helper, matching the public Codex client flow.
class CodexOAuth {
  static const clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const issuer = 'https://auth.openai.com';

  static Future<
    ({
      String verificationUrl,
      String userCode,
      String deviceId,
      Duration interval,
    })
  >
  beginDeviceLogin() async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('$issuer/api/accounts/deviceauth/usercode'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'client_id': clientId}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw StateError(
          'ChatGPT device login failed (HTTP ${response.statusCode})',
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (
        verificationUrl: '$issuer/codex/device',
        userCode: json['user_code'] as String,
        deviceId: json['device_auth_id'] as String,
        interval: Duration(seconds: int.tryParse('${json['interval']}') ?? 5),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> waitForDeviceLogin({
    required String deviceId,
    required String userCode,
    required Duration interval,
  }) async {
    while (true) {
      await Future<void>.delayed(interval);
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('$issuer/api/accounts/deviceauth/token'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({'device_auth_id': deviceId, 'user_code': userCode}),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 403 || response.statusCode == 404) continue;
        if (response.statusCode != 200) {
          throw StateError(
            'ChatGPT device login was rejected (HTTP ${response.statusCode})',
          );
        }
        final approval = jsonDecode(body) as Map<String, dynamic>;
        return await _exchangeAuthorizationCode(
          approval['authorization_code'] as String,
          approval['code_verifier'] as String,
        );
      } finally {
        client.close(force: true);
      }
    }
  }

  static Future<String> _exchangeAuthorizationCode(
    String code,
    String verifier,
  ) => _token({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': '$issuer/deviceauth/callback',
    'client_id': clientId,
    'code_verifier': verifier,
  });

  static Future<String> refresh(String refreshToken, {String? accountId}) =>
      _token({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      }, fallbackAccountId: accountId);

  static Future<String> _token(
    Map<String, String> fields, {
    String? fallbackAccountId,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$issuer/oauth/token'));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(Uri(queryParameters: fields).query);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw StateError(
          'ChatGPT token exchange failed (HTTP ${response.statusCode})',
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      return CodexCredential.encode(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        // Recent OAuth responses may put the account identifier directly
        // on the token response while older ones only place it in either
        // JWT. Inspect both tokens before falling back to the account we
        // already had — refresh responses commonly omit `id_token`.
        accountId:
            CodexCredential.extractAccountIdFromTokenResponse(json) ??
            fallbackAccountId,
        expiresAt: DateTime.now().add(
          Duration(seconds: json['expires_in'] as int? ?? 3600),
        ),
      );
    } finally {
      client.close(force: true);
    }
  }
}

class CodexCredential {
  final String accessToken;
  final String refreshToken;
  final String? accountId;
  final DateTime expiresAt;
  const CodexCredential(
    this.accessToken,
    this.refreshToken,
    this.expiresAt, {
    this.accountId,
  });

  static const _prefix = 'crux-codex-oauth:';

  static String encode({
    required String accessToken,
    required String refreshToken,
    String? accountId,
    required DateTime expiresAt,
  }) =>
      '$_prefix${base64Url.encode(utf8.encode(jsonEncode({'access': accessToken, 'refresh': refreshToken, 'accountId': accountId, 'expiresAt': expiresAt.millisecondsSinceEpoch})))}';

  static CodexCredential? decode(String value) {
    if (!value.startsWith(_prefix)) return null;
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(value.substring(_prefix.length))),
      ) as Map<String, dynamic>;
      return CodexCredential(
        json['access'] as String,
        json['refresh'] as String,
        DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
        accountId: json['accountId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Extract the ChatGPT workspace/account id from a complete OAuth token
  /// response. Device-code token exchanges may supply the identifier as a
  /// response field, `id_token` claim, or only an access-token claim.
  static String? extractAccountIdFromTokenResponse(
    Map<String, dynamic> response,
  ) {
    for (final field in const [
      'chatgpt_account_id',
      'chatgptAccountId',
      'account_id',
      'accountId',
    ]) {
      final value = response[field];
      if (value is String && value.isNotEmpty) return value;
    }
    for (final field in const ['id_token', 'access_token']) {
      final value = response[field];
      if (value is! String) continue;
      final accountId = extractAccountId(value);
      if (accountId != null) return accountId;
    }
    return null;
  }

  /// Extract the ChatGPT workspace/account id from an OAuth JWT without
  /// sending the token anywhere. The claim layout matches Codex/OpenCode's
  /// device-auth flow and has a couple of historical fallbacks.
  static String? extractAccountId(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final direct = payload['chatgpt_account_id'];
      if (direct is String && direct.isNotEmpty) return direct;
      final auth = payload['https://api.openai.com/auth'];
      if (auth is Map) {
        final accountId = auth['chatgpt_account_id'];
        if (accountId is String && accountId.isNotEmpty) return accountId;
      }
      final organizations = payload['organizations'];
      if (organizations is List && organizations.isNotEmpty) {
        final first = organizations.first;
        if (first is Map && first['id'] is String) return first['id'] as String;
      }
    } catch (_) {
      // A non-JWT or an unfamiliar claim layout simply means no optional
      // workspace header is attached.
    }
    return null;
  }
}

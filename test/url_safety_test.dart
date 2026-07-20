import 'dart:io';

import 'package:crux/src/tools/url_safety.dart';
import 'package:test/test.dart';

void main() {
  group('UrlSafety.blockedAddressReason (pure)', () {
    String? reason(String ip) =>
        UrlSafety.blockedAddressReason(InternetAddress(ip));

    group('blocked', () {
      test('cloud metadata endpoint 169.254.169.254', () {
        expect(reason('169.254.169.254'), contains('169.254.0.0/16'));
      });

      test('link-local 169.254.x.y generally', () {
        expect(reason('169.254.0.1'), isNotNull);
        expect(reason('169.254.255.255'), isNotNull);
      });

      test('CGNAT 100.64.0.0/10 boundaries', () {
        expect(reason('100.64.0.0'), contains('100.64.0.0/10'));
        expect(reason('100.127.255.255'), contains('100.64.0.0/10'));
      });

      test('unspecified 0.0.0.0/8', () {
        expect(reason('0.0.0.0'), isNotNull);
        expect(reason('0.1.2.3'), isNotNull);
      });

      test('IPv6 link-local fe80::/10', () {
        expect(reason('fe80::1'), contains('fe80::/10'));
        expect(reason('fe80::dead:beef'), isNotNull);
      });

      test('IPv6 unspecified ::', () {
        expect(reason('::'), isNotNull);
      });

      test('IPv4-mapped IPv6 metadata address is judged as IPv4', () {
        expect(reason('::ffff:169.254.169.254'), contains('IPv4-mapped IPv6'));
      });
    });

    group('allowed', () {
      test('CGNAT boundaries just outside /10', () {
        expect(reason('100.63.255.255'), isNull);
        expect(reason('100.128.0.0'), isNull);
      });

      test('private ranges (intranet wikis are legitimate)', () {
        expect(reason('10.0.0.5'), isNull);
        expect(reason('172.16.0.1'), isNull);
        expect(reason('172.31.255.255'), isNull);
        expect(reason('192.168.1.1'), isNull);
      });

      test('localhost (dev servers are legitimate)', () {
        expect(reason('127.0.0.1'), isNull);
        expect(reason('127.0.1.1'), isNull);
        expect(reason('::1'), isNull);
      });

      test('public addresses', () {
        expect(reason('8.8.8.8'), isNull);
        expect(reason('1.1.1.1'), isNull);
        expect(reason('2606:4700:4700::1111'), isNull);
      });
    });
  });

  group('UrlSafety.check (Uri-level)', () {
    test('rejects non-http(s) schemes', () async {
      expect(
        await UrlSafety.check(Uri.parse('file:///etc/passwd')),
        contains('not fetchable'),
      );
      expect(
        await UrlSafety.check(Uri.parse('ftp://example.com/')),
        contains('not fetchable'),
      );
    });

    test('blocks literal metadata IP without DNS', () async {
      final reason = await UrlSafety.check(
        Uri.parse('https://169.254.169.254/latest/meta-data'),
      );
      expect(reason, contains('169.254.0.0/16'));
    });

    test('allows literal localhost / private IPs without DNS', () async {
      expect(
        await UrlSafety.check(Uri.parse('http://127.0.0.1:8080/dev')),
        isNull,
      );
      expect(
        await UrlSafety.check(Uri.parse('https://192.168.0.10/wiki')),
        isNull,
      );
    });

    test('"localhost" resolves to loopback and is allowed', () async {
      // Uses the system resolver; localhost must resolve via the
      // hosts file even offline.
      expect(
        await UrlSafety.check(Uri.parse('http://localhost:3000/')),
        isNull,
      );
    });

    test('unresolvable hostname is allowed through (fetch reports '
        'the DNS error)', () async {
      expect(
        await UrlSafety.check(
          Uri.parse('https://nonexistent.invalid.example/'),
        ),
        isNull,
      );
    });
  });

  group('UrlSafety.isLocalAddress (pure)', () {
    bool local(String ip) => UrlSafety.isLocalAddress(InternetAddress(ip));

    test('loopback, private, link-local, CGNAT, ULA are local', () {
      expect(local('127.0.0.1'), isTrue);
      expect(local('127.0.1.1'), isTrue);
      expect(local('10.0.0.5'), isTrue);
      expect(local('172.16.0.1'), isTrue);
      expect(local('172.31.255.255'), isTrue);
      expect(local('192.168.1.1'), isTrue);
      expect(local('169.254.169.254'), isTrue);
      expect(local('100.64.0.1'), isTrue);
      expect(local('0.0.0.0'), isTrue);
      expect(local('::1'), isTrue);
      expect(local('::'), isTrue);
      expect(local('fe80::1'), isTrue);
      expect(local('fd00::1'), isTrue);
      expect(local('::ffff:10.0.0.1'), isTrue);
    });

    test('public addresses are not local', () {
      expect(local('8.8.8.8'), isFalse);
      expect(local('172.15.0.1'), isFalse); // just outside 172.16/12
      expect(local('172.32.0.1'), isFalse);
      expect(local('100.128.0.0'), isFalse); // just outside CGNAT /10
      expect(local('2606:4700:4700::1111'), isFalse);
    });
  });

  group('UrlSafety.isLocalTarget (Uri-level)', () {
    test('literal loopback / private IPs are local', () async {
      expect(
        await UrlSafety.isLocalTarget(Uri.parse('http://127.0.0.1:8080/')),
        isTrue,
      );
      expect(
        await UrlSafety.isLocalTarget(Uri.parse('https://192.168.0.10/')),
        isTrue,
      );
    });

    test('literal public IPs are not local', () async {
      expect(
        await UrlSafety.isLocalTarget(Uri.parse('https://1.1.1.1/')),
        isFalse,
      );
    });

    test('"localhost" is local', () async {
      expect(
        await UrlSafety.isLocalTarget(Uri.parse('http://localhost:3000/')),
        isTrue,
      );
    });

    test('unresolvable hostname is treated as remote', () async {
      expect(
        await UrlSafety.isLocalTarget(
          Uri.parse('https://nonexistent.invalid.example/'),
        ),
        isFalse,
      );
    });
  });
}

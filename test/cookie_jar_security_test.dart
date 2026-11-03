import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/network/cookie_jar.dart';

void main() {
  late Directory directory;
  late CookieJarSql jar;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-cookie-test-');
    jar = CookieJarSql('${directory.path}/cookies.db');
  });

  tearDown(() async {
    jar.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'logout revokes owned cookies after restart and preserves other hosts',
    () {
      final first = Uri.parse('https://source.example/');
      final second = Uri.parse('https://other.example/');
      jar.saveFromResponse(first, [
        Cookie('session', 'private'),
      ], sourceKey: 'source');
      jar.saveFromResponse(second, [
        Cookie('session', 'other'),
      ], sourceKey: 'other');
      jar.dispose();
      jar = CookieJarSql('${directory.path}/cookies.db');
      jar.deleteForSource('source');
      expect(jar.loadForRequestCookieHeader(first), isEmpty);
      expect(jar.loadForRequestCookieHeader(second), 'session=other');
    },
  );

  test('cookies first used from a GUI profile gain source ownership', () {
    final uri = Uri.parse('https://source.example/');
    jar.saveFromResponse(uri, [Cookie('session', 'legacy')]);
    expect(
      jar.loadForRequestCookieHeader(uri, sourceKey: 'source'),
      'session=legacy',
    );
    jar.deleteForSource('source');
    expect(jar.loadForRequestCookieHeader(uri), isEmpty);
  });

  test('Secure cookies are never sent over HTTP', () {
    final cookie = Cookie('session', 'secret')..secure = true;
    jar.saveFromResponse(Uri.parse('https://example.com/'), [cookie]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('http://example.com/')),
      isEmpty,
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/')),
      'session=secret',
    );
  });

  test('a response cannot plant cookies for an unrelated domain', () {
    final cookie = Cookie('session', 'secret')..domain = '.victim.com';
    jar.saveFromResponse(Uri.parse('https://attacker.com/'), [cookie]);

    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://victim.com/')),
      isEmpty,
    );
  });

  test('a cookie path does not match a sibling path prefix', () {
    final cookie = Cookie('session', 'secret')..path = '/comic';
    jar.saveFromResponse(Uri.parse('https://example.com/comic'), [cookie]);

    expect(
      jar.loadForRequestCookieHeader(
        Uri.parse('https://example.com/comic-extra'),
      ),
      isEmpty,
    );
    expect(
      jar.loadForRequestCookieHeader(Uri.parse('https://example.com/comic/1')),
      'session=secret',
    );
  });
}

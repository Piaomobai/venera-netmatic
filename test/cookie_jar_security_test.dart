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

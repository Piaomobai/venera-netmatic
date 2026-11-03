import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/credentials.dart';
import 'package:venera_netmatic/headless/source_auth.dart';

class AuthSource implements ComicSource {
  @override
  String get key => 'fixture';
  @override
  Map<String, dynamic> data = {
    'settings': {'api': 'fixture'},
    'cache': 'old',
  };
  @override
  bool get isLogged => data['account'] != null;
  @override
  bool accountMutationInProgress = false;
  @override
  bool accountCleanupFailed = false;
  @override
  AccountConfig? account;
  final writes = <Map<String, dynamic>>[];
  int? failSaveAt;
  int saves = 0;
  @override
  Future<void> flushPendingData() async {}
  @override
  Future<void> saveData() async {
    if (!accountMutationInProgress) {
      if (++saves == failSaveAt) throw StateError('private storage detail');
      writes.add(jsonDecode(jsonEncode(data)));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AuthSource source;
  late CliControl control;
  late SourceAuth auth;
  late Directory temp;
  var loginCalls = 0;
  SourceCredentials credentials([
    String user = 'alice',
    String password = 'secret',
  ]) => SourceCredentials.parse({'username': user, 'password': password});
  AccountConfig account({
    LoginFunction? login,
    Future<void> Function()? logout,
    Future<bool> Function()? verify,
    Future<void> Function()? idle,
  }) => AccountConfig(
    login ??
        (user, password) async {
          loginCalls++;
          source.data['token'] = 'private-token';
          await source.saveData();
          return const Res(true);
        },
    null,
    null,
    () {},
    null,
    null,
    null,
    null,
    logoutAsync: logout,
    validateSession: verify,
    waitForIdle: idle,
  );
  setUp(() async {
    source = AuthSource();
    control = CliControl();
    auth = SourceAuth(source, control);
    loginCalls = 0;
    source.account = account(verify: () async => true);
    temp = await Directory.systemTemp.createTemp('auth-input-');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'login stages token writes, verifies, and returns no identity or secret',
    () async {
      final result = await auth.login(credentials());
      expect(result.exitCode, 0);
      expect((result.data as Map)['state'], 'authenticated');
      expect(source.writes.length, 2); // clear identity, then commit
      expect(source.writes.first.containsKey('account'), isFalse);
      expect(source.writes.last['account'], ['alice', 'secret']);
      final output = jsonEncode(result.toJson());
      for (final secret in ['alice', 'secret', 'private-token']) {
        expect(output, isNot(contains(secret)));
      }
    },
  );

  test('an existing identity requires explicit replacement', () async {
    source.data['account'] = ['alice', 'secret'];
    final result = await cliGuard(() => auth.login(credentials('bob')));
    expect(result.code, 'already_logged_in');
    expect(source.data['account'], ['alice', 'secret']);
    expect(loginCalls, 0);
  });

  test(
    'failed replacement leaves no old or partially-written credentials',
    () async {
      source.data.addAll({
        'account': ['old', 'old-password'],
        'token': 'old-token',
      });
      source.account = account(
        login: (_, _) async {
          source.data['token'] = 'partial-new-token';
          await source.saveData();
          return const Res.error('password-echo-secret');
        },
      );
      final result = await cliGuard(
        () => auth.login(credentials('bob'), replace: true),
      );
      expect(result.code, 'authentication_failed');
      expect(source.data, {
        'settings': {'api': 'fixture'},
      });
      expect(source.writes.any((w) => w.containsKey('token')), isFalse);
      expect(
        jsonEncode(result.toJson()),
        isNot(contains('password-echo-secret')),
      );
    },
  );

  test('remote rejection rolls back successful login response', () async {
    source.account = account(verify: () async => false);
    expect(
      (await cliGuard(() => auth.login(credentials()))).code,
      'authentication_failed',
    );
    expect(source.isLogged, isFalse);
    expect(source.data.containsKey('token'), isFalse);
  });

  test(
    'session persistence failure rolls back and reports storage failure',
    () async {
      source.failSaveAt = 2;
      final result = await cliGuard(() => auth.login(credentials()));
      expect(result.code, 'persistence_failed');
      expect(source.isLogged, isFalse);
      expect(source.data.containsKey('token'), isFalse);
      expect(source.accountMutationInProgress, isFalse);
      expect(source.writes.any((w) => w.containsKey('token')), isFalse);
      expect(result.message, isNot(contains('private storage detail')));
    },
  );

  for (final timeout in [false, true]) {
    test(
      '${timeout ? 'timeout' : 'cancellation'} waits for JS then rolls back late token',
      () async {
        final release = Completer<void>();
        source.account = account(
          login: (_, _) async {
            await release.future;
            source.data['token'] = 'late-token';
            await source.saveData();
            return const Res(true);
          },
        );
        var finished = false;
        final operation = cliGuard(() => auth.login(credentials())).then((v) {
          finished = true;
          return v;
        });
        while (!source.accountMutationInProgress) {
          await Future<void>.delayed(Duration.zero);
        }
        if (timeout) {
          control.timedOut = true;
        } else {
          control.cancelled = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(finished, isFalse);
        release.complete();
        final result = await operation;
        expect(result.code, timeout ? 'timeout' : 'cancelled');
        expect(source.isLogged, isFalse);
        expect(source.data.containsKey('token'), isFalse);
        expect(source.accountMutationInProgress, isFalse);
      },
    );
  }

  test(
    'replacement waits for timed-out source promises before clearing identity',
    () async {
      final pending = Completer<void>();
      source.data['account'] = ['old', 'password'];
      source.account = account(idle: () => pending.future);
      final result = auth.login(credentials('new'), replace: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.data['account'], ['old', 'password']);
      expect(loginCalls, 0);
      pending.complete();
      await result;
      expect(source.data['account'], ['new', 'secret']);
    },
  );

  test(
    'logout awaits async hook, clears unknown session fields, and is repeatable',
    () async {
      final release = Completer<void>();
      var calls = 0;
      source.account = account(
        logout: () async {
          if (++calls == 1) await release.future;
        },
      );
      source.data.addAll({
        'account': ['a', 'b'],
        'private_session_field': 'token',
      });
      final running = auth.logout();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.isLogged, isTrue);
      release.complete();
      expect((await running).exitCode, 0);
      expect((await auth.logout()).exitCode, 0);
      expect(source.data, {
        'settings': {'api': 'fixture'},
      });
    },
  );

  test(
    'failed logout hook still removes local credentials and returns an error',
    () async {
      source.account = account(
        logout: () async => throw StateError('secret response'),
      );
      source.data['account'] = ['alice', 'secret'];
      final result = await auth.logout();
      expect(result.code, 'source_cleanup_failed');
      expect(source.isLogged, isFalse);
      expect(result.message, isNot(contains('secret response')));
    },
  );

  test(
    'expired session can be explicitly reauthenticated with saved credentials',
    () async {
      source.data['account'] = ['alice', 'secret'];
      source.account = account(verify: () async => false);
      expect((await auth.verify()).code, 'authentication_required');
      expect(SourceAuth.describe(source)['state'], 'expired');
      source.account = account(verify: () async => true);
      expect((await auth.reauthenticate()).exitCode, 0);
      expect(SourceAuth.describe(source)['state'], 'authenticated');
    },
  );

  test(
    'cookies and GUI-only sources advertise and enforce their capabilities',
    () async {
      source.account = AccountConfig(null, null, null, () {}, null, null, [
        'session',
      ], (c) async => c.single == 'cookie');
      expect(
        (await auth.login(
          SourceCredentials.parse({
            'cookies': ['cookie'],
          }),
        )).exitCode,
        0,
      );
      expect(source.data['account'], 'ok');
      expect(
        (await cliGuard(auth.reauthenticate)).code,
        'credentials_required',
      );
      source.account = AccountConfig(
        null,
        'https://example.invalid',
        null,
        () {},
        null,
        null,
        null,
        null,
      );
      expect(
        (await cliGuard(() => auth.login(credentials(), replace: true))).code,
        'interaction_required',
      );
    },
  );

  test(
    'credentials files are bounded, private and regular; failures never echo JSON',
    () async {
      final file = File('${temp.path}/credentials.json');
      await file.writeAsString('{"username":"alice","password":"secret"}');
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }
      final request = CliRequest.parse([
        'sources',
        'login',
        'fixture',
        '--credentials-file',
        file.path,
      ]);
      expect(
        (await SourceCredentials.read(request, control)).username,
        'alice',
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', ['644', file.path]);
        await expectLater(
          SourceCredentials.read(request, control),
          throwsA(
            isA<CliException>().having(
              (e) => e.code,
              'code',
              'insecure_credentials',
            ),
          ),
        );
        await Process.run('chmod', ['600', file.path]);
        final link = Link('${temp.path}/link');
        await link.create(file.path);
        await expectLater(
          SourceCredentials.read(
            CliRequest.parse([
              'sources',
              'login',
              'fixture',
              '--credentials-file',
              link.path,
            ]),
            control,
          ),
          throwsA(isA<CliException>()),
        );
      }
      await file.writeAsString('secret invalid JSON');
      final result = await cliGuard(() async {
        await SourceCredentials.read(request, control);
        return const CliResult(null);
      });
      expect(result.code, 'invalid_credentials');
      expect(result.message, isNot(contains('secret')));
      expect(
        () => SourceCredentials.parse({
          'username': 'a',
          'password': 'b',
          'extra': 'x',
        }),
        throwsA(isA<CliException>()),
      );
      expect(
        () => SourceCredentials.decode(
          List.filled(SourceCredentials.maxBytes + 1, 65),
        ),
        throwsA(isA<CliException>()),
      );
    },
  );
}

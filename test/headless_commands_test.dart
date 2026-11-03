import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/commands.dart';
import 'package:venera_netmatic/headless/jobs.dart';

class QuerySource implements ComicSource {
  QuerySource(this.searchPageData, {this.ready});
  final Completer<void>? ready;
  @override
  String get key => 'query-test';
  @override
  final SearchPageData? searchPageData;
  @override
  Future<void> ensureInitialized() async {
    await ready?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  Future<CliResult> run(List<String> args) => cliGuard(
    () => HeadlessCommands(
      CliRequest.parse(args),
      CliControl(),
      CliJobs(temp.path),
      (_) {},
    ).execute(),
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('headless-commands-');
    Log.isMuted = true;
  });
  tearDown(() async {
    ComicSourceManager().remove('query-test');
    await temp.delete(recursive: true);
  });

  test(
    'search waits for source initialization and returns page metadata',
    () async {
      final ready = Completer<void>();
      var called = false;
      ComicSourceManager().add(
        QuerySource(
          SearchPageData(null, (query, page, options) async {
            called = true;
            expect(query, '中文');
            expect(page, 2);
            expect(options, isEmpty);
            return Res([
              Comic(
                'Title',
                '',
                'id',
                null,
                null,
                '',
                'query-test',
                null,
                null,
              ),
            ], subData: 5);
          }, null),
          ready: ready,
        ),
      );
      final running = run(['search', 'query-test', '中文', '--page', '2']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(called, isFalse);
      ready.complete();
      final result = await running;
      expect(result.exitCode, 0);
      expect((result.data as Map)['maxPage'], 5);
      expect((result.data as Map)['items'], hasLength(1));
    },
  );

  test(
    'cursor searches preserve opaque cursors and reject page mode',
    () async {
      ComicSourceManager().add(
        QuerySource(
          SearchPageData(null, null, (q, cursor, options) async {
            expect(cursor, 'opaque');
            return const Res(<Comic>[], subData: 'next');
          }),
        ),
      );
      final result = await run([
        'search',
        'query-test',
        'q',
        '--cursor',
        'opaque',
      ]);
      expect((result.data as Map)['nextCursor'], 'next');
      expect(
        (await run(['search', 'query-test', 'q', '--page', '2'])).exitCode,
        2,
      );
    },
  );

  test('source failures become error results', () async {
    ComicSourceManager().add(
      QuerySource(
        SearchPageData(
          null,
          (q, page, options) async => const Res.error('offline'),
          null,
        ),
      ),
    );
    final result = await run(['search', 'query-test', 'q']);
    expect(result.exitCode, 1);
    expect(result.code, 'source_error');
  });

  test('unconfigured WebDAV cannot claim upload success', () async {
    final previous = appdata.settings['webdav'];
    try {
      appdata.settings['webdav'] = [];
      final result = await run(['webdav', 'up']);
      expect(result.exitCode, 1);
      expect(result.code, 'not_configured');
    } finally {
      appdata.settings['webdav'] = previous;
    }
  });

  test('NAS query does not expose passwords or usernames', () async {
    final previous = appdata.settings['nasConnections'];
    try {
      appdata.settings['nasConnections'] = [
        {
          'id': 'nas',
          'name': 'NAS',
          'protocol': 'webdav',
          'host': 'https://private.invalid',
          'username': 'private-user',
          'password': 'private-secret',
        },
      ];
      final result = await run(['nas', 'list']);
      expect(result.exitCode, 0);
      expect(result.data.toString(), isNot(contains('private-secret')));
      expect(result.data.toString(), isNot(contains('private-user')));
      expect(result.data.toString(), contains('nas'));
    } finally {
      appdata.settings['nasConnections'] = previous;
    }
  });
  test('cancelling search interrupts pending source initialization', () async {
    final ready = Completer<void>();
    var searched = false;
    ComicSourceManager().add(
      QuerySource(
        SearchPageData(null, (q, p, o) async {
          searched = true;
          return const Res(<Comic>[]);
        }, null),
        ready: ready,
      ),
    );
    final control = CliControl();
    final operation = cliGuard(
      () => HeadlessCommands(
        CliRequest.parse(['search', 'query-test', 'q']),
        control,
        CliJobs(temp.path),
        (_) {},
      ).execute(),
    );
    control.cancelled = true;
    final result = await operation;
    expect(result.code, 'cancelled');
    expect(searched, isFalse);
    ready.complete();
  });
}

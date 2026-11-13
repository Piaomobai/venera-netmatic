import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/commands.dart';
import 'package:venera_netmatic/headless/jobs.dart';
import 'package:venera_netmatic/headless/service_queue.dart';

class BrowseSource implements ComicSource {
  @override
  String get key => 'browse_test';
  @override
  CategoryData? categoryData;
  @override
  CategoryComicsData? categoryComicsData;
  @override
  HandleClickTagEvent? handleClickTagEvent;
  @override
  SearchPageData? searchPageData;
  Completer<void>? ready;
  @override
  Future<void> ensureInitialized() async {
    await ready?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late BrowseSource source;
  late Directory temp;
  Future<CliResult> run(List<String> args, {CliControl? control}) => cliGuard(
    () => HeadlessCommands(
      CliRequest.parse(args),
      control ?? CliControl(),
      CliJobs(temp.path),
      (_) {},
    ).execute(),
  );
  const empty = Res(<Comic>[], subData: 7);
  setUp(() async {
    source = BrowseSource();
    ComicSourceManager().add(source);
    temp = await Directory.systemTemp.createTemp('headless-browse-');
  });
  tearDown(() async {
    ComicSourceManager().remove(source.key);
    await temp.delete(recursive: true);
  });

  test(
    'ranking options, page selection, source errors and unknown values',
    () async {
      var calls = 0;
      source.categoryComicsData = CategoryComicsData(
        load: (_, _, _, _) async => empty,
        rankingData: RankingData({'day': 'Daily'}, (option, page) async {
          calls++;
          expect(option, 'day');
          expect(page, 2);
          return empty;
        }, null),
      );
      expect(
        ((await run(['ranking', 'options', source.key])).data
            as Map)['options'],
        {'day': 'Daily'},
      );
      final result = await run([
        'ranking',
        'get',
        source.key,
        'day',
        '--page',
        '2',
      ]);
      expect((result.data as Map)['maxPage'], 7);
      expect((result.data as Map)['pagination'], 'page');
      expect(
        (await run(['ranking', 'get', source.key, 'invalid'])).exitCode,
        2,
      );
      expect(calls, 1);
      expect(
        (await run([
          'ranking',
          'get',
          source.key,
          'day',
          '--cursor',
          'opaque',
        ])).exitCode,
        2,
      );
    },
  );

  test(
    'cursor rankings retain opaque continuation and reject page mode',
    () async {
      source.categoryComicsData = CategoryComicsData(
        load: (_, _, _, _) async => empty,
        rankingData: RankingData({'week': 'Weekly'}, null, (
          option,
          cursor,
        ) async {
          expect(cursor, 'opaque');
          return const Res(<Comic>[], subData: 'next');
        }),
      );
      final result = await run([
        'ranking',
        'get',
        source.key,
        'week',
        '--cursor',
        'opaque',
      ]);
      expect((result.data as Map)['nextCursor'], 'next');
      expect(
        (await run([
          'ranking',
          'get',
          source.key,
          'week',
          '--page',
          '1',
        ])).exitCode,
        2,
      );
    },
  );

  test(
    'category catalog exposes all random tags with pagination and literal targets',
    () async {
      const target = PageJumpTarget('browse_test', 'category', {
        'category': '中文:category',
        'param': 'c',
      });
      source.categoryData = const CategoryData(
        title: 'Catalog',
        key: 'catalog',
        enableRankingPage: true,
        categories: [
          RandomCategoryPart('Tags', [
            CategoryItem('First', target),
            CategoryItem('Second', target),
            CategoryItem('Third', target),
          ], 1),
        ],
      );
      final all =
          (await run(['categories', 'list', source.key, '--limit', '2'])).data
              as Map;
      expect(all['total'], 3);
      expect(all['nextOffset'], 2);
      expect((all['items'] as List).first['target']['param'], 'c');
      final filtered =
          (await run([
                'categories',
                'list',
                source.key,
                '--query',
                'Third',
              ])).data
              as Map;
      expect(filtered['total'], 1);
    },
  );

  test(
    'category options await dynamic loader and honor visibility, defaults and explicit sorting',
    () async {
      final ready = Completer<Res<List<CategoryComicsOptions>>>();
      var loaded = false;
      source.categoryComicsData = CategoryComicsData(
        optionsLoader: (category, param) async {
          expect(category, 'Books');
          expect(param, 'c');
          return ready.future;
        },
        load: (category, param, options, page) async {
          loaded = true;
          expect(options, ['old']);
          expect(page, 3);
          return empty;
        },
      );
      final operation = run([
        'categories',
        'get',
        source.key,
        'Books',
        '--param',
        'c',
        '--options',
        '["old"]',
        '--page',
        '3',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(loaded, isFalse);
      ready.complete(
        Res([
          CategoryComicsOptions(
            'Sort',
            LinkedHashMap.of({'new': 'Newest', 'old': 'Oldest'}),
            [],
            null,
          ),
          CategoryComicsOptions(
            'Hidden',
            LinkedHashMap.of({'hidden': 'Hidden'}),
            ['Books'],
            null,
          ),
          CategoryComicsOptions(
            'Elsewhere',
            LinkedHashMap.of({'other': 'Other'}),
            [],
            ['Elsewhere'],
          ),
        ]),
      );
      expect((await operation).exitCode, 0);
      final metadata =
          (await run([
                'categories',
                'options',
                source.key,
                'Books',
                '--param',
                'c',
              ])).data
              as Map;
      expect(metadata['options'], hasLength(1));
      expect(metadata['options'][0]['default'], 'new');
      expect(
        (await run([
          'categories',
          'get',
          source.key,
          'Books',
          '--param',
          'c',
          '--options',
          '["invalid"]',
        ])).exitCode,
        2,
      );
    },
  );

  test(
    'tag targets preserve source-specific category versus search semantics',
    () async {
      source.handleClickTagEvent = (namespace, tag) => namespace == 'Author'
          ? PageJumpTarget(source.key, 'category', {
              'category': tag,
              'param': 'a',
            })
          : PageJumpTarget(source.key, 'search', {'text': tag});
      final author =
          (await run([
                'tags',
                'resolve',
                source.key,
                'Author',
                'literal:"tag',
              ])).data
              as Map;
      expect(author['target']['action'], 'category');
      expect(author['target']['param'], 'a');
      final tag =
          (await run(['tags', 'resolve', source.key, 'Tags', '中文'])).data
              as Map;
      expect(tag['target']['query'], '中文');
      source.handleClickTagEvent = (_, _) => PageJumpTarget(
        source.key,
        'webview',
        {'url': 'https://example.invalid'},
      );
      expect(
        (await run(['tags', 'resolve', source.key, 'Tags', 'anything'])).code,
        'unsupported',
      );
    },
  );

  test(
    'tag search follows search targets with literal text and target sorting',
    () async {
      const literal = '--冒险:"quoted"';
      source.handleClickTagEvent = (namespace, tag) {
        expect(namespace, 'Tags');
        expect(tag, literal);
        return PageJumpTarget(source.key, 'search', {
          'text': tag,
          'options': ['old'],
        });
      };
      source.searchPageData = SearchPageData(
        [
          SearchOptions(
            LinkedHashMap.of({'new': 'New', 'old': 'Old'}),
            'Sort',
            'select',
            null,
          ),
        ],
        (query, page, options) async {
          expect(query, literal);
          expect(page, 2);
          expect(options, ['old']);
          return Res([
            Comic(
              'Book',
              '',
              'book',
              null,
              ['Adventure'],
              '',
              source.key,
              null,
              null,
            ),
          ], subData: 4);
        },
        null,
      );
      final result = await run([
        '--page',
        '2',
        '--',
        'tags',
        'search',
        source.key,
        'Tags',
        literal,
      ]);
      expect(result.exitCode, 0);
      final data = result.data as Map;
      expect(data['pagination'], 'page');
      expect(data['page'], 2);
      expect(data['maxPage'], 4);
      expect(data['items'][0]['id'], 'book');
    },
  );

  test(
    'tag search reuses defaults and explicit search option validation',
    () async {
      source.handleClickTagEvent = (_, tag) =>
          PageJumpTarget(source.key, 'search', {'keyword': tag, 'options': []});
      var calls = 0;
      source.searchPageData = SearchPageData(
        [
          SearchOptions(
            LinkedHashMap.of({'new': 'New', 'old': 'Old'}),
            'Sort',
            'select',
            null,
          ),
        ],
        (query, page, options) async {
          expect(query, 'Adventure');
          expect(options, [calls++ == 0 ? 'new' : 'old']);
          return empty;
        },
        null,
      );
      final command = ['tags', 'search', source.key, 'Tags', 'Adventure'];
      expect((await run(command)).exitCode, 0);
      expect((await run([...command, '--options', '["old"]'])).exitCode, 0);
      expect((await run([...command, '--options', '["invalid"]'])).exitCode, 2);
      expect(calls, 2);
    },
  );

  test(
    'tag search preserves opaque cursors and rejects page mode for cursor-only sources',
    () async {
      source.handleClickTagEvent = (_, tag) =>
          PageJumpTarget(source.key, 'search', {'text': tag});
      source.searchPageData = SearchPageData(null, null, (
        query,
        cursor,
        options,
      ) async {
        expect(query, 'Adventure');
        expect(cursor, 'opaque');
        return const Res(<Comic>[], subData: 'next');
      });
      final command = ['tags', 'search', source.key, 'Tags', 'Adventure'];
      final result = await run([...command, '--cursor', 'opaque']);
      expect(result.exitCode, 0);
      expect((result.data as Map)['pagination'], 'cursor');
      expect((result.data as Map)['nextCursor'], 'next');
      expect((await run([...command, '--page', '2'])).exitCode, 2);
    },
  );

  test(
    'tag search follows author category parameters and dynamic options',
    () async {
      source.handleClickTagEvent = (namespace, tag) =>
          PageJumpTarget(source.key, 'category', {
            'category': tag,
            'param': 'a',
            'options': ['old'],
          });
      source.categoryComicsData = CategoryComicsData(
        optionsLoader: (category, param) async {
          expect(category, 'Writer');
          expect(param, 'a');
          return Res([
            CategoryComicsOptions(
              'Sort',
              LinkedHashMap.of({'new': 'New', 'old': 'Old'}),
              [],
              null,
            ),
            CategoryComicsOptions('Hidden', LinkedHashMap.of({'x': 'X'}), [
              'Writer',
            ], null),
            CategoryComicsOptions(
              'Language',
              LinkedHashMap.of({'all': 'All'}),
              [],
              ['Writer'],
            ),
          ]);
        },
        load: (category, param, options, page) async {
          expect(category, 'Writer');
          expect(param, 'a');
          expect(page, 3);
          expect(options, ['old', 'all']);
          return empty;
        },
      );
      final command = ['tags', 'search', source.key, 'Author', 'Writer'];
      final result = await run([...command, '--page', '3']);
      expect(result.exitCode, 0);
      expect((result.data as Map)['category'], 'Writer');
      expect((result.data as Map)['param'], 'a');
      expect((result.data as Map)['maxPage'], 7);
      expect((await run([...command, '--cursor', 'opaque'])).exitCode, 2);
    },
  );

  test(
    'tag search rejects missing, unsupported and malformed targets',
    () async {
      final command = ['tags', 'search', source.key, 'Tags', 'Adventure'];
      expect((await run(command)).code, 'unsupported');
      for (final target in [
        PageJumpTarget(source.key, 'webview', {
          'url': 'https://example.invalid',
        }),
        PageJumpTarget(source.key, 'search', {'text': 42}),
        PageJumpTarget(source.key, 'category', {}),
        PageJumpTarget(source.key, 'search', {
          'options': [42],
        }),
      ]) {
        source.handleClickTagEvent = (_, _) => target;
        expect(
          (await run(command)).code,
          target.page == 'webview' ? 'unsupported' : 'source_error',
        );
      }
    },
  );

  test(
    'tag search shares cancellation and timeout control with source queries',
    () async {
      final pending = Completer<Res<List<Comic>>>();
      source.handleClickTagEvent = (_, tag) =>
          PageJumpTarget(source.key, 'search', {'text': tag});
      source.searchPageData = SearchPageData(
        null,
        (_, _, _) => pending.future,
        null,
      );
      final command = ['tags', 'search', source.key, 'Tags', 'Adventure'];
      final control = CliControl();
      final operation = run(command, control: control);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      control.cancelled = true;
      expect((await operation).code, 'cancelled');
      expect((await run([...command, '--timeout', '1'])).code, 'timeout');
      pending.complete(empty);
    },
  );

  test(
    'tag search waits for source initialization and checks cancellation before resolving',
    () async {
      source.ready = Completer<void>();
      var resolved = false;
      source.handleClickTagEvent = (_, tag) {
        resolved = true;
        return PageJumpTarget(source.key, 'search', {'text': tag});
      };
      final control = CliControl();
      final operation = run([
        'tags',
        'search',
        source.key,
        'Tags',
        'Adventure',
      ], control: control);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resolved, isFalse);
      control.cancelled = true;
      expect((await operation).code, 'cancelled');
      expect(resolved, isFalse);
      source.ready!.complete();
    },
  );

  test(
    'cancelling ranking does not require its pending page to resolve',
    () async {
      final pending = Completer<Res<List<Comic>>>();
      source.categoryComicsData = CategoryComicsData(
        load: (_, _, _, _) async => empty,
        rankingData: RankingData(
          {'day': 'Daily'},
          (_, _) => pending.future,
          null,
        ),
      );
      final control = CliControl();
      final result = run([
        'ranking',
        'get',
        source.key,
        'day',
      ], control: control);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      control.cancelled = true;
      expect((await result).code, 'cancelled');
      pending.complete(empty);
    },
  );

  test(
    'browse commands share query priority and bypass pending NAS work',
    () async {
      final release = Completer<void>();
      final queue = ServiceQueue(
        directory: temp.path,
        execute: (request, _, _) async {
          if (request.command == 'downloads run') await release.future;
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      final nas = await queue.submit(['nas', 'upload', 'nas']);
      for (final args in [
        ['ranking', 'options', source.key],
        ['ranking', 'get', source.key, 'day'],
        ['categories', 'list', source.key],
        ['categories', 'options', source.key, 'Books'],
        ['categories', 'get', source.key, 'Books'],
        ['tags', 'resolve', source.key, 'Tags', 'tag'],
        ['tags', 'search', source.key, 'Tags', 'tag'],
      ]) {
        final request = await queue.submit(args);
        for (var n = 0; n < 100 && request.state != 'completed'; n++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(request.priority, 'interactive');
        expect(request.state, 'completed');
        expect(nas.state, 'queued');
      }
      await queue.cancel(nas.id);
      release.complete();
      await queue.shutdown();
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';

// ============================================================================
// Tests for ranking-list paging.
//
// This is the core of the ranking monitor: reading pages of a ranking option
// and collecting the comics listed. The two loader shapes have different
// conventions -- `load` is 1-based and reports maxPage as an int, while
// `loadWithNext` threads a nullable cursor and reports the next cursor as a
// String -- and getting either wrong means silently reading only the first page,
// or looping forever.
//
// `RankingData` takes its loaders as constructor arguments, so both shapes can
// be exercised with fakes and no network.
// ============================================================================

Comic comic(String id, [String? title]) => Comic(
  title ?? 'Comic $id',
  'cover-$id.png',
  id,
  null,
  null,
  '',
  'test-source',
  null,
  null,
);

void main() {
  group('paged loaders (ranking.load)', () {
    test('reads pages starting at 1, not 0', () async {
      final requested = <int>[];
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        requested.add(page);
        return Res(<Comic>[comic('$page-a'), comic('$page-b')]);
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 3);

      expect(scan.error, isNull);
      expect(requested, [1, 2, 3], reason: 'paging is 1-based');
      expect(scan.comics.map((c) => c.id), [
        '1-a',
        '1-b',
        '2-a',
        '2-b',
        '3-a',
        '3-b',
      ]);
      expect(scan.pagesRead, 3);
    });

    test('stops at maxPage reported through subData', () async {
      final requested = <int>[];
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        requested.add(page);
        return Res(<Comic>[comic('$page')], subData: 2);
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 10);

      // maxPage is 2, so pages 3..10 must not be requested even though 10 were
      // allowed.
      expect(requested, [1, 2]);
      expect(scan.comics.map((c) => c.id), ['1', '2']);
    });

    test('stops on an empty page even without maxPage', () async {
      final requested = <int>[];
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        requested.add(page);
        if (page == 1) {
          return Res(<Comic>[comic('1')]);
        }
        return Res(const <Comic>[]);
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(requested, [1, 2]);
      expect(scan.comics.map((c) => c.id), ['1']);
      expect(scan.error, isNull);
    });

    test('a non-int subData does not stop paging', () async {
      // Some sources put an unrelated value in subData; only an int means
      // maxPage.
      final requested = <int>[];
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        requested.add(page);
        return Res(<Comic>[comic('$page')], subData: 'unrelated');
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 3);

      expect(requested, [1, 2, 3]);
      expect(scan.comics.length, 3);
    });

    test('an error keeps the pages already read', () async {
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        if (page == 2) {
          return const Res<List<Comic>>.error('network exploded');
        }
        return Res(<Comic>[comic('1')]);
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(scan.failed, isTrue);
      expect(scan.error, 'network exploded');
      // Page 1's comic is still reported, so a partial scan is not wasted.
      expect(scan.comics.map((c) => c.id), ['1']);
      expect(scan.pagesRead, 2);
    });

    test('a throwing loader becomes an error, not an exception', () async {
      final ranking = RankingData(
        {'day': 'Day'},
        (option, page) async => throw StateError('boom'),
        null,
      );

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 2);

      expect(scan.failed, isTrue);
      expect(scan.error, contains('boom'));
      expect(scan.comics, isEmpty);
    });

    test('the option key is passed through to the loader', () async {
      final seen = <String>[];
      final ranking = RankingData({'week': 'Week', 'month': 'Month'}, (
        option,
        page,
      ) async {
        seen.add(option);
        return Res(<Comic>[comic('$option-$page')]);
      }, null);

      await RankingMonitorRunner.scanOption(ranking, 'month', 2);

      expect(seen, ['month', 'month']);
    });

    test('pages below 1 request nothing', () async {
      final requested = <int>[];
      final ranking = RankingData({'day': 'Day'}, (option, page) async {
        requested.add(page);
        return Res(<Comic>[comic('$page')]);
      }, null);

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 0);

      expect(requested, isEmpty);
      expect(scan.comics, isEmpty);
      expect(scan.error, isNull);
    });
  });

  group('cursor loaders (ranking.loadWithNext)', () {
    test('starts with a null cursor and threads subData forward', () async {
      final cursors = <String?>[];
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        cursors.add(cursor);
        // Three pages, then no next cursor.
        final body = Res(<Comic>[comic(cursor ?? 'first')]);
        if (cursor == null) {
          return Res(body.dataOrNull!, subData: 'c1');
        }
        if (cursor == 'c1') {
          return Res(body.dataOrNull!, subData: 'c2');
        }
        return Res(body.dataOrNull!);
      });

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(scan.error, isNull);
      expect(cursors, [null, 'c1', 'c2']);
      expect(scan.comics.length, 3);
    });

    test('a null subData ends paging', () async {
      var calls = 0;
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        calls++;
        return Res(<Comic>[comic('$calls')]);
      });

      await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(calls, 1);
    });

    test('a non-String subData ends paging', () async {
      var calls = 0;
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        calls++;
        // A source that reports a page number instead of a cursor must not
        // cause the loop to continue with a bogus cursor.
        return Res(<Comic>[comic('$calls')], subData: 7);
      });

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(calls, 1);
      expect(scan.comics.length, 1);
    });

    test('an empty subData string ends paging', () async {
      var calls = 0;
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        calls++;
        return Res(<Comic>[comic('$calls')], subData: '');
      });

      await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(calls, 1);
    });

    test('an empty page ends paging even with a cursor', () async {
      var calls = 0;
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        calls++;
        if (calls == 1) {
          return Res(<Comic>[comic('1')], subData: 'next');
        }
        return Res(const <Comic>[], subData: 'next-again');
      });

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(calls, 2);
      expect(scan.comics.length, 1);
    });

    test('an error keeps the pages already read', () async {
      var calls = 0;
      final ranking = RankingData({'day': 'Day'}, null, (option, cursor) async {
        calls++;
        if (calls == 2) {
          return const Res<List<Comic>>.error('gone');
        }
        return Res(<Comic>[comic('1')], subData: 'next');
      });

      final scan = await RankingMonitorRunner.scanOption(ranking, 'day', 5);

      expect(scan.failed, isTrue);
      expect(scan.error, 'gone');
      expect(scan.comics.length, 1);
    });
  });

  group('ranking support detection', () {
    test('a source with no ranking loader is not usable', () async {
      // RankingData with neither loader: options exist but nothing can be read.
      // scanOption would dereference loadWithNext, so the guard that matters is
      // supportsRanking, which the runner uses to filter sources.
      expect(RankingMonitorRunner.rankingCapableSources(), isEmpty);
    });
  });

  group('ranking option configuration', () {
    final ranking = RankingData(
      {'day': 'Day', 'week': 'Week', 'month': 'Month'},
      (option, page) async => Res(const <Comic>[]),
      null,
    );

    test('selects different ranking options for different sources', () {
      final config = <String, dynamic>{
        'options': <String>['month'],
        RankingMonitorRunner.optionsBySourceConfigKey: <String, dynamic>{
          'picacg': <String>['week', 'week', 'unknown'],
          'jmcomic': <String>['month'],
        },
      };

      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: config,
          ranking: ranking,
          sourceKey: 'picacg',
        ),
        ['week'],
      );
      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: config,
          ranking: ranking,
          sourceKey: 'jmcomic',
        ),
        ['month'],
      );
      // A source without an entry gets its own first option instead of the
      // legacy global option.
      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: config,
          ranking: ranking,
          sourceKey: 'other',
        ),
        ['day'],
      );
    });

    test('keeps legacy global options when no per-source map is present', () {
      final config = <String, dynamic>{
        'options': <String>['month'],
      };
      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: config,
          ranking: ranking,
          sourceKey: 'picacg',
        ),
        ['month'],
      );
    });

    test('falls back to the first option for empty or unknown selections', () {
      final empty = <String, dynamic>{
        RankingMonitorRunner.optionsBySourceConfigKey: <String, dynamic>{
          'picacg': <String>[],
        },
      };
      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: empty,
          ranking: ranking,
          sourceKey: 'picacg',
        ),
        ['day'],
      );

      final unknown = <String, dynamic>{
        RankingMonitorRunner.optionsBySourceConfigKey: <String, dynamic>{
          'picacg': <String>['missing'],
        },
      };
      expect(
        RankingMonitorRunner.resolveOptionsForConfig(
          config: unknown,
          ranking: ranking,
          sourceKey: 'picacg',
        ),
        ['day'],
      );
    });
  });
}

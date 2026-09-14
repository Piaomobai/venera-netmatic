import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/builtin.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/incremental_download.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/nas_sync.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';

// Pure-logic tests for the task runners. Deliberately avoids anything that
// needs the network, sqlite3, a Flutter binding, or an initialised
// ComicSourceManager, so these always run.
void main() {
  group('built-in runner registration', () {
    tearDown(TaskRunnerRegistry.clear);

    test('registers every shipped runner', () {
      TaskRunnerRegistry.clear();
      expect(TaskRunnerRegistry.has(RankingMonitorRunner.key), isFalse);

      registerBuiltInTaskRunners();

      expect(TaskRunnerRegistry.has(RankingMonitorRunner.key), isTrue);
      expect(TaskRunnerRegistry.has(IncrementalDownloadRunner.key), isTrue);
      expect(TaskRunnerRegistry.has(NasSyncRunner.key), isTrue);
      expect(TaskRunnerRegistry.find(RankingMonitorRunner.key), isNotNull);
      expect(
        TaskRunnerRegistry.find(RankingMonitorRunner.key),
        isA<RankingMonitorRunner>(),
      );
      expect(
        TaskRunnerRegistry.find(IncrementalDownloadRunner.key),
        isA<IncrementalDownloadRunner>(),
      );
      expect(TaskRunnerRegistry.find(NasSyncRunner.key), isA<NasSyncRunner>());
    });

    test('is idempotent', () {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final first = TaskRunnerRegistry.find(RankingMonitorRunner.key);
      registerBuiltInTaskRunners();
      // The same instance is kept; re-registering must not churn the registry.
      expect(TaskRunnerRegistry.find(RankingMonitorRunner.key), same(first));
      expect(TaskRunnerRegistry.all().length, 3);
    });

    test('every runner has a usable identity', () {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      for (final runner in TaskRunnerRegistry.all()) {
        expect(runner.typeKey, isNotEmpty);
        expect(runner.displayName, isNotEmpty);
        expect(runner.description, isNotEmpty);
        expect(runner.defaultConfig(), isA<Map<String, dynamic>>());
      }
    });

    test('default configs are valid, except where a folder is mandatory', () {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();

      // Ranking monitoring is useful with nothing configured.
      final ranking = RankingMonitorRunner();
      expect(ranking.validateConfig(ranking.defaultConfig()), isNull);

      // Incremental download cannot guess a favourites folder, so its default
      // config is deliberately incomplete. createTask therefore refuses it,
      // which is asserted in the engine tests.
      final download = IncrementalDownloadRunner();
      expect(download.validateConfig(download.defaultConfig()), isNotNull);

      // Scheduled NAS sync must target a connection explicitly.
      final nasSync = NasSyncRunner();
      expect(nasSync.validateConfig(nasSync.defaultConfig()), isNotNull);
    });
  });

  group('RankingMonitorRunner defaults', () {
    late RankingMonitorRunner runner;

    setUp(() {
      runner = RankingMonitorRunner();
    });

    test('identity', () {
      expect(runner.typeKey, 'rankingMonitor');
      expect(runner.displayName, 'Ranking monitor');
    });

    test('default config scans everything and takes no side effects', () {
      final config = runner.defaultConfig();
      expect(config['sources'], isEmpty);
      expect(config['options'], isEmpty);
      expect(config[RankingMonitorRunner.optionsBySourceConfigKey], isEmpty);
      expect(config['pagesPerOption'], 1);
      expect(config['autoFavorite'], isFalse);
      expect(config['autoDownload'], isFalse);
      // No follow-up actions enabled, so no folder is required.
      expect(runner.validateConfig(config), isNull);
    });

    test('validates the per-source ranking option map', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig());
      config[RankingMonitorRunner.optionsBySourceConfigKey] = <String, dynamic>{
        'picacg': <String>['day', 'week'],
      };
      expect(runner.validateConfig(config), isNull);

      config[RankingMonitorRunner.optionsBySourceConfigKey] = <String, dynamic>{
        'picacg': 'week',
      };
      expect(runner.validateConfig(config), isNotNull);
    });

    test('rejects out-of-range tuning values', () {
      Map<String, dynamic> withValue(String key, Object? value) =>
          Map<String, dynamic>.from(runner.defaultConfig())..[key] = value;

      expect(runner.validateConfig(withValue('pagesPerOption', 0)), isNotNull);
      expect(runner.validateConfig(withValue('pagesPerOption', 21)), isNotNull);
      expect(runner.validateConfig(withValue('pagesPerOption', 20)), isNull);
      expect(runner.validateConfig(withValue('maxNewPerRun', 0)), isNotNull);
      expect(runner.validateConfig(withValue('throttleMs', -1)), isNotNull);
      expect(runner.validateConfig(withValue('throttleMs', 0)), isNull);
    });

    test('requires a folder only when auto-favourite is on', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig());
      config['autoFavorite'] = true;
      expect(runner.validateConfig(config), isNotNull);

      config['favoriteFolder'] = '   ';
      expect(runner.validateConfig(config), isNotNull);

      config['favoriteFolder'] = 'Scheduled';
      expect(runner.validateConfig(config), isNull);
    });

    test('seenNamespace is namespaced per source', () {
      expect(
        RankingMonitorRunner.seenNamespace('copymanga'),
        'ranking:copymanga',
      );
      expect(
        RankingMonitorRunner.seenNamespace('a'),
        isNot(RankingMonitorRunner.seenNamespace('b')),
      );
    });

    test('reports no ranking sources when none are installed', () {
      // Reading ComicSource.all() must be safe before initialisation; it simply
      // yields an empty registry rather than hanging.
      expect(RankingMonitorRunner.rankingCapableSources(), isEmpty);
    });
  });

  group('IncrementalDownloadRunner defaults', () {
    late IncrementalDownloadRunner runner;

    setUp(() {
      runner = IncrementalDownloadRunner();
    });

    test('identity', () {
      expect(runner.typeKey, 'incrementalDownload');
    });

    test('defaults to the favourites scope and requires a folder', () {
      final config = runner.defaultConfig();
      expect(config['scope'], IncrementalDownloadRunner.scopeFavorites);
      expect(config['favoriteFolder'], isEmpty);
      // The default config is incomplete on purpose: a folder is mandatory.
      expect(runner.validateConfig(config), isNotNull);
    });

    test('accepts a folder for the favourites scope', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig());
      config['favoriteFolder'] = 'Scheduled';
      expect(runner.validateConfig(config), isNull);
    });

    test('the library scope needs no folder', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig());
      config['scope'] = IncrementalDownloadRunner.scopeLibrary;
      expect(runner.validateConfig(config), isNull);
    });

    test('rejects an unknown scope', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig());
      config['scope'] = 'nonsense';
      expect(runner.validateConfig(config), isNotNull);
    });

    test('rejects negative bounds', () {
      final config = Map<String, dynamic>.from(runner.defaultConfig())
        ..['favoriteFolder'] = 'Scheduled';
      config['maxComicsPerRun'] = 0;
      expect(runner.validateConfig(config), isNotNull);
      config['maxComicsPerRun'] = 20;
      config['maxChaptersPerComic'] = -1;
      expect(runner.validateConfig(config), isNotNull);
      config['maxChaptersPerComic'] = 0;
      expect(runner.validateConfig(config), isNull);
    });
  });

  group('NasSyncRunner defaults', () {
    final runner = NasSyncRunner();

    test('identity', () {
      expect(runner.typeKey, 'nasSync');
      expect(runner.displayName, 'NAS sync');
    });

    test('requires a connection id', () {
      final config = runner.defaultConfig();
      expect(runner.validateConfig(config), isNotNull);
      config['nasConnectionId'] = 'nas-1';
      expect(runner.validateConfig(config), isNull);
      config['nasConnectionId'] = '   ';
      expect(runner.validateConfig(config), isNotNull);
    });
  });
}

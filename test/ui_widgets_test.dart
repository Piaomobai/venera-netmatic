import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/foundation/scheduler/store.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/builtin.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';
import 'package:venera_netmatic/pages/local_comics_page.dart';
import 'package:venera_netmatic/pages/scheduler/scheduler_home_card.dart';
import 'package:venera_netmatic/pages/scheduler/scheduler_page.dart';
import 'package:venera_netmatic/pages/scheduler/task_editor_page.dart';
import 'package:venera_netmatic/pages/storage_manager_page.dart';
// Re-exports dart:io and dart:typed_data, and supplies Directory.joinFile.
import 'package:venera_netmatic/utils/io.dart';
import 'package:venera_netmatic/utils/translations.dart';

// ============================================================================
// Widget tests for the scheduler and storage UI.
//
// These render the real widget tree on the host, which is the only way to
// exercise layout and runtime widget behaviour without building for Windows.
// `flutter analyze` proves the files parse and type-check; it cannot catch a
// LateInitializationError inside build(), a missing required parameter at
// runtime, or an assertion thrown during layout. These tests can.
//
// They deliberately avoid anything that needs a platform channel:
// path_provider, the QuickJS comic-source runtime, and the file dialogs are all
// unreachable here, so the pages are exercised in their "nothing configured
// yet" state, which is also the state every user starts in.
// ============================================================================

late Directory _tempDirectory;

int _dbCounter = 0;

String _nextDbPath() {
  _dbCounter++;
  return '${_tempDirectory.path}/ui_test_$_dbCounter.db';
}

/// `.tl` reads a `static late final` map. Assigning it here avoids depending on
/// asset loading, and an unknown locale falls back to the source string anyway.
void _installTranslations() {
  AppTranslation.translations = {
    'zh_CN': <String, String>{},
    'zh_TW': <String, String>{},
  };
}

/// A tall test surface so a whole page fits without scrolling.
///
/// This matters: widgets below the fold are still *built* but are marked
/// offstage, and `find.byKey` / `find.text` skip offstage widgets by default.
/// With the default 800x600 surface, a page's save button exists in the element
/// tree yet every finder reports "found 0 widgets", which looks like a missing
/// widget rather than a below-the-fold one.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Pumps [child] inside a MaterialApp.
Future<void> pumpPage(WidgetTester tester, Widget child) async {
  useTallSurface(tester);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    _tempDirectory = Directory.systemTemp.createTempSync('venera_ui_test');
    _installTranslations();
  });

  tearDownAll(() {
    SchedulerEngine().close();
    SchedulerStore().close();
    if (_tempDirectory.existsSync()) {
      try {
        _tempDirectory.deleteSync(recursive: true);
      } catch (_) {
        // A leaked temp directory is not worth failing the suite over.
      }
    }
  });

  group('SchedulerPage', () {
    tearDown(() => SchedulerEngine().close());

    testWidgets('renders the empty state when the engine is not started',
        (tester) async {
      TaskRunnerRegistry.clear();
      await pumpPage(tester, const SchedulerPage());

      // Title, the not-started warning, and the empty-state copy.
      expect(find.text('Scheduled Tasks'), findsOneWidget);
      expect(
        find.text(
          'The scheduler is not running. It starts automatically with the app.',
        ),
        findsOneWidget,
      );
      expect(find.text('No scheduled tasks yet'), findsOneWidget);
      expect(find.text('New Task'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists a configured task with its schedule and state',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      final task = engine.createTask(
        typeKey: 'rankingMonitor',
        name: 'Nightly ranking scan',
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
      );
      expect(task, isNotNull, reason: 'task creation should succeed');

      await pumpPage(tester, const SchedulerPage());

      expect(find.text('Nightly ranking scan'), findsOneWidget);
      // The runner name and the schedule description share a single Text, so
      // match on substrings rather than the whole string.
      expect(find.textContaining('Ranking monitor'), findsOneWidget);
      expect(find.textContaining('Every day at 03:30'), findsOneWidget);
      // Never run yet, and no runner has executed.
      expect(find.text('Never run'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('TaskEditorPage', () {
    tearDown(() => SchedulerEngine().close());

    /// Pumps a host page with a button that pushes the editor via the app's own
    /// navigation, so that the editor's `context.pop(result)` has a route.
    Future<void> openEditor(WidgetTester tester,
        {TaskDefinition? existing}) async {
      useTallSurface(tester);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    context.to(() => TaskEditorPage(existing: existing)),
                child: const Text('open editor'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open editor'));
      await tester.pumpAndSettle();
    }

    testWidgets('renders and creates an interval task with defaults',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      expect(find.text('New Task'), findsOneWidget);

      // The default schedule is a 30 minute interval, which is valid, and an
      // empty name falls back to the runner's display name.
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      expect(engine.tasks.length, 1);
      final created = engine.tasks.single;
      expect(created.schedule.type, ScheduleType.interval);
      expect(created.schedule.interval, const Duration(minutes: 30));
      expect(created.name, 'Ranking monitor');
      expect(created.enabled, isTrue);
    });

    testWidgets('refuses an interval below the five minute floor',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      await tester.enterText(
        find.byKey(const Key('field-intervalMinutes')),
        '2',
      );
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      expect(engine.tasks, isEmpty, reason: 'nothing should be created');
      expect(find.text('Please complete the schedule'), findsOneWidget);
    });

    testWidgets('creates a weekly task on the selected weekdays',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      await tester.tap(find.byKey(const Key('schedule-weekly')));
      await tester.pumpAndSettle();
      // Weekday chips are keyed by cron day number. Weekly starts with nothing
      // selected, so Wednesday is the only day.
      await tester.tap(find.byKey(const Key('weekday-3')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      expect(engine.tasks.length, 1);
      final schedule = engine.tasks.single.schedule;
      expect(schedule.type, ScheduleType.weekly);
      expect(schedule.weekdays, [3]);
      expect(schedule.asCron!.source, '0 3 * * 3');
    });

    testWidgets('weekly refuses to save until a day is selected',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      await tester.tap(find.byKey(const Key('schedule-weekly')));
      await tester.pumpAndSettle();
      // No weekday chip touched, so the schedule is incomplete.
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      expect(engine.tasks, isEmpty);
      expect(find.text('Please complete the schedule'), findsOneWidget);
    });

    testWidgets('surfaces a cron expression that can never fire',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      await tester.tap(find.byKey(const Key('schedule-cron')));
      await tester.pumpAndSettle();
      // February never has a 30th.
      await tester.enterText(find.byKey(const Key('field-cron')), '0 0 30 2 *');
      await tester.pumpAndSettle();

      expect(
        find.text('This expression never matches a date in the next 8 years.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      // The expression parses, so _buildSchedule succeeds; it is schedule
      // validation that rejects it, and the task must not be created.
      expect(engine.tasks, isEmpty);
      expect(
        find.text('This expression never matches a date in the next 8 years.'),
        findsWidgets,
      );
    });

    testWidgets('offers a run-on-start toggle, off by default', (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      expect(find.byKey(const Key('task-run-on-start')), findsOneWidget);
      expect(find.text('Run when the app starts'), findsOneWidget);

      // An untouched editor must not opt a new task into running on every
      // launch.
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();
      expect(engine.tasks.single.runOnStart, isFalse);
    });

    testWidgets('the run-on-start toggle is persisted when turned on',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      await openEditor(tester);
      await tester.tap(find.byKey(const Key('task-run-on-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();

      expect(engine.tasks.length, 1);
      expect(engine.tasks.single.runOnStart, isTrue);
      // And it survives a write/read cycle through the store.
      expect(SchedulerStore().loadTasks().single.runOnStart, isTrue);
    });

    testWidgets('can forget the comics a ranking task already remembers',
        (tester) async {
      TaskRunnerRegistry.clear();
      registerBuiltInTaskRunners();
      final engine = SchedulerEngine();
      await engine.init(databasePath: _nextDbPath(), startTimer: false);

      final created = engine.createTask(
        typeKey: RankingMonitorRunner.key,
        name: 'Ranking',
        schedule: ScheduleSpec.daily(hour: 12, minute: 0),
        config: const {
          'sources': ['picacg'],
          'autoDownload': true,
        },
      );
      expect(created, isNotNull);

      // What a scan that ran before auto-download was enabled leaves behind.
      final namespace = RankingMonitorRunner.seenNamespace('picacg');
      SchedulerStore().markSeen(namespace, 'comic-1');
      SchedulerStore().markSeen(namespace, 'comic-2');
      expect(SchedulerStore().countSeen(namespace), 2);

      await openEditor(tester, existing: created);
      expect(find.text('Remembered comics'), findsOneWidget);
      expect(find.textContaining('picacg: 2'), findsOneWidget);

      await tester.tap(find.text('Forget'));
      await tester.pump();
      // The toast this action shows owns a 2 s timer; expire it here so the
      // test does not finish with a pending timer.
      await tester.pump(const Duration(seconds: 3));

      expect(
        SchedulerStore().countSeen(namespace),
        0,
        reason: 'the next run has to treat the whole ranking as new again',
      );
      // The row reflects the reset immediately, without reopening the editor.
      expect(find.textContaining('picacg: 0'), findsOneWidget);
      // But saving the editor must not resurrect them.
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();
      expect(SchedulerStore().countSeen(namespace), 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('StorageManagerPage', () {
    testWidgets('renders without an initialised local library',
        (tester) async {
      // LocalManager is not initialised in tests, which is exactly the state
      // that used to throw a LateInitializationError from build().
      await pumpPage(tester, const StorageManagerPage());

      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('No downloaded comics yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // These catch a class of bug that neither `flutter analyze` nor the page tests
  // above can see: a widget returning a plain box is a perfectly valid Widget,
  // so it type-checks, but putting it in a `slivers:` list throws at layout time
  // with "A RenderViewport expected a child of type RenderSliver but received a
  // child of type RenderFlex". That is exactly what happened when these two
  // cards were first added to HomePage, and it was only found by running the
  // built Windows app.
  group('home cards must be slivers', () {
    setUp(() {
      // SchedulerEngine is a process-wide singleton and `close()` does not drop
      // the in-memory task list, so tasks created by earlier groups are still
      // present here. Clear them, otherwise this group's assertions depend on
      // test order -- which is exactly how it broke when a later editor test
      // started creating a task.
      final engine = SchedulerEngine();
      for (final task in engine.tasks) {
        engine.deleteTask(task.id);
      }
    });

    Future<void> pumpInSlivers(WidgetTester tester, Widget sliver) async {
      useTallSurface(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [sliver]),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('SchedulerHomeCard works inside a slivers list',
        (tester) async {
      await pumpInSlivers(tester, const SchedulerHomeCard());

      expect(tester.takeException(), isNull);
      expect(find.text('Scheduled Tasks'), findsOneWidget);
      expect(find.text('No scheduled tasks yet'), findsOneWidget);
    });

    testWidgets('StorageHomeCard works inside a slivers list', (tester) async {
      await pumpInSlivers(tester, const StorageHomeCard());

      expect(tester.takeException(), isNull);
      expect(find.text('Storage'), findsOneWidget);
    });
  });

  // Kept last: initialising LocalManager here would change the state the
  // StorageManagerPage test above observes.
  group('LocalComicsPage groups the library by source', () {
    var ready = false;
    late ComicType unknownSource;

    setUpAll(() async {
      App.dataPath = _tempDirectory.path;
      App.cachePath = _tempDirectory.path;
      // LocalManager.init() ends with ComicSourceManager().ensureInit(), which
      // never completes without a JS engine, so it is fire-and-forget here.
      // Opening local.db and resolving the library path both happen first.
      unawaited(LocalManager().init());
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        try {
          final path = LocalManager().path;
          if (path.isNotEmpty && Directory(path).existsSync()) {
            ready = true;
            break;
          }
        } catch (_) {
          // `path` is a late field; not assigned yet.
        }
      }
      if (!ready) {
        // ignore: avoid_print
        print('SKIPPED (local.db could not be opened in this environment)');
        return;
      }
      // A source that is not installed: its type resolves to no ComicSource, so
      // the group name falls back to `Source <n>` rather than throwing.
      unknownSource = ComicType.fromKey('not-installed-source');
      await _seed('e2e-a1', 'Alpha', 'local/Alpha', ComicType.local);
      await _seed('e2e-b2', 'Beta', 'local/Beta', ComicType.local);
      await _seed(
        'e2e-c3',
        'Gamma',
        'source/Gamma',
        unknownSource,
      );
    });

    testWidgets('renders one titled group per source, local last',
        (tester) async {
      if (!ready) {
        return;
      }
      await pumpPage(tester, const LocalComicsPage());

      // Two sources -> two group headers, named by the same function that names
      // the folders on disk.
      final localGroup = LocalManager.sourceFolderName(ComicType.local);
      final sourceGroup = LocalManager.sourceFolderName(unknownSource);
      expect(sourceGroup, startsWith('Source '));
      expect(find.text(localGroup), findsOneWidget);
      expect(find.text(sourceGroup), findsOneWidget);

      // Locally imported comics sort last.
      final sourceY = tester.getTopLeft(find.text(sourceGroup)).dy;
      final localY = tester.getTopLeft(find.text(localGroup)).dy;
      expect(sourceY, lessThan(localY),
          reason: 'the local group should come after named sources');

      // Group contents are covered precisely by the pure groupBySource tests;
      // asserting on tiles here would only re-test sliver laziness, since
      // SliverGridComics builds only the children inside the viewport.
    });

    // Regression: ComicTile reads comic.sourceKey, and ComicType.sourceKey
    // asserts comicSource!. A comic downloaded from a source that was later
    // uninstalled therefore crashed the whole local page. ComicType.local is
    // the only type whose sourceKey may be 'local'; every other type has to
    // fall back instead of asserting.
    test('a comic from an uninstalled source still reports a source key', () {
      if (!ready) {
        return;
      }
      LocalComic build(ComicType type) => LocalComic(
            id: 'orphan-1',
            title: 'Orphan',
            subtitle: '',
            tags: const [],
            directory: 'source/Orphan',
            chapters: null,
            cover: 'cover.png',
            comicType: type,
            downloadedChapters: const [],
            createdAt: DateTime(2025, 1, 1),
          );

      final orphan = build(unknownSource);
      expect(orphan.comicType.comicSource, isNull,
          reason: 'the source must genuinely be uninstalled');
      expect(orphan.sourceKey, 'Unknown:${unknownSource.value}');
      expect(
        LocalManager.sourceFolderName(orphan.comicType),
        startsWith('Source '),
      );

      // Locally imported comics keep their dedicated key.
      expect(build(ComicType.local).sourceKey, 'local');
    });
  });
}

/// Creates an on-disk comic under [relativeDirectory] and registers it, so the
/// local page has something real to render (including a loadable cover).
Future<void> _seed(
  String id,
  String title,
  String relativeDirectory,
  ComicType type,
) async {
  final dir = Directory('${LocalManager().path}/$relativeDirectory');
  dir.createSync(recursive: true);
  dir.joinFile('cover.png').writeAsBytesSync(_onePixelPng);
  await LocalManager().add(LocalComic(
    id: id,
    title: title,
    subtitle: '',
    tags: const [],
    directory: relativeDirectory,
    chapters: null,
    cover: 'cover.png',
    comicType: type,
    downloadedChapters: const [],
    createdAt: DateTime(2025, 1, 1),
  ));
}

/// A 1x1 transparent PNG, so cover loading succeeds instead of reporting an
/// image error that the test binding would surface as a failure.
final Uint8List _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

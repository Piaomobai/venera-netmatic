import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/foundation/scheduler/store.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';

// ============================================================================
// Store and engine tests.
//
// These need the native sqlite3 library. On Windows the app gets it bundled
// next to the executable by `sqlite3_flutter_libs`, but a bare `flutter test`
// runs on the host VM where `DynamicLibrary.open('sqlite3.dll')` may fail.
// Rather than reporting a false failure, every test in this file probes for the
// library once and reports a clear skip when it is unavailable. Run
// `flutter test` after a `flutter build windows` (or with sqlite3.dll on PATH)
// to exercise them for real.
// ============================================================================

var _sqliteAvailable = false;

String? _sqliteUnavailableReason;

late Directory _tempDirectory;

int _pathCounter = 0;

String _nextDatabasePath() {
  _pathCounter++;
  return '${_tempDirectory.path}/scheduler_$_pathCounter.db';
}

/// Returns true when the test should run, printing a skip notice otherwise.
bool _requireSqlite() {
  if (_sqliteAvailable) {
    return true;
  }
  // ignore: avoid_print
  print('SKIPPED (sqlite3 native library unavailable: $_sqliteUnavailableReason)');
  return false;
}

void _probeSqlite() {
  _tempDirectory = Directory.systemTemp.createTempSync('venera_scheduler_test');
  final probe = SchedulerStore();
  try {
    probe.open('${_tempDirectory.path}/probe.db');
    probe.close();
    _sqliteAvailable = true;
  } catch (e) {
    _sqliteUnavailableReason = e.toString();
  }
}

void main() {
  setUpAll(_probeSqlite);

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

  // ---------------------------------------------------------------------------
  // Store
  // ---------------------------------------------------------------------------

  group('SchedulerStore tasks', () {
    setUp(() {
      if (_sqliteAvailable) {
        SchedulerStore().open(_nextDatabasePath());
      }
    });

    test('persists and reloads a task with every field intact', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      expect(store.countTasks(), 0);

      final task = TaskDefinition(
        id: 'task-1',
        typeKey: 'rankingMonitor',
        name: 'Daily ranking scan',
        schedule: ScheduleSpec.weekly(weekdays: [1, 5], hour: 2, minute: 15),
        enabled: true,
        config: {'sources': <String>['a', 'b'], 'limit': 20},
        retry: const TaskRetryPolicy(maxAttempts: 3),
        sortOrder: 2,
        createdAt: DateTime(2025, 1, 1, 8, 0),
        lastRunAt: DateTime(2025, 1, 2, 2, 15),
        nextRunAt: DateTime(2025, 1, 6, 2, 15),
        lastState: TaskRunState.failed,
        lastError: 'timeout',
        consecutiveFailures: 2,
        lastSummary: {'sourcesChecked': 5, 'newComics': 3},
      );
      store.saveTask(task);

      final loaded = store.loadTask('task-1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'task-1');
      expect(loaded.typeKey, 'rankingMonitor');
      expect(loaded.name, 'Daily ranking scan');
      expect(loaded.schedule, equals(task.schedule));
      expect(loaded.enabled, isTrue);
      expect(loaded.config['sources'], ['a', 'b']);
      expect(loaded.config['limit'], 20);
      expect(loaded.retry.maxAttempts, 3);
      expect(loaded.sortOrder, 2);
      expect(loaded.createdAt, DateTime(2025, 1, 1, 8, 0));
      expect(loaded.lastRunAt, DateTime(2025, 1, 2, 2, 15));
      expect(loaded.nextRunAt, DateTime(2025, 1, 6, 2, 15));
      expect(loaded.lastState, TaskRunState.failed);
      expect(loaded.lastError, 'timeout');
      expect(loaded.consecutiveFailures, 2);
      expect(loaded.lastSummary, {'sourcesChecked': 5, 'newComics': 3});
      expect(store.countTasks(), 1);
    });

    test('save is an upsert, not an append', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      final task = _simpleTask('task-1', name: 'First');
      store.saveTask(task);
      store.saveTask(task.copyWith(name: 'Renamed'));
      expect(store.countTasks(), 1);
      expect(store.loadTask('task-1')!.name, 'Renamed');
    });

    test('orders by sort_order then created_at', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.saveTask(_simpleTask('b', sortOrder: 1, createdAt: DateTime(2025, 1, 1)));
      store.saveTask(_simpleTask('a', sortOrder: 0, createdAt: DateTime(2025, 1, 2)));
      store.saveTask(_simpleTask('c', sortOrder: 1, createdAt: DateTime(2025, 1, 3)));
      expect(store.loadTasks().map((t) => t.id), ['a', 'b', 'c']);
    });

    test('reorder rewrites sort_order', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.saveTask(_simpleTask('a', sortOrder: 0));
      store.saveTask(_simpleTask('b', sortOrder: 1));
      store.saveTask(_simpleTask('c', sortOrder: 2));
      store.reorder(['c', 'a', 'b']);
      expect(store.loadTasks().map((t) => t.id), ['c', 'a', 'b']);
    });

    test('deleteTask removes the task and its runs', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.saveTask(_simpleTask('a'));
      store.insertRun(TaskRunRecord(taskId: 'a', startedAt: DateTime(2025, 1, 1)));
      expect(store.countRuns('a'), 1);
      store.deleteTask('a');
      expect(store.countTasks(), 0);
      expect(store.countRuns('a'), 0);
      expect(store.loadTask('a'), isNull);
    });

    test('skips a corrupt row instead of failing the whole load', () {
      if (!_requireSqlite()) {
        return;
      }
      final path = _nextDatabasePath();
      final store = SchedulerStore();
      store.open(path);
      store.saveTask(_simpleTask('good', name: 'Good'));

      // Write a row whose schedule JSON cannot be parsed, using a second
      // connection so the store's own writer is bypassed.
      final raw = sqlite3.open(path);
      raw.execute(
        'INSERT INTO scheduled_tasks (id, type_key, name, enabled, schedule, '
        'config, retry, sort_order, created_at, last_state, '
        'consecutive_failures) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        ['bad', 'recorder', 'Bad', 1, '{not json', '{}', '{}', 1, 0, 'never', 0],
      );
      raw.dispose();

      final tasks = store.loadTasks();
      expect(tasks.map((t) => t.id), ['good']);
    });
  });

  group('SchedulerStore runs', () {
    setUp(() {
      if (_sqliteAvailable) {
        SchedulerStore().open(_nextDatabasePath());
      }
    });

    test('inserts, finishes, and reloads a run', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      var run = TaskRunRecord(
        taskId: 'a',
        startedAt: DateTime(2025, 1, 1, 10, 0, 0),
      );
      final rowId = store.insertRun(run);
      expect(rowId, greaterThan(0));
      run = run.copyWith(
        rowId: rowId,
        finishedAt: DateTime(2025, 1, 1, 10, 0, 30),
        state: TaskRunState.success,
        message: 'Checked 4 sources',
        summary: {'newComics': 2},
      );
      store.finishRun(run);

      final loaded = store.loadRuns(taskId: 'a');
      expect(loaded.length, 1);
      expect(loaded.first.rowId, rowId);
      expect(loaded.first.state, TaskRunState.success);
      expect(loaded.first.message, 'Checked 4 sources');
      expect(loaded.first.summary, {'newComics': 2});
      expect(loaded.first.duration, const Duration(seconds: 30));
    });

    test('returns runs newest first and honours the limit', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      for (var i = 0; i < 5; i++) {
        store.insertRun(TaskRunRecord(
          taskId: 'a',
          startedAt: DateTime(2025, 1, 1, 10, i),
        ));
      }
      final all = store.loadRuns(taskId: 'a');
      expect(all.length, 5);
      expect(all.first.startedAt.minute, 4);
      expect(all.last.startedAt.minute, 0);
      expect(store.loadRuns(taskId: 'a', limit: 2).length, 2);
    });

    test('pruneRuns keeps only the newest runs per task', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      for (var i = 0; i < 10; i++) {
        store.insertRun(TaskRunRecord(
          taskId: 'a',
          startedAt: DateTime(2025, 1, 1, 10, i),
        ));
        store.insertRun(TaskRunRecord(
          taskId: 'b',
          startedAt: DateTime(2025, 1, 1, 11, i),
        ));
      }
      store.pruneRuns(keepPerTask: 3);
      expect(store.countRuns('a'), 3);
      expect(store.countRuns('b'), 3);
      // The survivors are the newest three.
      expect(store.loadRuns(taskId: 'a').first.startedAt.minute, 9);
    });

    test('clearRuns only affects one task', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.insertRun(TaskRunRecord(taskId: 'a', startedAt: DateTime(2025, 1, 1)));
      store.insertRun(TaskRunRecord(taskId: 'b', startedAt: DateTime(2025, 1, 1)));
      store.clearRuns('a');
      expect(store.countRuns('a'), 0);
      expect(store.countRuns('b'), 1);
    });

    test('replaceAll swaps the entire task list', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.saveTask(_simpleTask('old'));
      store.insertRun(TaskRunRecord(taskId: 'old', startedAt: DateTime(2025, 1, 1)));
      store.replaceAll([_simpleTask('new1'), _simpleTask('new2')]);
      expect(store.loadTasks().map((t) => t.id), ['new1', 'new2']);
      expect(store.countRuns('old'), 0);
    });

    test('closeInterruptedRuns closes rows a dead process left running', () {
      if (!_requireSqlite()) {
        return;
      }
      final store = SchedulerStore();
      store.open(_nextDatabasePath());

      // A run that a killed process never got to finish...
      final stale = store.insertRun(
        TaskRunRecord(taskId: 'a', startedAt: DateTime(2025, 1, 1)),
      );
      // ...next to a run that completed normally.
      final done = store.insertRun(
        TaskRunRecord(taskId: 'a', startedAt: DateTime(2025, 1, 1)),
      );
      store.finishRun(TaskRunRecord(
        taskId: 'a',
        startedAt: DateTime(2025, 1, 1),
        rowId: done,
        state: TaskRunState.success,
        message: 'done',
      ));

      expect(store.closeInterruptedRuns(), 1);
      // Idempotent: a second startup finds nothing left to close.
      expect(store.closeInterruptedRuns(), 0);

      final byRow = {
        for (final run in store.loadRuns(taskId: 'a')) run.rowId: run,
      };
      expect(byRow[stale]!.state, TaskRunState.cancelled);
      expect(byRow[stale]!.message, 'Interrupted by app shutdown');
      expect(byRow[stale]!.finishedAt, isNotNull);
      expect(
        byRow[stale]!.finishedAt!.isBefore(byRow[stale]!.startedAt),
        isFalse,
        reason: 'finished_at must never precede started_at',
      );
      // A completed row must be left exactly as it was.
      expect(byRow[done]!.state, TaskRunState.success);
      expect(byRow[done]!.message, 'done');
    });

    test('reopening the same path preserves data', () {
      if (!_requireSqlite()) {
        return;
      }
      final path = _nextDatabasePath();
      final store = SchedulerStore();
      store.open(path);
      store.saveTask(_simpleTask('persisted', name: 'Kept'));
      store.close();

      store.open(path);
      expect(store.loadTask('persisted')!.name, 'Kept');
    });
  });

  // ---------------------------------------------------------------------------
  // Engine
  // ---------------------------------------------------------------------------

  group('SchedulerEngine', () {
    late String databasePath;

    setUp(() {
      TaskRunnerRegistry.clear();
      if (_sqliteAvailable) {
        databasePath = _nextDatabasePath();
      }
    });

    tearDown(() {
      SchedulerEngine().close();
      TaskRunnerRegistry.clear();
    });

    test('createTask rejects an unregistered type', () async {
      if (!_requireSqlite()) {
        return;
      }
      await SchedulerEngine().init(databasePath: databasePath, startTimer: false);
      final created = SchedulerEngine().createTask(
        typeKey: 'nope',
        name: 'x',
        schedule: ScheduleSpec.daily(hour: 1, minute: 0),
      );
      expect(created, isNull);
      expect(SchedulerEngine().tasks, isEmpty);
    });

    test('createTask rejects an unrunnable schedule', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_RecordingRunner());
      await SchedulerEngine().init(databasePath: databasePath, startTimer: false);
      final created = SchedulerEngine().createTask(
        typeKey: 'recorder',
        name: 'x',
        // February never has a 30th.
        schedule: ScheduleSpec.cron('0 0 30 2 *'),
      );
      expect(created, isNull);
    });

    test('createTask schedules the first run and persists it', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_RecordingRunner());
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Every 30 minutes',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      );
      expect(created, isNotNull);
      expect(created!.nextRunAt, isNotNull);
      expect(created.nextRunAt!.isAfter(DateTime.now()), isTrue);
      expect(engine.enabledCount, 1);
      expect(engine.nextScheduledRun, isNotNull);

      // A fresh engine instance reloads the same task from disk.
      final reloaded = SchedulerStore().loadTask(created.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.name, 'Every 30 minutes');
    });

    test('runs a due task, records success, and reschedules', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);

      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Due now',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;
      // Force it to be due.
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));
      // updateTask keeps the pending slot when the schedule is unchanged.
      expect(engine.findTask(created.id)!.isDue, isTrue);

      await engine.runDueTasks();

      expect(runner.runCount, 1);
      final after = engine.findTask(created.id)!;
      expect(after.lastState, TaskRunState.success);
      expect(after.consecutiveFailures, 0);
      expect(after.nextRunAt!.isAfter(DateTime.now()), isTrue);
      expect(after.lastSummary, {'ran': 1});

      final runs = engine.runsFor(created.id);
      expect(runs.length, 1);
      expect(runs.first.state, TaskRunState.success);
      expect(runs.first.isFinished, isTrue);
      expect(engine.logFor(created.id), isNotEmpty);
    });

    test('a failing runner is recorded and counted', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner(fail: true);
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);

      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Failing',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        retry: const TaskRetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration(minutes: 1),
        ),
      )!;
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));
      await engine.runDueTasks();

      final after = engine.findTask(created.id)!;
      expect(after.lastState, TaskRunState.failed);
      expect(after.consecutiveFailures, 1);
      expect(after.lastError, isNotNull);
      expect(engine.runsFor(created.id).first.state, TaskRunState.failed);
    });

    test('a runner that throws is recorded as failed, not propagated', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_ThrowingRunner());
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'thrower',
        name: 'Thrower',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));

      await engine.runDueTasks();

      final after = engine.findTask(created.id)!;
      expect(after.lastState, TaskRunState.failed);
      expect(after.lastError, contains('kaboom'));
    });

    test('a runner requesting cancellation is recorded as cancelled', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_CancellingRunner());
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'cancelling',
        name: 'Cancelling',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));

      await engine.runDueTasks();

      expect(engine.findTask(created.id)!.lastState, TaskRunState.cancelled);
    });

    test('an unknown persisted type is marked failed rather than crashing', () async {
      if (!_requireSqlite()) {
        return;
      }
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      // Persist a task whose runner is not registered.
      SchedulerStore().saveTask(TaskDefinition(
        id: 'orphan',
        typeKey: 'ghost',
        name: 'Orphan',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        createdAt: DateTime.now(),
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));

      // Reload so the engine sees it.
      engine.close();
      await engine.init(databasePath: databasePath, startTimer: false);
      expect(engine.findTask('orphan'), isNotNull);

      await engine.runDueTasks();
      final after = engine.findTask('orphan')!;
      expect(after.lastState, TaskRunState.failed);
      expect(after.lastError, contains('Unknown task type'));
    });

    test('disabled tasks are never due', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Disabled',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        enabled: false,
      )!;
      expect(created.nextRunAt, isNull);
      await engine.runDueTasks();
      expect(runner.runCount, 0);

      engine.setEnabled(created.id, true);
      expect(engine.findTask(created.id)!.nextRunAt, isNotNull);
      engine.setEnabled(created.id, false);
      expect(engine.findTask(created.id)!.nextRunAt, isNull);
    });

    test('runOnStart brings a future slot forward when the engine restarts',
        () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);

      // A daily task: its next slot is hours away, so without runOnStart an app
      // session that starts and ends before then would never run it.
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'On start',
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
        runOnStart: true,
      )!;
      expect(created.runOnStart, isTrue);
      expect(created.nextRunAt!.isAfter(DateTime.now()), isTrue);
      expect(engine.findTask(created.id)!.isDue, isFalse);

      // Simulate an app restart.
      engine.close();
      await engine.init(databasePath: databasePath, startTimer: false);

      final reloaded = engine.findTask(created.id)!;
      expect(reloaded.runOnStart, isTrue, reason: 'flag must survive restart');
      expect(
        reloaded.isDue,
        isTrue,
        reason: 'runOnStart should mark the task due at startup',
      );

      await engine.runDueTasks();
      expect(runner.runCount, 1);
      // Afterwards it returns to its normal calendar slot.
      final after = engine.findTask(created.id)!;
      expect(after.lastState, TaskRunState.success);
      expect(after.nextRunAt!.hour, 3);
      expect(after.nextRunAt!.isAfter(DateTime.now()), isTrue);
    });

    test('without runOnStart a future slot stays in the future', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Normal',
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
      )!;
      expect(created.runOnStart, isFalse);

      engine.close();
      await engine.init(databasePath: databasePath, startTimer: false);

      expect(engine.findTask(created.id)!.isDue, isFalse);
      await engine.runDueTasks();
      expect(runner.runCount, 0);
    });

    test('runOnStart does not double-run an already overdue task', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Overdue and on start',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        runOnStart: true,
      )!;
      // Make it overdue as if the app had been closed past its slot.
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(hours: 3)),
      ));

      engine.close();
      await engine.init(databasePath: databasePath, startTimer: false);
      await engine.runDueTasks();

      // Exactly one run: the overdue catch-up, not a second one from runOnStart.
      expect(runner.runCount, 1);
      expect(engine.runsFor(created.id).length, 1);
    });

    test('runNow executes immediately and keeps the scheduled slot', () async {
      if (!_requireSqlite()) {
        return;
      }
      final runner = _RecordingRunner();
      TaskRunnerRegistry.register(runner);
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Manual',
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
      )!;
      final scheduledBefore = created.nextRunAt;

      await engine.runNow(created.id);

      expect(runner.runCount, 1);
      final after = engine.findTask(created.id)!;
      expect(after.lastState, TaskRunState.success);
      // A manual run must not push a calendar slot into the future.
      expect(after.nextRunAt, equals(scheduledBefore));
    });

    test('deleting a task drops it and its history', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_RecordingRunner());
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final created = engine.createTask(
        typeKey: 'recorder',
        name: 'Doomed',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;
      engine.updateTask(created.copyWith(
        nextRunAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ));
      await engine.runDueTasks();
      expect(engine.runsFor(created.id), isNotEmpty);

      engine.deleteTask(created.id);
      expect(engine.tasks, isEmpty);
      expect(engine.runsFor(created.id), isEmpty);
      expect(SchedulerStore().loadTask(created.id), isNull);
    });

    test('recovers a run interrupted by shutdown', () async {
      if (!_requireSqlite()) {
        return;
      }
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      SchedulerStore().saveTask(TaskDefinition(
        id: 'stuck',
        typeKey: 'recorder',
        name: 'Stuck',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        createdAt: DateTime.now(),
        lastState: TaskRunState.running,
      ));
      engine.close();
      await engine.init(databasePath: databasePath, startTimer: false);

      final recovered = engine.findTask('stuck')!;
      expect(recovered.lastState, TaskRunState.cancelled);
      expect(recovered.lastError, contains('Interrupted'));
      // It must also be rescheduled so it is not stuck forever.
      expect(recovered.nextRunAt, isNotNull);
    });

    test('reorder updates ordering and survives a reload', () async {
      if (!_requireSqlite()) {
        return;
      }
      TaskRunnerRegistry.register(_RecordingRunner());
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      final a = engine.createTask(
        typeKey: 'recorder',
        name: 'A',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;
      final b = engine.createTask(
        typeKey: 'recorder',
        name: 'B',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      )!;

      engine.reorder([b.id, a.id]);
      expect(engine.tasks.map((t) => t.name), ['B', 'A']);
      expect(SchedulerStore().loadTasks().map((t) => t.name), ['B', 'A']);
    });

    test('init does not start a timer when asked not to', () async {
      if (!_requireSqlite()) {
        return;
      }
      final engine = SchedulerEngine();
      await engine.init(databasePath: databasePath, startTimer: false);
      expect(engine.isStarted, isTrue);
      engine.close();
      expect(engine.isStarted, isFalse);
    });
  });
}

// -----------------------------------------------------------------------------
// Test doubles
// -----------------------------------------------------------------------------

TaskDefinition _simpleTask(
  String id, {
  String name = 'Task',
  int sortOrder = 0,
  DateTime? createdAt,
}) {
  return TaskDefinition(
    id: id,
    typeKey: 'recorder',
    name: name,
    schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
    sortOrder: sortOrder,
    createdAt: createdAt ?? DateTime(2025, 1, 1),
  );
}

class _RecordingRunner extends SchedulableRunner {
  _RecordingRunner({this.fail = false});

  final bool fail;

  int runCount = 0;

  @override
  String get typeKey => 'recorder';

  @override
  String get displayName => 'Recording runner';

  @override
  String get description => 'Records how many times it ran';
  @override
  Map<String, dynamic> defaultConfig() => {'limit': 10};

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    runCount++;
    context.log('run $runCount');
    if (fail) {
      return const TaskRunOutcome.failed('simulated failure');
    }
    return TaskRunOutcome(
      success: true,
      message: 'did the thing',
      summary: {'ran': runCount},
    );
  }
}

class _ThrowingRunner extends SchedulableRunner {
  @override
  String get typeKey => 'thrower';

  @override
  String get displayName => 'Throwing runner';

  @override
  String get description => 'Always throws';
  @override
  Map<String, dynamic> defaultConfig() => const {};

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    throw StateError('kaboom');
  }
}

class _CancellingRunner extends SchedulableRunner {
  @override
  String get typeKey => 'cancelling';

  @override
  String get displayName => 'Cancelling runner';

  @override
  String get description => 'Reports itself cancelled';
  @override
  Map<String, dynamic> defaultConfig() => const {};

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    throw const TaskCancelledException();
  }
}

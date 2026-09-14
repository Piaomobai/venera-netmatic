import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';

void main() {
  group('ScheduleSpec interval', () {
    test('rejects intervals below the floor', () {
      expect(
        () => ScheduleSpec.everyInterval(const Duration(minutes: 4)),
        throwsArgumentError,
      );
      expect(
        () => ScheduleSpec.everyInterval(Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => ScheduleSpec.everyInterval(const Duration(minutes: 5)),
        returnsNormally,
      );
    });

    test('nextAfter adds the interval without rounding', () {
      final spec = ScheduleSpec.everyInterval(const Duration(minutes: 30));
      expect(
        spec.nextAfter(DateTime(2025, 1, 1, 10, 7, 42)),
        DateTime(2025, 1, 1, 10, 37, 42),
      );
      expect(spec.asCron, isNull);
      expect(spec.validationError(), isNull);
    });

    test('describes itself in hours and minutes', () {
      expect(
        ScheduleSpec.everyInterval(const Duration(hours: 6)).description,
        'Every 6 hours',
      );
      expect(
        ScheduleSpec.everyInterval(const Duration(hours: 1)).description,
        'Every hour',
      );
      expect(
        ScheduleSpec.everyInterval(const Duration(minutes: 30)).description,
        'Every 30 minutes',
      );
      expect(
        ScheduleSpec.everyInterval(const Duration(minutes: 5)).description,
        'Every 5 minutes',
      );
    });
  });

  group('ScheduleSpec friendly presets compile to cron', () {
    test('daily', () {
      final spec = ScheduleSpec.daily(hour: 3, minute: 30);
      expect(spec.asCron!.source, '30 3 * * *');
      expect(spec.description, 'Every day at 03:30');
      expect(spec.nextAfter(DateTime(2025, 1, 1, 4, 0)),
          DateTime(2025, 1, 2, 3, 30));
      expect(spec.nextAfter(DateTime(2025, 1, 1, 3, 30)),
          DateTime(2025, 1, 2, 3, 30));
      expect(spec.validationError(), isNull);
    });

    test('weekly', () {
      final spec = ScheduleSpec.weekly(weekdays: [1, 3], hour: 3, minute: 30);
      expect(spec.asCron!.source, '30 3 * * 1,3');
      expect(spec.description, 'Mon, Wed at 03:30');
      // 2025-01-01 is a Wednesday, so the next run is that same day.
      expect(spec.nextAfter(DateTime(2025, 1, 1, 0, 0)),
          DateTime(2025, 1, 1, 3, 30));
      expect(spec.nextAfter(DateTime(2025, 1, 1, 4, 0)),
          DateTime(2025, 1, 6, 3, 30)); // Monday
    });

    test('weekly sorts and de-duplicates its weekdays', () {
      final spec = ScheduleSpec.weekly(weekdays: [5, 1, 1, 3], hour: 0, minute: 0);
      expect(spec.weekdays, [1, 3, 5]);
      expect(spec.asCron!.source, '0 0 * * 1,3,5');
    });

    test('weekly with all seven days reads as daily', () {
      final spec = ScheduleSpec.weekly(
        weekdays: [0, 1, 2, 3, 4, 5, 6],
        hour: 3,
        minute: 30,
      );
      expect(spec.description, 'Every day at 03:30');
      expect(spec.asCron!.daysOfWeek, [0, 1, 2, 3, 4, 5, 6]);
    });

    test('weekly requires at least one weekday', () {
      expect(
        () => ScheduleSpec.weekly(weekdays: const [], hour: 0, minute: 0),
        throwsArgumentError,
      );
    });

    test('weekly folds 7 onto Sunday but rejects out-of-range days', () {
      // 7 is cron's other spelling of Sunday, so it normalizes to 0.
      expect(
        ScheduleSpec.weekly(weekdays: const [7], hour: 0, minute: 0).weekdays,
        [0],
      );
      // Out-of-range values must NOT be silently wrapped onto a valid day,
      // which is what would happen if the range check ran after normalizing.
      expect(
        () => ScheduleSpec.weekly(weekdays: const [8], hour: 0, minute: 0),
        throwsArgumentError,
      );
      expect(
        () => ScheduleSpec.weekly(weekdays: const [14], hour: 0, minute: 0),
        throwsArgumentError,
      );
      expect(
        () => ScheduleSpec.weekly(weekdays: const [-1], hour: 0, minute: 0),
        throwsArgumentError,
      );
    });

    test('monthly', () {
      final spec = ScheduleSpec.monthly(dayOfMonth: 15, hour: 3, minute: 30);
      expect(spec.asCron!.source, '30 3 15 * *');
      expect(spec.description, 'Day 15 of every month at 03:30');
      expect(spec.nextAfter(DateTime(2025, 1, 1, 0, 0)),
          DateTime(2025, 1, 15, 3, 30));
      expect(spec.nextAfter(DateTime(2025, 1, 15, 3, 30)),
          DateTime(2025, 2, 15, 3, 30));
    });

    test('monthly skips months without that day rather than clamping', () {
      final spec = ScheduleSpec.monthly(dayOfMonth: 31, hour: 0, minute: 0);
      expect(spec.nextAfter(DateTime(2025, 1, 31, 0, 0)),
          DateTime(2025, 3, 31, 0, 0));
    });

    test('rejects out-of-range times and days', () {
      expect(() => ScheduleSpec.daily(hour: 24, minute: 0), throwsArgumentError);
      expect(() => ScheduleSpec.daily(hour: 0, minute: 60), throwsArgumentError);
      expect(
        () => ScheduleSpec.monthly(dayOfMonth: 0, hour: 0, minute: 0),
        throwsArgumentError,
      );
      expect(
        () => ScheduleSpec.monthly(dayOfMonth: 32, hour: 0, minute: 0),
        throwsArgumentError,
      );
    });
  });

  group('ScheduleSpec cron', () {
    test('keeps the raw expression', () {
      final spec = ScheduleSpec.cron('  0 5 * * 1  ');
      expect(spec.cronExpression, '0 5 * * 1');
      expect(spec.asCron!.source, '0 5 * * 1');
      expect(spec.description, 'Cron: 0 5 * * 1');
      expect(spec.validationError(), isNull);
    });

    test('rejects an invalid expression eagerly', () {
      expect(() => ScheduleSpec.cron('not a cron'), throwsFormatException);
      expect(() => ScheduleSpec.cron('* * *'), throwsFormatException);
    });

    test('flags an expression that can never fire', () {
      // February never has a 30th, so this parses but never matches.
      final spec = ScheduleSpec.cron('0 0 30 2 *');
      expect(spec.validationError(), isNotNull);
      expect(spec.isValid, isFalse);
      expect(spec.nextAfter(DateTime(2025, 1, 1)), isNull);
    });
  });

  group('ScheduleSpec weekday conversion', () {
    test('normalizeWeekday folds Dart numbering onto cron numbering', () {
      // Dart: Mon=1 .. Sat=6, Sun=7. Cron: Sun=0, Mon=1 .. Sat=6.
      expect(ScheduleSpec.normalizeWeekday(DateTime.monday), 1);
      expect(ScheduleSpec.normalizeWeekday(DateTime.saturday), 6);
      expect(ScheduleSpec.normalizeWeekday(DateTime.sunday), 0);
    });

    test('toDartWeekday converts back', () {
      expect(ScheduleSpec.toDartWeekday(0), DateTime.sunday);
      expect(ScheduleSpec.toDartWeekday(1), DateTime.monday);
      expect(ScheduleSpec.toDartWeekday(6), DateTime.saturday);
    });

    test('round-trips with the real DateTime.weekday of a known date', () {
      // 2025-01-06 is a Monday.
      final monday = DateTime(2025, 1, 6);
      expect(monday.weekday, DateTime.monday);
      expect(ScheduleSpec.normalizeWeekday(monday.weekday), 1);
      final spec = ScheduleSpec.weekly(weekdays: [1], hour: 9, minute: 0);
      expect(spec.nextAfter(DateTime(2025, 1, 5, 12, 0)),
          DateTime(2025, 1, 6, 9, 0));
    });
  });

  group('ScheduleSpec serialization', () {
    test('round-trips every type', () {
      final specs = [
        ScheduleSpec.everyInterval(const Duration(minutes: 30)),
        ScheduleSpec.daily(hour: 3, minute: 30),
        ScheduleSpec.weekly(weekdays: [1, 3], hour: 3, minute: 30),
        ScheduleSpec.monthly(dayOfMonth: 15, hour: 3, minute: 30),
        ScheduleSpec.cron('0 5 * * 1'),
      ];
      for (final spec in specs) {
        final json = spec.toJson();
        final restored = ScheduleSpec.fromJson(json);
        expect(restored, isNotNull, reason: 'failed to restore $spec');
        expect(restored, equals(spec), reason: 'mismatch for $spec');
        expect(restored!.description, spec.description);
      }
    });

    test('omits irrelevant fields', () {
      expect(
        ScheduleSpec.everyInterval(const Duration(minutes: 30)).toJson(),
        {'type': 'interval', 'intervalSeconds': 1800},
      );
      expect(
        ScheduleSpec.daily(hour: 3, minute: 30).toJson(),
        {'type': 'daily', 'hour': 3, 'minute': 30},
      );
      expect(
        ScheduleSpec.cron('0 5 * * 1').toJson(),
        {'type': 'cron', 'cronExpression': '0 5 * * 1'},
      );
    });

    test('returns null instead of throwing on corrupt data', () {
      expect(ScheduleSpec.fromJson(<String, dynamic>{}), isNull);
      expect(ScheduleSpec.fromJson({'type': 'nonsense'}), isNull);
      expect(ScheduleSpec.fromJson({'type': 'interval'}), isNull);
      expect(
        ScheduleSpec.fromJson({'type': 'interval', 'intervalSeconds': 0}),
        isNull,
      );
      expect(ScheduleSpec.fromJson({'type': 'cron'}), isNull);
      expect(
        ScheduleSpec.fromJson({'type': 'cron', 'cronExpression': 'garbage'}),
        isNull,
      );
      expect(ScheduleSpec.fromJson({'type': 'weekly', 'weekdays': <int>[]}), isNull);
    });
  });

  group('TaskRetryPolicy', () {
    test('exponential backoff, clamped to maxDelay', () {
      const policy = TaskRetryPolicy(
        maxAttempts: 5,
        initialDelay: Duration(minutes: 1),
        backoffMultiplier: 2.0,
        maxDelay: Duration(minutes: 3),
      );
      expect(policy.retriesEnabled, isTrue);
      expect(policy.delayBeforeAttempt(1), Duration.zero);
      expect(policy.delayBeforeAttempt(2), const Duration(minutes: 1));
      expect(policy.delayBeforeAttempt(3), const Duration(minutes: 2));
      expect(policy.delayBeforeAttempt(4), const Duration(minutes: 3)); // clamped
      expect(policy.delayBeforeAttempt(9), const Duration(minutes: 3));
    });

    test('a single attempt means no retrying', () {
      const policy = TaskRetryPolicy(maxAttempts: 1);
      expect(policy.retriesEnabled, isFalse);
    });

    test('round-trips through JSON', () {
      const policy = TaskRetryPolicy(
        maxAttempts: 3,
        initialDelay: Duration(seconds: 45),
        backoffMultiplier: 1.5,
        maxDelay: Duration(minutes: 10),
      );
      final restored = TaskRetryPolicy.fromJson(policy.toJson());
      expect(restored.maxAttempts, 3);
      expect(restored.initialDelay, const Duration(seconds: 45));
      expect(restored.backoffMultiplier, 1.5);
      expect(restored.maxDelay, const Duration(minutes: 10));
    });

    test('falls back to defaults on corrupt JSON', () {
      final restored = TaskRetryPolicy.fromJson({'maxAttempts': 'lots'});
      expect(restored.maxAttempts, 1);
    });
  });

  group('TaskDefinition scheduling', () {
    TaskDefinition build({
      required ScheduleSpec schedule,
      TaskRetryPolicy retry = const TaskRetryPolicy(),
      int consecutiveFailures = 0,
      DateTime? nextRunAt,
      bool enabled = true,
    }) {
      return TaskDefinition(
        id: 't1',
        typeKey: 'test',
        name: 'Test',
        schedule: schedule,
        retry: retry,
        consecutiveFailures: consecutiveFailures,
        nextRunAt: nextRunAt,
        enabled: enabled,
        createdAt: DateTime(2025, 1, 1),
      );
    }

    test('computeNextRun truncates to the minute for intervals', () {
      final task = build(
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 30)),
      );
      expect(
        task.computeNextRun(DateTime(2025, 1, 1, 10, 7, 42)),
        DateTime(2025, 1, 1, 10, 37),
      );
    });

    test('computeNextRun uses the calendar for cron schedules', () {
      final task = build(schedule: ScheduleSpec.daily(hour: 3, minute: 30));
      expect(
        task.computeNextRun(DateTime(2025, 1, 1, 4, 0)),
        DateTime(2025, 1, 2, 3, 30),
      );
    });

    test('auto-enables a retry while the budget lasts', () {
      final task = build(
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
        retry: const TaskRetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration(minutes: 1),
          backoffMultiplier: 2.0,
        ),
        consecutiveFailures: 1,
      );
      final now = DateTime(2025, 1, 1, 4, 0);
      // First failure -> the upcoming run would be attempt 2.
      expect(task.computeRetryRun(now), now.add(const Duration(minutes: 1)));

      final second = task.copyWith(consecutiveFailures: 2);
      expect(second.computeRetryRun(now), now.add(const Duration(minutes: 2)));

      // Budget exhausted: fall back to the normal schedule.
      final third = task.copyWith(consecutiveFailures: 3);
      expect(third.computeRetryRun(now), isNull);
    });

    test('never retries when maxAttempts is 1', () {
      final task = build(
        schedule: ScheduleSpec.daily(hour: 3, minute: 30),
        consecutiveFailures: 1,
      );
      expect(task.computeRetryRun(DateTime(2025, 1, 1)), isNull);
    });

    test('isDue reflects enabled state and nextRunAt', () {
      final past = DateTime.now().subtract(const Duration(minutes: 1));
      final future = DateTime.now().add(const Duration(hours: 1));
      expect(build(schedule: ScheduleSpec.daily(hour: 0, minute: 0), nextRunAt: past).isDue, isTrue);
      expect(build(schedule: ScheduleSpec.daily(hour: 0, minute: 0), nextRunAt: future).isDue, isFalse);
      expect(
        build(
          schedule: ScheduleSpec.daily(hour: 0, minute: 0),
          nextRunAt: past,
          enabled: false,
        ).isDue,
        isFalse,
      );
    });

    test('copyWith can clear nullable fields explicitly', () {
      final task = build(schedule: ScheduleSpec.daily(hour: 0, minute: 0))
          .copyWith(lastError: 'boom', lastSummary: {'a': 1});
      expect(task.lastError, 'boom');
      expect(task.copyWith(clearLastError: true).lastError, isNull);
      expect(task.copyWith(clearLastSummary: true).lastSummary, isNull);
    });

    test('round-trips through JSON', () {
      final task = build(
        schedule: ScheduleSpec.weekly(weekdays: [1, 5], hour: 2, minute: 15),
        retry: const TaskRetryPolicy(maxAttempts: 3),
        nextRunAt: DateTime(2025, 1, 6, 2, 15),
      ).copyWith(
        lastRunAt: DateTime(2025, 1, 1, 2, 15),
        lastState: TaskRunState.failed,
        lastError: 'network down',
        lastSummary: {'sourcesChecked': 4},
        runOnStart: true,
      );
      final restored = TaskDefinition.fromJson(task.toJson());
      expect(restored, isNotNull);
      expect(restored!.toJson(), equals(task.toJson()));
      expect(restored.schedule, equals(task.schedule));
      expect(restored.lastState, TaskRunState.failed);
      expect(restored.lastError, 'network down');
      expect(restored.lastSummary, {'sourcesChecked': 4});
      expect(restored.retry.maxAttempts, 3);
      expect(restored.runOnStart, isTrue);
    });

    test('runOnStart defaults to false and survives copyWith', () {
      final task = build(
        schedule: ScheduleSpec.daily(hour: 1, minute: 0),
      );
      // Off by default: existing tasks must not silently start running on every
      // app launch after an upgrade.
      expect(task.runOnStart, isFalse);
      expect(TaskDefinition.fromJson(task.toJson())!.runOnStart, isFalse);

      final on = task.copyWith(runOnStart: true);
      expect(on.runOnStart, isTrue);
      expect(on.copyWith(name: 'renamed').runOnStart, isTrue);
      expect(on.copyWith(runOnStart: false).runOnStart, isFalse);
      // A JSON blob written before this field existed must still load.
      final legacy = task.toJson()..remove('runOnStart');
      expect(TaskDefinition.fromJson(legacy)!.runOnStart, isFalse);
    });

    test('rejects corrupt records without throwing', () {
      expect(TaskDefinition.fromJson(<String, dynamic>{}), isNull);
      expect(
        TaskDefinition.fromJson({'id': 'a', 'typeKey': 'b'}),
        isNull,
        reason: 'missing schedule',
      );
      expect(
        TaskDefinition.fromJson({
          'id': '',
          'typeKey': 'b',
          'schedule': {'type': 'interval', 'intervalSeconds': 600},
        }),
        isNull,
        reason: 'empty id',
      );
    });
  });

  group('TaskRunRecord', () {
    test('reports duration once finished', () {
      final record = TaskRunRecord(
        taskId: 't1',
        startedAt: DateTime(2025, 1, 1, 10, 0, 0),
        finishedAt: DateTime(2025, 1, 1, 10, 0, 30),
        state: TaskRunState.success,
      );
      expect(record.duration, const Duration(seconds: 30));
      expect(record.isFinished, isTrue);
      expect(
        TaskRunRecord(taskId: 't1', startedAt: DateTime(2025, 1, 1)).duration,
        isNull,
      );
    });

    test('round-trips through JSON', () {
      final record = TaskRunRecord(
        taskId: 't1',
        startedAt: DateTime(2025, 1, 1, 10, 0, 0),
        finishedAt: DateTime(2025, 1, 1, 10, 0, 30),
        state: TaskRunState.success,
        message: 'Checked 3 sources',
        summary: {'newComics': 2},
      );
      final restored = TaskRunRecord.fromJson(record.toJson());
      expect(restored, isNotNull);
      expect(restored!.taskId, 't1');
      expect(restored.state, TaskRunState.success);
      expect(restored.message, 'Checked 3 sources');
      expect(restored.summary, {'newComics': 2});
      expect(restored.duration, const Duration(seconds: 30));
    });

    test('rejects a record with no task id', () {
      expect(TaskRunRecord.fromJson({'startedAt': 0}), isNull);
    });
  });

  group('TaskRunnerRegistry', () {
    tearDown(TaskRunnerRegistry.clear);

    test('registers and looks up runners', () {
      final runner = _FakeRunner('alpha', 'Alpha');
      TaskRunnerRegistry.register(runner);
      expect(TaskRunnerRegistry.has('alpha'), isTrue);
      expect(TaskRunnerRegistry.find('alpha'), same(runner));
      expect(TaskRunnerRegistry.find('missing'), isNull);
      expect(TaskRunnerRegistry.all().map((r) => r.typeKey), ['alpha']);
    });

    test('re-registering a type replaces it', () {
      TaskRunnerRegistry.register(_FakeRunner('alpha', 'Alpha'));
      final replacement = _FakeRunner('alpha', 'Alpha Two');
      TaskRunnerRegistry.register(replacement);
      expect(TaskRunnerRegistry.all().length, 1);
      expect(TaskRunnerRegistry.find('alpha'), same(replacement));
    });
  });

  group('TaskRunContext', () {
    test('reads typed config values with coercion', () {
      final task = TaskDefinition(
        id: 't1',
        typeKey: 'test',
        name: 'Test',
        schedule: ScheduleSpec.daily(hour: 0, minute: 0),
        config: {
          'count': 7,
          'ratio': 1.5,
          'name': 'hello',
          'flag': true,
          'list': ['a', 'b', 3],
          'missing': null,
        },
        createdAt: DateTime(2025, 1, 1),
      );
      final context = TaskRunContext(
        task: task,
        log: (_) {},
        isCancelled: () => false,
        reportProgress: ({double? progress, String? message}) {},
      );
      expect(context.configValue('count', 0), 7);
      expect(context.configValue('ratio', 0.0), 1.5);
      expect(context.configValue('name', 'x'), 'hello');
      expect(context.configValue('flag', false), isTrue);
      expect(context.configValue('missing', 42), 42);
      expect(context.configValue('absent', 'fallback'), 'fallback');
      expect(context.configValue('ratio', 0), 1); // int fallback coerces
      expect(context.configStringList('list'), ['a', 'b']);
      expect(context.configStringList('absent'), isEmpty);
    });

    test('throwIfCancelled raises the cancellation exception', () {
      final task = TaskDefinition(
        id: 't1',
        typeKey: 'test',
        name: 'Test',
        schedule: ScheduleSpec.daily(hour: 0, minute: 0),
        createdAt: DateTime(2025, 1, 1),
      );
      var cancelled = false;
      final context = TaskRunContext(
        task: task,
        log: (_) {},
        isCancelled: () => cancelled,
        reportProgress: ({double? progress, String? message}) {},
      );
      expect(context.throwIfCancelled, returnsNormally);
      cancelled = true;
      expect(context.isCancelled, isTrue);
      expect(context.throwIfCancelled, throwsA(isA<TaskCancelledException>()));
    });
  });

  group('task list codec', () {
    test('round-trips and skips unusable entries', () {
      final task = TaskDefinition(
        id: 't1',
        typeKey: 'test',
        name: 'Test',
        schedule: ScheduleSpec.everyInterval(const Duration(minutes: 10)),
        createdAt: DateTime(2025, 1, 1),
      );
      final encoded = encodeTaskList([task]);
      final decoded = decodeTaskList(encoded);
      expect(decoded.length, 1);
      expect(decoded.first.toJson(), equals(task.toJson()));

      expect(decodeTaskList('not json'), isEmpty);
      expect(decodeTaskList('[{"broken": true}, {}]'), isEmpty);
    });
  });
}

class _FakeRunner extends SchedulableRunner {
  _FakeRunner(this.typeKey, this.displayName);

  @override
  final String typeKey;

  @override
  final String displayName;

  @override
  String get description => 'Fake runner';

  @override
  Map<String, dynamic> defaultConfig() => {'enabled': true};

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async =>
      const TaskRunOutcome(success: true, message: 'ok');
}

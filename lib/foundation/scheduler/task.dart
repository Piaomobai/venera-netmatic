import 'dart:convert';

import 'schedule.dart';

/// The outcome of the most recent run of a task.
enum TaskRunState {
  /// Never run.
  never,

  /// Currently executing.
  running,

  /// Finished without error.
  success,

  /// Finished with an error.
  failed,

  /// Stopped by the user or by app shutdown.
  cancelled,

  /// Considered due, but deliberately not executed (disabled, no work to do,
  /// or a precondition such as the network being unavailable).
  skipped,
}

/// Retry policy applied when a run fails.
class TaskRetryPolicy {
  const TaskRetryPolicy({
    this.maxAttempts = 1,
    this.initialDelay = const Duration(minutes: 1),
    this.backoffMultiplier = 2.0,
    this.maxDelay = const Duration(hours: 1),
  }) : assert(maxAttempts >= 1);

  /// Total attempts, including the first. `1` disables retrying.
  final int maxAttempts;

  final Duration initialDelay;

  final double backoffMultiplier;

  final Duration maxDelay;

  bool get retriesEnabled => maxAttempts > 1;

  /// Delay before attempt number [attempt] (1-based, so attempt 2 is the first
  /// retry).
  Duration delayBeforeAttempt(int attempt) {
    if (attempt <= 1) {
      return Duration.zero;
    }
    var delay = initialDelay.inMilliseconds *
        _pow(backoffMultiplier, attempt - 2).toDouble();
    if (delay.isNaN || delay < 0) {
      delay = initialDelay.inMilliseconds.toDouble();
    }
    if (delay > maxDelay.inMilliseconds) {
      delay = maxDelay.inMilliseconds.toDouble();
    }
    return Duration(milliseconds: delay.round());
  }

  static num _pow(double base, int exponent) {
    var result = 1.0;
    for (var i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'maxAttempts': maxAttempts,
        'initialDelaySeconds': initialDelay.inSeconds,
        'backoffMultiplier': backoffMultiplier,
        'maxDelaySeconds': maxDelay.inSeconds,
      };

  static TaskRetryPolicy fromJson(Map<String, dynamic> json) {
    try {
      return TaskRetryPolicy(
        maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 1,
        initialDelay:
            Duration(seconds: (json['initialDelaySeconds'] as num?)?.toInt() ?? 60),
        backoffMultiplier:
            (json['backoffMultiplier'] as num?)?.toDouble() ?? 2.0,
        maxDelay:
            Duration(seconds: (json['maxDelaySeconds'] as num?)?.toInt() ?? 3600),
      );
    } catch (_) {
      return const TaskRetryPolicy();
    }
  }

  @override
  String toString() => 'TaskRetryPolicy(maxAttempts: $maxAttempts)';
}

/// A persisted scheduled task.
///
/// Immutable: the engine and store replace whole instances via [copyWith] so
/// that concurrent readers never observe a half-updated task.
class TaskDefinition {
  const TaskDefinition({
    required this.id,
    required this.typeKey,
    required this.name,
    required this.schedule,
    this.enabled = true,
    this.runOnStart = false,
    this.config = const {},
    this.retry = const TaskRetryPolicy(),
    this.sortOrder = 0,
    required this.createdAt,
    this.lastRunAt,
    this.nextRunAt,
    this.lastState = TaskRunState.never,
    this.lastError,
    this.consecutiveFailures = 0,
    this.lastSummary,
  });

  /// Stable unique id (a v4 UUID).
  final String id;

  /// Which registered runner handles this task.
  final String typeKey;

  /// User-visible name.
  final String name;

  final ScheduleSpec schedule;

  final bool enabled;

  /// When true, an enabled task is marked due as soon as the engine starts, so
  /// it runs shortly after the app opens instead of waiting for its next
  /// scheduled slot.
  ///
  /// This exists because the engine only runs while the app is open: a task
  /// whose interval is longer than a typical session (say six hours, opened
  /// briefly once a day) would otherwise never fire at all. An overdue task is
  /// caught up on start regardless of this flag; [runOnStart] additionally
  /// covers the case where the next slot is still in the future.
  final bool runOnStart;

  /// Runner-specific options, validated by the runner.
  final Map<String, dynamic> config;

  final TaskRetryPolicy retry;

  /// Display and execution order; lower runs first.
  final int sortOrder;

  final DateTime createdAt;

  /// When the last run started.
  final DateTime? lastRunAt;

  /// When the next run is due. Null means "needs scheduling".
  final DateTime? nextRunAt;

  final TaskRunState lastState;

  final String? lastError;

  /// Reset to 0 on success; drives the retry policy.
  final int consecutiveFailures;

  /// Machine-readable result of the last run, e.g. `{"newComics": 3}`.
  final Map<String, dynamic>? lastSummary;

  bool get isDue {
    final next = nextRunAt;
    return enabled && next != null && !next.isAfter(DateTime.now());
  }

  TaskDefinition copyWith({
    String? id,
    String? typeKey,
    String? name,
    ScheduleSpec? schedule,
    bool? enabled,
    bool? runOnStart,
    Map<String, dynamic>? config,
    TaskRetryPolicy? retry,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? lastRunAt,
    DateTime? nextRunAt,
    TaskRunState? lastState,
    String? lastError,
    int? consecutiveFailures,
    Map<String, dynamic>? lastSummary,
    bool clearLastError = false,
    bool clearLastSummary = false,
    bool clearNextRunAt = false,
  }) {
    return TaskDefinition(
      id: id ?? this.id,
      typeKey: typeKey ?? this.typeKey,
      name: name ?? this.name,
      schedule: schedule ?? this.schedule,
      enabled: enabled ?? this.enabled,
      runOnStart: runOnStart ?? this.runOnStart,
      config: config ?? this.config,
      retry: retry ?? this.retry,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      // `nextRunAt` is nullable, so `nextRunAt ?? this.nextRunAt` cannot express
      // "clear it". Callers that need it cleared pass clearNextRunAt.
      nextRunAt: clearNextRunAt ? null : (nextRunAt ?? this.nextRunAt),
      lastState: lastState ?? this.lastState,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastSummary:
          clearLastSummary ? null : (lastSummary ?? this.lastSummary),
    );
  }

  /// The next run time strictly after [now], used both for the initial schedule
  /// and after every completed run.
  ///
  /// For interval schedules the interval is measured from [now], so a period
  /// spent offline (or a run that took longer than the interval) collapses into
  /// a single run instead of a burst of catch-up runs.
  DateTime computeNextRun(DateTime now) {
    final truncated =
        DateTime(now.year, now.month, now.day, now.hour, now.minute);
    if (schedule.type == ScheduleType.interval) {
      return truncated.add(schedule.interval!);
    }
    return schedule.nextAfter(truncated) ??
        truncated.add(const Duration(hours: 24));
  }

  /// Backoff applied after a failed run, or null when the retry budget is spent
  /// and the task should simply wait for its next scheduled time.
  ///
  /// Called on the task *after* [consecutiveFailures] has been incremented, so
  /// that value counts the failures so far and the upcoming run would be
  /// attempt `consecutiveFailures + 1`.
  DateTime? computeRetryRun(DateTime now) {
    if (!retry.retriesEnabled) {
      return null;
    }
    final nextAttempt = consecutiveFailures + 1;
    if (nextAttempt > retry.maxAttempts) {
      return null;
    }
    return now.add(retry.delayBeforeAttempt(nextAttempt));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'typeKey': typeKey,
        'name': name,
        'schedule': schedule.toJson(),
        'enabled': enabled,
        'runOnStart': runOnStart,
        'config': config,
        'retry': retry.toJson(),
        'sortOrder': sortOrder,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastRunAt': lastRunAt?.millisecondsSinceEpoch,
        'nextRunAt': nextRunAt?.millisecondsSinceEpoch,
        'lastState': lastState.name,
        'lastError': lastError,
        'consecutiveFailures': consecutiveFailures,
        'lastSummary': lastSummary,
      };

  /// Parses a task, returning null when the record is unusable.
  ///
  /// Never throws: a single corrupt row must not prevent the rest of the task
  /// list from loading.
  static TaskDefinition? fromJson(Map<String, dynamic> json) {
    try {
      final scheduleJson = json['schedule'];
      final schedule = scheduleJson is Map
          ? ScheduleSpec.fromJson(Map<String, dynamic>.from(scheduleJson))
          : null;
      if (schedule == null) {
        return null;
      }
      final id = json['id'];
      final typeKey = json['typeKey'];
      if (id is! String || id.isEmpty || typeKey is! String || typeKey.isEmpty) {
        return null;
      }
      final rawConfig = json['config'];
      return TaskDefinition(
        id: id,
        typeKey: typeKey,
        name: json['name'] is String ? json['name'] as String : typeKey,
        schedule: schedule,
        enabled: json['enabled'] as bool? ?? true,
        runOnStart: json['runOnStart'] as bool? ?? false,
        config: rawConfig is Map
            ? Map<String, dynamic>.from(rawConfig)
            : const {},
        retry: json['retry'] is Map
            ? TaskRetryPolicy.fromJson(Map<String, dynamic>.from(json['retry']))
            : const TaskRetryPolicy(),
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        createdAt: _dateFrom(json['createdAt']) ?? DateTime.now(),
        lastRunAt: _dateFrom(json['lastRunAt']),
        nextRunAt: _dateFrom(json['nextRunAt']),
        lastState: _stateFrom(json['lastState']),
        lastError: json['lastError'] as String?,
        consecutiveFailures:
            (json['consecutiveFailures'] as num?)?.toInt() ?? 0,
        lastSummary: json['lastSummary'] is Map
            ? Map<String, dynamic>.from(json['lastSummary'])
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _dateFrom(Object? value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  static TaskRunState _stateFrom(Object? value) {
    if (value is String) {
      for (final state in TaskRunState.values) {
        if (state.name == value) {
          return state;
        }
      }
    }
    return TaskRunState.never;
  }

  @override
  String toString() =>
      'TaskDefinition($id, $typeKey, "$name", ${schedule.description})';
}

/// One execution attempt, kept for the history view.
class TaskRunRecord {
  const TaskRunRecord({
    this.rowId,
    required this.taskId,
    required this.startedAt,
    this.finishedAt,
    this.state = TaskRunState.running,
    this.message,
    this.error,
    this.summary,
  });

  /// SQLite rowid; null until the record has been inserted.
  final int? rowId;

  final String taskId;

  final DateTime startedAt;

  final DateTime? finishedAt;

  final TaskRunState state;

  /// Short human-readable description, e.g. `Checked 12 sources`.
  final String? message;

  final String? error;

  /// Machine-readable counters, e.g. `{"sourcesChecked": 12, "newComics": 3}`.
  final Map<String, dynamic>? summary;

  Duration? get duration {
    final end = finishedAt;
    if (end == null) {
      return null;
    }
    return end.difference(startedAt);
  }

  bool get isFinished => state != TaskRunState.running;

  TaskRunRecord copyWith({
    int? rowId,
    DateTime? finishedAt,
    TaskRunState? state,
    String? message,
    String? error,
    Map<String, dynamic>? summary,
  }) {
    return TaskRunRecord(
      rowId: rowId ?? this.rowId,
      taskId: taskId,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      state: state ?? this.state,
      message: message ?? this.message,
      error: error ?? this.error,
      summary: summary ?? this.summary,
    );
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'startedAt': startedAt.millisecondsSinceEpoch,
        'finishedAt': finishedAt?.millisecondsSinceEpoch,
        'state': state.name,
        'message': message,
        'error': error,
        'summary': summary,
      };

  static TaskRunRecord? fromJson(Map<String, dynamic> json) {
    try {
      final taskId = json['taskId'];
      if (taskId is! String || taskId.isEmpty) {
        return null;
      }
      return TaskRunRecord(
        taskId: taskId,
        startedAt: TaskDefinition._dateFrom(json['startedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        finishedAt: TaskDefinition._dateFrom(json['finishedAt']),
        state: TaskDefinition._stateFrom(json['state']),
        message: json['message'] as String?,
        error: json['error'] as String?,
        summary: json['summary'] is Map
            ? Map<String, dynamic>.from(json['summary'])
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Result a runner reports back to the engine.
class TaskRunOutcome {
  const TaskRunOutcome({
    required this.success,
    this.message,
    this.error,
    this.summary,
    this.requestRetry = false,
    this.skipped = false,
  });

  /// A run that deliberately did nothing, e.g. the feature is unconfigured.
  const TaskRunOutcome.skipped(String reason)
      : success = true,
        message = reason,
        error = null,
        summary = null,
        requestRetry = false,
        skipped = true;

  const TaskRunOutcome.failed(String message, {this.summary})
      : success = false,
        message = null,
        error = message,
        requestRetry = false,
        skipped = false;

  final bool success;

  final String? message;

  final String? error;

  final Map<String, dynamic>? summary;

  /// Ask the engine to schedule a retry under the task's retry policy.
  final bool requestRetry;

  final bool skipped;
}

/// Per-run services handed to a runner.
class TaskRunContext {
  TaskRunContext({
    required this.task,
    required void Function(String message) log,
    required bool Function() isCancelled,
    required void Function({double? progress, String? message}) reportProgress,
  })  : _log = log,
        _isCancelled = isCancelled,
        _reportProgress = reportProgress;

  final TaskDefinition task;

  final void Function(String message) _log;

  final bool Function() _isCancelled;

  final void Function({double? progress, String? message}) _reportProgress;

  /// Appends to this run's log.
  void log(String message) => _log(message);

  /// Polled by long-running runners so a stop request takes effect promptly.
  bool get isCancelled => _isCancelled();

  /// Reports progress in the range 0-1 for the queue view.
  void reportProgress({double? progress, String? message}) =>
      _reportProgress(progress: progress, message: message);

  /// Throws [TaskCancelledException] if the run has been cancelled.
  void throwIfCancelled() {
    if (isCancelled) {
      throw const TaskCancelledException();
    }
  }

  /// Convenience reader for runner options with a default.
  T configValue<T>(String key, T fallback) {
    final value = task.config[key];
    if (value is T) {
      return value;
    }
    if (value is num && fallback is int) {
      return value.toInt() as T;
    }
    if (value is num && fallback is double) {
      return value.toDouble() as T;
    }
    return fallback;
  }

  List<String> configStringList(String key) {
    final value = task.config[key];
    if (value is List) {
      return value.whereType<String>().toList();
    }
    return const [];
  }
}

/// Thrown by a runner when it observes a cancellation request.
class TaskCancelledException implements Exception {
  const TaskCancelledException();

  @override
  String toString() => 'Task cancelled';
}

/// A kind of scheduled task.
///
/// Implementations live in `lib/foundation/scheduler/tasks/` and are registered
/// with [TaskRunnerRegistry].
abstract class SchedulableRunner {
  /// Stable identifier persisted in `scheduled_tasks.type_key`.
  String get typeKey;

  /// Name shown in the task editor.
  String get displayName;

  /// One-line explanation shown in the task editor.
  String get description;

  /// Options for a newly created task of this type.
  Map<String, dynamic> defaultConfig();

  /// Returns an error message when [config] is unusable, else null.
  String? validateConfig(Map<String, dynamic> config) => null;

  /// Executes one run. Must not throw for ordinary failures; return
  /// [TaskRunOutcome.failed] instead. Throwing is treated as a failure too.
  Future<TaskRunOutcome> run(TaskRunContext context);
}

/// Registry of available runners.
///
/// A plain static map keeps the scheduler free of dependency-injection
/// plumbing; runners are registered once by
/// `registerBuiltInTaskRunners()`.
class TaskRunnerRegistry {
  TaskRunnerRegistry._();

  static final Map<String, SchedulableRunner> _runners = {};

  static void register(SchedulableRunner runner) {
    _runners[runner.typeKey] = runner;
  }

  static SchedulableRunner? find(String typeKey) => _runners[typeKey];

  static bool has(String typeKey) => _runners.containsKey(typeKey);

  static List<SchedulableRunner> all() {
    final list = _runners.values.toList();
    list.sort((a, b) => a.displayName.compareTo(b.displayName));
    return list;
  }

  /// Test seam: clears every registration.
  static void clear() => _runners.clear();
}

/// Encodes a task list for export or debugging.
String encodeTaskList(List<TaskDefinition> tasks) =>
    jsonEncode(tasks.map((t) => t.toJson()).toList());

/// Decodes [encodeTaskList] output, skipping unusable entries.
///
/// Never throws: malformed input yields an empty list, because this is used
/// while loading persisted state where a bad blob must not break startup.
List<TaskDefinition> decodeTaskList(String data) {
  Object? decoded;
  try {
    decoded = jsonDecode(data);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) {
    return const [];
  }
  final result = <TaskDefinition>[];
  for (final entry in decoded) {
    if (entry is Map) {
      final task = TaskDefinition.fromJson(Map<String, dynamic>.from(entry));
      if (task != null) {
        result.add(task);
      }
    }
  }
  return result;
}

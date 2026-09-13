import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scheduler/schedule.dart';
import 'package:venera/foundation/scheduler/store.dart';
import 'package:venera/foundation/scheduler/task.dart';
import 'package:venera/foundation/scheduler/tasks/builtin.dart';

/// The scheduler: decides which task is due, runs it, and records the outcome.
///
/// Design constraints that shaped this class:
///
/// * Tasks hit third-party comic sites, so execution is **serialised to one
///   task at a time** and the tick interval is deliberately coarse. This mirrors
///   the throttling already in `follow_updates.dart:119-137`.
/// * Run state is persisted, so a run that is interrupted by app shutdown is
///   visible afterwards as a stale `running` record rather than silently
///   vanishing. [init] reconciles those.
/// * Nothing here may throw into the host app. Every entry point catches and
///   converts failures into a recorded run state.
class SchedulerEngine with ChangeNotifier {
  SchedulerEngine._();

  static SchedulerEngine? _instance;

  factory SchedulerEngine() => _instance ??= SchedulerEngine._();

  /// How often the engine looks for due tasks.
  static const Duration tickInterval = Duration(seconds: 20);

  /// How long after start the first due-task check runs.
  ///
  /// Startup is busy (comic sources are parsed by QuickJS, translations and tag
  /// data are loaded), so the first check waits a moment rather than competing
  /// with it. Without this, an overdue task or one with `runOnStart` would wait
  /// a full [tickInterval] before being noticed.
  static const Duration initialCheckDelay = Duration(seconds: 3);

  /// Per-task log lines retained in memory for the queue view.
  static const int maxLogLinesPerTask = 200;

  /// Run records retained per task in the database.
  static const int runsPerTask = SchedulerStore.defaultRunsPerTask;

  final SchedulerStore _store = SchedulerStore();

  final Map<String, List<String>> _logs = {};

  List<TaskDefinition> _tasks = [];

  Timer? _timer;

  /// One-shot kick so the first check does not wait a full tick interval.
  Timer? _initialTimer;

  bool _started = false;

  bool _disposed = false;

  bool _isExecuting = false;

  String? _activeTaskId;

  TaskRunRecord? _activeRun;

  double? _activeProgress;

  String? _activeMessage;

  bool _cancelRequested = false;

  // ---------------------------------------------------------------------------
  // Read-only state
  // ---------------------------------------------------------------------------

  /// All tasks, in execution order.
  List<TaskDefinition> get tasks => List.unmodifiable(_tasks);

  /// Whether the engine is initialised and its timer is live.
  bool get isStarted => _started;

  /// The task currently executing, if any.
  String? get activeTaskId => _activeTaskId;

  /// The run currently executing, if any.
  TaskRunRecord? get activeRun => _activeRun;

  /// Progress of the active run in the range 0-1, when the runner reports it.
  double? get activeProgress => _activeProgress;

  /// Status message of the active run.
  String? get activeMessage => _activeMessage;

  bool get isExecuting => _isExecuting;

  bool get isBusy => _isExecuting;

  /// Whether a stop has been requested for the active run.
  bool get isCancelRequested => _cancelRequested;

  int get enabledCount => _tasks.where((t) => t.enabled).length;

  TaskDefinition? findTask(String id) {
    for (final task in _tasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  /// The soonest scheduled run across all enabled tasks.
  DateTime? get nextScheduledRun {
    DateTime? soonest;
    for (final task in _tasks) {
      final next = task.nextRunAt;
      if (!task.enabled || next == null) {
        continue;
      }
      if (soonest == null || next.isBefore(soonest)) {
        soonest = next;
      }
    }
    return soonest;
  }

  /// Recent in-memory log lines for [taskId], oldest first.
  List<String> logFor(String taskId) =>
      List.unmodifiable(_logs[taskId] ?? const <String>[]);

  void clearLogFor(String taskId) {
    _logs.remove(taskId);
    _notify();
  }

  /// Persisted run history for [taskId], newest first.
  List<TaskRunRecord> runsFor(String taskId, {int limit = 20}) {
    if (!_store.isOpen) {
      return const [];
    }
    return _store.loadRuns(taskId: taskId, limit: limit);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens the database, loads tasks, and starts the tick timer.
  ///
  /// Never throws: a broken task store must not prevent the app from starting.
  /// Pass `startTimer: false` to drive the engine manually (used by tests).
  Future<void> init({
    required String databasePath,
    bool startTimer = true,
  }) async {
    if (_started) {
      return;
    }
    try {
      // Runners must exist before any persisted task is dispatched.
      registerBuiltInTaskRunners();
      _store.open(databasePath);
      _tasks = _store.loadTasks();
      _recoverInterruptedRuns();
      _markRunOnStartTasksDue();
      _scheduleMissingNextRuns();
      _started = true;
      if (startTimer) {
        _timer = Timer.periodic(tickInterval, (_) => _tick());
        _initialTimer = Timer(initialCheckDelay, _tick);
      }
      Log.info(
        'Scheduler',
        'Started with ${_tasks.length} task(s), $enabledCount enabled',
      );
    } catch (e, s) {
      Log.error('Scheduler', 'Failed to start scheduler: $e', s);
    }
    _notify();
  }

  /// Convenience wrapper that resolves the database path from [dataPath].
  Future<void> initWithDataPath(String dataPath) =>
      init(databasePath: '$dataPath/scheduler.db');

  /// Stops the timer. The database stays open so tasks can still be edited.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _initialTimer?.cancel();
    _initialTimer = null;
    _started = false;
    _notify();
  }

  void close() {
    stop();
    _store.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _initialTimer?.cancel();
    _initialTimer = null;
    _started = false;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// A run interrupted by shutdown is left as `running` in the database. Mark
  /// those as cancelled so the history is honest and the task is rescheduled.
  void _recoverInterruptedRuns() {
    final now = DateTime.now();
    // The task's lastState is only half of it: the matching task_runs row is
    // left `running` too, and would otherwise sit in the history forever.
    _store.closeInterruptedRuns();
    for (final task in List<TaskDefinition>.from(_tasks)) {
      if (task.lastState == TaskRunState.running) {
        _replace(
          task.copyWith(
            lastState: TaskRunState.cancelled,
            lastError: 'Interrupted by app shutdown',
            nextRunAt: task.computeNextRun(now),
          ),
          persist: true,
        );
      }
    }
  }

  /// Brings forward every enabled task that asked to run when the app starts.
  ///
  /// The engine only runs while the app is open, so a task whose interval is
  /// longer than a typical session would otherwise never fire. Marking the task
  /// due moves its next slot to now; the run then reschedules it normally.
  ///
  /// A task that is already overdue is left alone: it will be caught up on the
  /// first check anyway, and re-running it here would duplicate the work.
  void _markRunOnStartTasksDue() {
    final now = DateTime.now();
    final truncated = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    for (final task in List<TaskDefinition>.from(_tasks)) {
      if (!task.enabled || !task.runOnStart) {
        continue;
      }
      final next = task.nextRunAt;
      if (next != null && !next.isAfter(now)) {
        continue; // already due; the normal catch-up will pick it up
      }
      _replace(task.copyWith(nextRunAt: truncated), persist: true);
    }
  }

  void _scheduleMissingNextRuns() {
    final now = DateTime.now();
    for (final task in List<TaskDefinition>.from(_tasks)) {
      if (task.enabled && task.nextRunAt == null) {
        _replace(task.copyWith(nextRunAt: task.computeNextRun(now)),
            persist: true);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Task CRUD
  // ---------------------------------------------------------------------------

  /// Creates and persists a new task.
  ///
  /// Returns null when [typeKey] is not a registered runner or [schedule] is
  /// invalid.
  TaskDefinition? createTask({
    required String typeKey,
    required String name,
    required ScheduleSpec schedule,
    Map<String, dynamic>? config,
    TaskRetryPolicy retry = const TaskRetryPolicy(),
    bool enabled = true,
    bool runOnStart = false,
  }) {
    final runner = TaskRunnerRegistry.find(typeKey);
    if (runner == null || schedule.validationError() != null) {
      return null;
    }
    // Validate the config too. Without this, a task created with no explicit
    // config would inherit a runner default that may itself be incomplete
    // (IncrementalDownloadRunner's default has no favourites folder), and the
    // invalid task would be persisted and fail on every run.
    final effectiveConfig = config ?? runner.defaultConfig();
    if (runner.validateConfig(effectiveConfig) != null) {
      return null;
    }
    final now = DateTime.now();
    final task = TaskDefinition(
      id: const Uuid().v4(),
      typeKey: typeKey,
      name: name.trim().isEmpty ? runner.displayName : name.trim(),
      schedule: schedule,
      enabled: enabled,
      runOnStart: runOnStart,
      config: effectiveConfig,
      retry: retry,
      sortOrder: _tasks.length,
      createdAt: now,
      nextRunAt: enabled ? schedule.nextAfter(now) ?? now.add(const Duration(hours: 24)) : null,
    );
    _tasks.add(task);
    _persist(task);
    _notify();
    return task;
  }

  /// Replaces an existing task. A changed schedule reschedules the next run.
  void updateTask(TaskDefinition task) {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index < 0) {
      return;
    }
    final previous = _tasks[index];
    var updated = task;
    if (!task.enabled) {
      // Disabling always clears the pending slot.
      updated = updated.copyWith(clearNextRunAt: true);
    } else if (previous.schedule != task.schedule ||
        previous.nextRunAt == null) {
      updated = updated.copyWith(nextRunAt: task.computeNextRun(DateTime.now()));
    }
    _tasks[index] = updated;
    _persist(updated);
    _notify();
  }

  void setEnabled(String id, bool enabled) {
    final task = findTask(id);
    if (task == null) {
      return;
    }
    updateTask(task.copyWith(
      enabled: enabled,
      nextRunAt: enabled ? task.computeNextRun(DateTime.now()) : null,
      clearNextRunAt: !enabled,
    ));
  }

  void deleteTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    _logs.remove(id);
    if (_store.isOpen) {
      _store.deleteTask(id);
    }
    _notify();
  }

  void reorder(List<String> orderedIds) {
    final byId = {for (final task in _tasks) task.id: task};
    final reordered = <TaskDefinition>[];
    for (final id in orderedIds) {
      final task = byId.remove(id);
      if (task != null) {
        reordered.add(task);
      }
    }
    // Anything not mentioned keeps its relative order at the end.
    reordered.addAll(byId.values);
    for (var i = 0; i < reordered.length; i++) {
      reordered[i] = reordered[i].copyWith(sortOrder: i);
    }
    _tasks = reordered;
    if (_store.isOpen) {
      _store.reorder(orderedIds);
    }
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /// Forces [id] to run as soon as the engine is free.
  ///
  /// A manual run does not consume the pending scheduled slot for calendar
  /// schedules; interval schedules are re-anchored because the interval is
  /// measured from the previous run.
  Future<void> runNow(String id) async {
    if (_isExecuting || _activeTaskId != null) {
      return;
    }
    final task = findTask(id);
    if (task == null) {
      return;
    }
    await _execute(task, manual: true);
  }

  /// Requests cancellation of the active run.
  ///
  /// Cooperative: a runner only stops once it polls
  /// [TaskRunContext.isCancelled]. The current image download, network request
  /// or API call still has to finish.
  void requestCancel() {
    if (!_isExecuting) {
      return;
    }
    _cancelRequested = true;
    _activeMessage = 'Stopping...';
    _notify();
  }

  /// Finds and runs the next due task, if the engine is idle.
  Future<void> runDueTasks() async {
    if (_isExecuting) {
      return;
    }
    final now = DateTime.now();
    final due = _tasks
        .where((t) => t.enabled && t.nextRunAt != null && !t.nextRunAt!.isAfter(now))
        .toList()
      ..sort((a, b) {
        final byTime = a.nextRunAt!.compareTo(b.nextRunAt!);
        return byTime != 0 ? byTime : a.sortOrder.compareTo(b.sortOrder);
      });
    if (due.isEmpty) {
      return;
    }
    await _execute(due.first, manual: false);
  }

  void _tick() {
    if (!_started || _isExecuting) {
      return;
    }
    // Deliberately not awaited: the tick must not queue up. _isExecuting
    // guards against overlap.
    unawaited(runDueTasks());
  }

  Future<void> _execute(TaskDefinition task, {required bool manual}) async {
    final runner = TaskRunnerRegistry.find(task.typeKey);
    final startedAt = DateTime.now();

    if (runner == null) {
      _replace(
        task.copyWith(
          lastRunAt: startedAt,
          lastState: TaskRunState.failed,
          lastError: 'Unknown task type "${task.typeKey}"',
          nextRunAt: task.computeNextRun(startedAt),
        ),
        persist: true,
      );
      _notify();
      return;
    }

    _isExecuting = true;
    _activeTaskId = task.id;
    _cancelRequested = false;
    _activeProgress = null;
    _activeMessage = 'Starting...';

    var run = TaskRunRecord(taskId: task.id, startedAt: startedAt);
    if (_store.isOpen) {
      try {
        run = run.copyWith(rowId: _store.insertRun(run));
      } catch (e, s) {
        Log.error('Scheduler', 'Failed to record run start: $e', s);
      }
    }
    _activeRun = run;

    _replace(
      task.copyWith(
        lastRunAt: startedAt,
        lastState: TaskRunState.running,
        clearLastError: true,
      ),
      persist: true,
    );
    _appendLog(task.id, 'Run started${manual ? ' (manual)' : ''}');
    Log.info('Scheduler', 'Running task "${task.name}"');
    _notify();

    TaskRunOutcome outcome;
    var cancelled = false;
    try {
      outcome = await runner.run(_buildContext(task));
    } on TaskCancelledException {
      cancelled = true;
      outcome = const TaskRunOutcome(
        success: false,
        error: 'Cancelled',
        message: 'Stopped by the user',
      );
    } catch (e, s) {
      Log.error('Scheduler', 'Task "${task.name}" threw: $e', s);
      outcome = TaskRunOutcome.failed(e.toString());
    }

    final finishedAt = DateTime.now();
    // A cancellation is either thrown by the runner or requested through the
    // engine; both must be recorded as cancelled rather than failed.
    final wasCancelled = cancelled || _cancelRequested;
    final state = outcome.success
        ? (outcome.skipped ? TaskRunState.skipped : TaskRunState.success)
        : (wasCancelled ? TaskRunState.cancelled : TaskRunState.failed);

    run = run.copyWith(
      finishedAt: finishedAt,
      state: state,
      message: outcome.message,
      error: outcome.error,
      summary: outcome.summary,
    );
    if (_store.isOpen) {
      try {
        _store.finishRun(run);
        _store.pruneRuns(keepPerTask: runsPerTask);
      } catch (e, s) {
        Log.error('Scheduler', 'Failed to record run result: $e', s);
      }
    }

    // Bookkeeping: consecutive failures drive the retry backoff.
    final current = findTask(task.id) ?? task;
    final failures =
        outcome.success ? 0 : current.consecutiveFailures + 1;
    var updated = current.copyWith(
      lastState: state,
      consecutiveFailures: failures,
      lastError: outcome.error,
      lastSummary: outcome.summary,
      clearLastSummary: outcome.summary == null,
    );

    DateTime? next;
    if (!outcome.success && outcome.requestRetry) {
      next = updated.computeRetryRun(finishedAt);
    }
    if (next == null) {
      // A manual run must not push back an already-scheduled calendar slot.
      final pending = updated.nextRunAt;
      final keepPending = manual &&
          pending != null &&
          pending.isAfter(finishedAt) &&
          updated.schedule.type != ScheduleType.interval;
      next = keepPending ? pending : updated.computeNextRun(finishedAt);
    }
    updated = updated.copyWith(
      nextRunAt: updated.enabled ? next : null,
      clearNextRunAt: !updated.enabled,
    );
    _replace(updated, persist: true);

    _appendLog(
      task.id,
      'Run finished: ${state.name}'
      '${outcome.message == null ? '' : ' - ${outcome.message}'}'
      '${outcome.error == null ? '' : ' - ${outcome.error}'}',
    );
    Log.info(
      'Scheduler',
      'Task "${task.name}" finished: ${state.name}',
    );

    _isExecuting = false;
    _activeTaskId = null;
    _activeRun = null;
    _activeProgress = null;
    _activeMessage = null;
    _cancelRequested = false;
    _notify();
  }

  TaskRunContext _buildContext(TaskDefinition task) {
    return TaskRunContext(
      task: task,
      log: (message) {
        _appendLog(task.id, message);
        _activeMessage = message;
        _notify();
      },
      isCancelled: () => _cancelRequested,
      reportProgress: ({double? progress, String? message}) {
        if (progress != null) {
          _activeProgress = progress.clamp(0.0, 1.0);
        }
        if (message != null) {
          _activeMessage = message;
        }
        _notify();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _replace(TaskDefinition task, {bool persist = false}) {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      _tasks[index] = task;
    } else {
      _tasks.add(task);
    }
    if (persist) {
      _persist(task);
    }
  }

  void _persist(TaskDefinition task) {
    if (!_store.isOpen) {
      return;
    }
    try {
      _store.saveTask(task);
    } catch (e, s) {
      Log.error('Scheduler', 'Failed to persist task "${task.id}": $e', s);
    }
  }

  void _appendLog(String taskId, String message) {
    final lines = _logs.putIfAbsent(taskId, () => <String>[]);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    lines.add(
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $message',
    );
    while (lines.length > maxLogLinesPerTask) {
      lines.removeAt(0);
    }
  }
}

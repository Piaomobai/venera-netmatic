import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:venera_netmatic/network/download.dart';
import 'cli.dart';
import 'download_queue.dart';
import 'jobs.dart';
import 'service_queue.dart';

/// One durable download intent owned by the existing profile worker.
/// Only a single-book transfer occupies the queue's write slot.
class DownloadSession {
  DownloadSession({
    required this.directory,
    required this.tasks,
    required this.flush,
    required this.jobs,
    required this.queue,
    this.now = DateTime.now,
  });
  final String directory;
  final List<DownloadTask> Function() tasks;
  final Future<void> Function() flush;
  final CliJobs jobs;
  final ServiceQueue queue;
  final DateTime Function() now;
  String? id;
  bool enabled = false;
  String state = 'idle';
  String? stopReason;
  int maxAttempts = 3;
  int retryDelaySeconds = 60;
  int idleTimeoutSeconds = 300;
  int? maxRuntimeSeconds;
  DateTime? deadline;
  DateTime? lastProgressAt;
  int completed = 0;
  Map<String, dynamic>? lastError;
  final Map<String, Map<String, dynamic>> _attempts = {};
  String? _stepId;
  String? _taskKey;
  final Set<String> _ownCancellations = {};
  bool _closing = false;
  bool _ticking = false;
  Future<void> _changes = Future<void>.value();

  String _key(DownloadTask task) =>
      jsonEncode([task.comicType.sourceKey, task.id]);

  Future<T> _change<T>(Future<T> Function() action) {
    final operation = _changes.then((_) => action());
    _changes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Map<String, dynamic> get status {
    final pending = tasks();
    final failed = pending
        .where((t) => _attempts[_key(t)]?['exhausted'] == true)
        .length;
    final retries =
        pending
            .map((t) => _attempts[_key(t)]?['nextRetryAt'])
            .whereType<String>()
            .map(DateTime.parse)
            .toList()
          ..sort();
    return {
      'sessionId': id,
      'state': state,
      'enabled': enabled,
      'remaining': pending.length,
      'completed': completed,
      'failed': failed,
      'maxAttempts': maxAttempts,
      'retryDelaySeconds': retryDelaySeconds,
      'idleTimeoutSeconds': idleTimeoutSeconds,
      'maxRuntimeSeconds': maxRuntimeSeconds,
      'executionDeadlineAt': deadline?.toIso8601String(),
      'lastProgressAt': lastProgressAt?.toIso8601String(),
      'stopReason': stopReason,
      'lastError': lastError,
      'nextRetryAt': retries.firstOrNull?.toIso8601String(),
      'activeRequestId': _stepId,
      'activeTask': queue.records[_stepId]?.progress,
      'items': pending
          .map(
            (task) => {
              'sourceKey': task.comicType.sourceKey,
              'comicId': task.id,
              ...?_attempts[_key(task)],
            },
          )
          .toList(),
    };
  }

  Future<void> load() async {
    final file = File('$directory/download_session.json');
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['schemaVersion'] != 1) {
      throw const FormatException('Unsupported download session');
    }
    id = data['sessionId'] as String?;
    enabled = data['enabled'] as bool;
    state = enabled ? 'running' : data['state'] as String;
    stopReason = data['stopReason'] as String?;
    completed = data['completed'] as int;
    maxAttempts = data['maxAttempts'] as int;
    retryDelaySeconds = data['retryDelaySeconds'] as int;
    idleTimeoutSeconds = data['idleTimeoutSeconds'] as int;
    maxRuntimeSeconds = data['maxRuntimeSeconds'] as int?;
    deadline = DateTime.tryParse(data['executionDeadlineAt'] as String? ?? '');
    lastProgressAt = DateTime.tryParse(data['lastProgressAt'] as String? ?? '');
    lastError = (data['lastError'] as Map?)?.cast<String, dynamic>();
    final entries = (data['attempts'] as Map).cast<String, dynamic>();
    for (final entry in entries.entries) {
      _attempts[entry.key] = Map<String, dynamic>.from(entry.value as Map);
    }
    if (maxAttempts < 1 || retryDelaySeconds < 1 || idleTimeoutSeconds < 1) {
      throw const FormatException('Invalid download session policy');
    }
    // Reattach to a durable queued step instead of submitting a duplicate
    // after a crash between request acceptance and starting its transfer.
    for (final request in queue.records.values.toList()) {
      if (request.origin != 'download-session' ||
          request.request.command != 'downloads step' ||
          request.state != 'queued') {
        continue;
      }
      if (enabled && _stepId == null) {
        _stepId = request.id;
        _taskKey = jsonEncode(request.request.arguments);
      } else {
        await queue.cancel(request.id);
      }
    }
  }

  Future<void> _save() async {
    try {
      final file = File('$directory/download_session.json.tmp');
      await file.writeAsString(
        jsonEncode({...status, 'schemaVersion': 1, 'attempts': _attempts}),
        flush: true,
      );
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['600', file.path]);
        if (result.exitCode != 0) {
          throw const FileSystemException('Cannot protect download session');
        }
      }
      await file.rename('$directory/download_session.json');
    } catch (_) {
      throw const CliException(
        'persistence_failed',
        'Could not save the download session.',
      );
    }
  }

  Future<CliResult> start(CliRequest request, {bool resume = false}) => _change(
    () async {
      if (_closing) throw const CliException('stopping', 'Worker is stopping.');
      if (enabled || (!resume && state == 'paused')) return CliResult(status);
      final attempts = request.integer(
        'max-attempts',
        maxAttempts,
        min: 1,
        max: 20,
      );
      final delay = request.integer(
        'retry-delay',
        retryDelaySeconds,
        min: 1,
        max: 3600,
      );
      final idle = request.integer(
        'idle-timeout',
        idleTimeoutSeconds,
        min: 1,
        max: 3600,
      );
      final runtime = request.integer(
        'max-runtime',
        maxRuntimeSeconds ?? 0,
        min: 0,
        max: 86400,
      );
      if (!resume || id == null) {
        id = const Uuid().v4();
        completed = 0;
      }
      _attempts.clear();
      maxAttempts = attempts;
      retryDelaySeconds = delay;
      idleTimeoutSeconds = idle;
      maxRuntimeSeconds = runtime == 0 ? null : runtime;
      deadline = maxRuntimeSeconds == null
          ? null
          : now().toUtc().add(Duration(seconds: maxRuntimeSeconds!));
      enabled = true;
      state = 'running';
      stopReason = null;
      lastError = null;
      try {
        await _save();
      } catch (_) {
        enabled = false;
        state = 'paused';
        stopReason = 'persistence_failed';
        rethrow;
      }
      // Hand a legacy foreground drain to the durable session after safe pause.
      for (final request in queue.records.values.toList()) {
        if (request.state == 'running' &&
            (request.request.command == 'downloads run' ||
                (request.request.command == 'downloads add' &&
                    !request.isEnqueueOnly &&
                    request.progress?['comicId'] != null))) {
          await queue.cancel(request.id);
        }
      }
      return CliResult(status);
    },
  );

  Future<CliResult> stop() async {
    try {
      await _change(() async {
        enabled = false;
        state = 'paused';
        stopReason = 'user_paused';
        await _save();
      });
    } finally {
      await _cancelStep();
    }
    return CliResult(status);
  }

  Future<void> forget(String sourceKey, String comicId) => _change(() async {
    _attempts.remove(jsonEncode([sourceKey, comicId]));
    await _save();
  });

  /// Called by the worker's timer; never waits for a whole transfer.
  Future<void> tick() async {
    if (_closing || _ticking) return;
    _ticking = true;
    try {
      await _change(() async {
        if (_closing) return;
        final previous = queue.records[_stepId];
        if (previous != null &&
            ['queued', 'running'].contains(previous.state)) {
          if (enabled &&
              deadline != null &&
              !now().toUtc().isBefore(deadline!)) {
            enabled = false;
            state = 'paused';
            stopReason = 'runtime_limit';
            await _save();
            _ownCancellations.add(previous.id);
            await queue.cancel(previous.id);
          }
          return;
        }
        if (_stepId != null) {
          final key = _taskKey!;
          final result = previous?.result;
          final pending = tasks().any((task) => _key(task) == key);
          if (!pending) {
            if (result?.exitCode == 0 && result?.status != 'skipped') {
              completed++;
            }
            _attempts.remove(key);
            lastProgressAt = now().toUtc();
          } else if (result?.code == 'cancelled' &&
              enabled &&
              !_ownCancellations.contains(_stepId)) {
            enabled = false;
            state = 'paused';
            stopReason = 'cancelled';
          } else if (result != null &&
              result.exitCode != 0 &&
              ![
                'timeout',
                'cancelled',
                'queue_timeout',
              ].contains(result.code)) {
            final results = (result.data as Map?)?['jobs'] as List?;
            final error = results?.firstOrNull?['error'] as Map?;
            lastError =
                error?.cast<String, dynamic>() ??
                {
                  'code': result.code ?? 'download_failed',
                  'message': 'Download could not finish.',
                  'retryable': true,
                };
            final attempts = (_attempts[key]?['attempts'] as int? ?? 0) + 1;
            final exhausted =
                attempts >= maxAttempts || lastError!['retryable'] == false;
            final delay =
                (retryDelaySeconds * (1 << (attempts - 1).clamp(0, 10))).clamp(
                  1,
                  3600,
                );
            _attempts[key] = {
              'attempts': attempts,
              'exhausted': exhausted,
              'lastError': lastError,
              if (!exhausted)
                'nextRetryAt': now()
                    .toUtc()
                    .add(Duration(seconds: delay))
                    .toIso8601String(),
            };
            if (enabled &&
                (lastError!['pauseSession'] == true ||
                    result.code == 'persistence_failed')) {
              enabled = false;
              state = 'paused';
              stopReason = result.code == 'persistence_failed'
                  ? result.code
                  : lastError!['code'] as String;
            }
          }
          _ownCancellations.remove(_stepId);
          _stepId = null;
          _taskKey = null;
          await _save();
        }
        if (!enabled) return;
        if (deadline != null && !now().toUtc().isBefore(deadline!)) {
          enabled = false;
          state = 'paused';
          stopReason = 'runtime_limit';
          await _save();
          return;
        }
        final pending = tasks();
        final eligible = pending
            .where((task) => _attempts[_key(task)]?['exhausted'] != true)
            .toList();
        if (eligible.isEmpty) {
          final adding = queue.records.values.any(
            (request) =>
                request.request.command == 'downloads add' &&
                ['queued', 'running'].contains(request.state),
          );
          if (adding) {
            state = 'waiting_enqueue';
            return;
          }
          enabled = false;
          state = pending.isEmpty ? 'completed' : 'completed_with_errors';
          stopReason = pending.isEmpty
              ? 'queue_empty'
              : pending.any(
                  (task) =>
                      _attempts[_key(task)]?['lastError']?['retryable'] ==
                      false,
                )
              ? 'non_retryable_errors'
              : 'retry_limit';
          await _save();
          return;
        }
        final task = eligible.where((task) {
          final next = _attempts[_key(task)]?['nextRetryAt'] as String?;
          return next == null || !DateTime.parse(next).isAfter(now().toUtc());
        }).firstOrNull;
        if (task == null) {
          state = 'waiting_retry';
          return;
        }
        state = 'running';
        final step = await queue.submit([
          'downloads',
          'step',
          task.comicType.sourceKey,
          task.id,
        ], origin: 'download-session');
        _stepId = step.id;
        _taskKey = _key(task);
      });
    } on CliException catch (error) {
      if (error.code == 'queue_full') {
        state = 'waiting_executor';
      } else {
        enabled = false;
        state = 'paused';
        stopReason = 'persistence_failed';
        await _cancelStep();
      }
    } catch (_) {
      // A failed journal/queue write must leave no uncontrolled downloader.
      enabled = false;
      state = 'paused';
      stopReason = 'persistence_failed';
      await _cancelStep();
    } finally {
      _ticking = false;
    }
  }

  Future<CliResult> executeStep(
    CliRequest request,
    CliControl control,
    void Function(Map<String, dynamic>) report,
  ) async {
    if (!enabled || _closing) return const CliResult(null, status: 'skipped');
    final task = tasks()
        .where(
          (task) =>
              task.comicType.sourceKey == request.arguments[0] &&
              task.id == request.arguments[1],
        )
        .firstOrNull;
    if (task == null) return const CliResult(null, status: 'skipped');
    return CliDownloadQueue(
      tasks: tasks,
      flush: flush,
      jobs: jobs,
      control: control,
      report: (progress) {
        if ((progress['bytesPerSecond'] as num? ?? 0) > 0) {
          lastProgressAt = now().toUtc();
        }
        report(progress);
      },
    ).drain(
      only: task,
      idleTimeout: Duration(seconds: idleTimeoutSeconds),
    );
  }

  Future<void> close() async {
    _closing = true;
    try {
      await _change(_save); // Preserve resume intent across a worker restart.
    } finally {
      await _cancelStep();
    }
  }

  Future<void> _cancelStep() async {
    final requests = queue.records.values
        .where(
          (request) =>
              request.id == _stepId ||
              (['queued', 'running'].contains(request.state) &&
                  request.request.command == 'downloads run') ||
              (request.state == 'running' &&
                  request.request.command == 'downloads add' &&
                  !request.isEnqueueOnly &&
                  request.progress?['comicId'] != null) ||
              (request.state == 'running' &&
                  [
                    'scheduler run',
                    'scheduler rundue',
                  ].contains(request.request.command) &&
                  request.progress?['comicId'] != null),
        )
        .toList();
    for (final step in requests) {
      if (step.id == _stepId) _ownCancellations.add(step.id);
      await queue.cancel(step.id);
      await step.running;
    }
  }
}

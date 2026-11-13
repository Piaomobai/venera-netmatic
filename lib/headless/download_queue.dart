import 'dart:async';
import 'package:venera_netmatic/network/download.dart';
import 'cli.dart';
import 'jobs.dart';

/// Stable diagnostics never include signed URLs, headers or source credentials.
Map<String, dynamic> downloadFailure(String message) {
  final text = message.toLowerCase().replaceAll(
    RegExp(r'https?://\S+'),
    '<url>',
  );
  final status =
      RegExp(
        r'(?:status(?:\s+code)?(?:\s+of)?|http)[^0-9]{0,16}(401|403|404|429)\b',
      ).firstMatch(text)?.group(1) ??
      RegExp(r'^\s*(401|403|404|429)\b').firstMatch(text)?.group(1);
  if (status == '401' ||
      text.contains('authentication') ||
      text.contains('not logged in')) {
    return {
      'code': 'authentication_required',
      'message': 'Source authentication needs attention.',
      'retryable': false,
      'pauseSession': true,
    };
  }
  if (text.contains('enospc') ||
      text.contains('no space left') ||
      text.contains('disk full')) {
    return {
      'code': 'storage_full',
      'message': 'Download storage is full.',
      'retryable': false,
      'pauseSession': true,
    };
  }
  if (text.contains('permission denied') ||
      text.contains('read-only file system')) {
    return {
      'code': 'storage_unavailable',
      'message': 'Download storage is not writable.',
      'retryable': false,
      'pauseSession': true,
    };
  }
  if (status == '429') {
    return {
      'code': 'rate_limited',
      'message': 'The source requested a slower request rate.',
      'retryable': true,
    };
  }
  if (status == '404' || status == '403') {
    return {
      'code': 'resource_unavailable',
      'message': 'The source denied access to this resource.',
      'retryable': status == '403',
    };
  }
  if (text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('stalled')) {
    return {
      'code': 'download_stalled',
      'message': 'The download made no progress within its idle limit.',
      'retryable': true,
    };
  }
  return {
    'code': 'download_failed',
    'message': 'Download failed; source or network may be unavailable.',
    'retryable': true,
  };
}

/// The CLI owns queue advancement. A task leaving the list is only successful
/// after its operation and the queue's durable write have both completed.
class CliDownloadQueue {
  CliDownloadQueue({
    required this.tasks,
    required this.flush,
    required this.jobs,
    required this.control,
    required this.report,
  });
  final List<DownloadTask> Function() tasks;
  final Future<void> Function() flush;
  final CliJobs jobs;
  final CliControl control;
  final void Function(Map<String, dynamic>) report;

  Future<String> jobFor(DownloadTask task) async =>
      jobs.pendingDownload(task.comicType.sourceKey, task.id) ??
      await jobs.create('download', {
        'sourceKey': task.comicType.sourceKey,
        'comicId': task.id,
      });

  Future<CliResult> drain({
    DownloadTask? only,
    Duration? idleTimeout = const Duration(minutes: 5),
  }) async {
    final results = <Map<String, dynamic>>[];
    await flush();
    for (final task
        in only == null ? List<DownloadTask>.from(tasks()) : [only]) {
      control.check();
      final id = await jobFor(task);
      await jobs.update(id, 'running');
      final idle = Stopwatch()..start();
      var previousProgress = task.progress;
      var stalled = false;
      void progress() {
        if (task.speed > 0 || task.progress != previousProgress) {
          idle.reset();
          previousProgress = task.progress;
        }
        if (idleTimeout != null && idle.elapsed >= idleTimeout) {
          stalled = true;
          task.pause();
        }
        if (control.cancelled || control.timedOut) task.pause();
        report({
          'jobId': id,
          'sourceKey': task.comicType.sourceKey,
          'comicId': task.id,
          'progress': task.progress,
          'bytesPerSecond': task.speed,
          'state': task.isPaused ? 'stopping' : 'running',
        });
      }

      Timer? timer;
      try {
        final source = task.comicType.comicSource;
        if (source != null) {
          try {
            await control.wait(source.ensureInitialized());
          } on TimeoutException {
            throw const CliException(
              'source_initialization_timeout',
              'The source did not finish initializing.',
            );
          }
        }
        control.check();
        task.resume();
        idle.reset();
        timer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => progress(),
        );
        progress();
        await task.settled;
        await flush();
        if (control.cancelled || control.timedOut) {
          await jobs.update(
            id,
            'paused',
            errorCode: control.timedOut ? 'timeout' : 'cancelled',
          );
          control.check();
        }
        final complete = !task.isError && !tasks().contains(task);
        final state = complete ? 'completed' : 'failed';
        final error = complete
            ? null
            : downloadFailure(stalled ? 'stalled' : task.message);
        await jobs.update(
          id,
          state,
          error: complete ? null : error!['message'] as String,
          errorCode: error?['code'] as String?,
        );
        results.add({
          'jobId': id,
          'state': state,
          'comicId': task.id,
          'sourceKey': task.comicType.sourceKey,
          if (error != null) 'error': error,
        });
      } catch (error) {
        task.pause();
        await task.settled;
        await flush();
        if (!control.cancelled && !control.timedOut) {
          await jobs.update(
            id,
            'failed',
            error: 'Download or persistence failed.',
            errorCode: error is CliException ? error.code : 'download_failed',
          );
        } else {
          await jobs.update(
            id,
            'paused',
            errorCode: control.timedOut ? 'timeout' : 'cancelled',
          );
        }
        control.check();
        rethrow;
      } finally {
        timer?.cancel();
      }
    }
    final failures = results.where((e) => e['state'] == 'failed').length;
    return CliResult(
      {
        'jobs': results,
        'completed': results.length - failures,
        'failed': failures,
      },
      status: failures > 0 ? 'error' : 'success',
      code: failures > 0 ? 'download_failed' : null,
      message: failures > 0
          ? 'Some downloads failed; the queue is saved.'
          : 'Download queue completed.',
      exitCode: failures > 0 ? 1 : 0,
    );
  }
}

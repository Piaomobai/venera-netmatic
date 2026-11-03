import 'dart:async';
import 'package:venera_netmatic/network/download.dart';
import 'cli.dart';
import 'jobs.dart';

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

  Future<CliResult> drain() async {
    final results = <Map<String, dynamic>>[];
    await flush();
    for (final task in List<DownloadTask>.from(tasks())) {
      control.check();
      final id = await jobFor(task);
      await jobs.update(id, 'running');
      task.resume();
      void progress() {
        if (control.cancelled || control.timedOut) task.pause();
        report({
          'jobId': id,
          'sourceKey': task.comicType.sourceKey,
          'comicId': task.id,
          'progress': task.progress,
          'bytesPerSecond': task.speed,
          'state': 'running',
        });
      }

      final timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => progress(),
      );
      try {
        progress();
        await task.settled;
        await flush();
        if (control.cancelled || control.timedOut) {
          await jobs.update(id, 'paused');
          control.check();
        }
        final complete = !task.isError && !tasks().contains(task);
        final state = complete ? 'completed' : 'failed';
        await jobs.update(
          id,
          state,
          error: complete
              ? null
              : 'Download did not complete. Retry with downloads run.',
        );
        results.add({
          'jobId': id,
          'state': state,
          'comicId': task.id,
          'sourceKey': task.comicType.sourceKey,
        });
      } catch (_) {
        task.pause();
        await task.settled;
        await flush();
        if (!control.cancelled && !control.timedOut) {
          await jobs.update(
            id,
            'failed',
            error: 'Download or persistence failed.',
          );
        } else {
          await jobs.update(id, 'paused');
        }
        control.check();
        rethrow;
      } finally {
        timer.cancel();
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

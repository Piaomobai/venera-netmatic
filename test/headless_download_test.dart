import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/download_queue.dart';
import 'package:venera_netmatic/headless/jobs.dart';
import 'package:venera_netmatic/network/download.dart';

class TestDownload extends DownloadTask {
  TestDownload(this.id, {this.type = ComicType.local});
  final ComicType type;
  final started = Completer<void>();
  final finished = Completer<void>();
  bool failed = false;
  bool paused = true;
  @override
  final String id;
  @override
  ComicType get comicType => type;
  @override
  Future<void> get settled => finished.future;
  @override
  bool get isError => failed;
  @override
  bool get isPaused => paused;
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  int get speed => 0;
  @override
  double get progress => 0;
  @override
  void resume() {
    paused = false;
    started.complete();
  }

  @override
  void pause() {
    paused = true;
    if (!finished.isCompleted) finished.complete();
  }

  @override
  void cancel() => pause();
  @override
  Map<String, dynamic> toJson() => {};
  @override
  LocalComic toLocalComic() => throw UnimplementedError();
}

class InitializingDownloadSource implements ComicSource {
  InitializingDownloadSource(this.ready);
  final Completer<void> ready;
  @override
  String get key => 'download-init-fixture';
  @override
  Future<void> ensureInitialized() => ready.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'download diagnostics classify status codes without exposing URLs or confusing IDs',
    () {
      expect(
        downloadFailure('Error: HTTP 401 token=private')['code'],
        'authentication_required',
      );
      expect(
        downloadFailure('Invalid status code: 429')['code'],
        'rate_limited',
      );
      expect(
        downloadFailure('Error: status code of 404')['retryable'],
        isFalse,
      );
      expect(downloadFailure('HTTP 403')['retryable'], isTrue);
      final unrelated = downloadFailure(
        'Connection failed https://server/401/book?token=private',
      );
      expect(unrelated['code'], 'download_failed');
      expect(unrelated.toString(), isNot(contains('private')));
    },
  );
  late Directory temp;
  late CliJobs jobs;
  late List<DownloadTask> tasks;
  late CliControl control;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download-cli-');
    jobs = CliJobs(temp.path);
    tasks = [];
    control = CliControl();
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'restored downloads await source initialization before resuming',
    () async {
      final ready = Completer<void>();
      final source = InitializingDownloadSource(ready);
      ComicSourceManager().add(source);
      try {
        final task = TestDownload('one', type: ComicType(source.key.hashCode));
        tasks.add(task);
        final runner = CliDownloadQueue(
          tasks: () => tasks,
          flush: () async {},
          jobs: jobs,
          control: control,
          report: (_) {},
        );
        final operation = runner.drain();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(task.started.isCompleted, isFalse);
        ready.complete();
        await task.started.future;
        tasks.remove(task);
        task.finished.complete();
        expect((await operation).exitCode, 0);
      } finally {
        ComicSourceManager().remove(source.key);
      }
    },
  );

  test('waits for transfer finalization and durable queue flush', () async {
    final task = TestDownload('one');
    tasks.add(task);
    final disk = Completer<void>();
    var flushCount = 0;
    final runner = CliDownloadQueue(
      tasks: () => tasks,
      flush: () async {
        if (++flushCount > 1) await disk.future;
      },
      jobs: jobs,
      control: control,
      report: (_) {},
    );
    var returned = false;
    final running = runner.drain().then((value) {
      returned = true;
      return value;
    });
    await task.started.future;
    expect(returned, isFalse);
    tasks.remove(task);
    task.finished.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      returned,
      isFalse,
      reason: 'A task leaving the queue is not enough: disk write is pending',
    );
    disk.complete();
    expect((await running).exitCode, 0);
    expect(jobs.all.single['state'], 'completed');
  });

  test('failed downloads stay resumable and do not report success', () async {
    final task = TestDownload('bad');
    tasks.add(task);
    final runner = CliDownloadQueue(
      tasks: () => tasks,
      flush: () async {},
      jobs: jobs,
      control: control,
      report: (_) {},
    );
    final running = runner.drain();
    await task.started.future;
    task.failed = true;
    task.finished.complete();
    expect((await running).exitCode, 1);
    expect(tasks, contains(task));
    expect(jobs.all.single['state'], 'failed');
  });

  test(
    'cancellation pauses and settles before returning cancellation',
    () async {
      final task = TestDownload('cancel');
      tasks.add(task);
      final runner = CliDownloadQueue(
        tasks: () => tasks,
        flush: () async {},
        jobs: jobs,
        control: control,
        report: (_) {},
      );
      final running = cliGuard(runner.drain);
      await task.started.future;
      control.cancelled = true;
      expect((await running).exitCode, 130);
      expect(task.paused, isTrue);
      expect(tasks, contains(task));
      expect(jobs.all.single['state'], 'paused');
    },
  );
}

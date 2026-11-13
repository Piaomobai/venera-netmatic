import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/commands.dart';
import 'package:venera_netmatic/headless/download_session.dart';
import 'package:venera_netmatic/headless/jobs.dart';
import 'package:venera_netmatic/headless/service_queue.dart';
import 'package:venera_netmatic/network/download.dart';

class SessionDownload extends DownloadTask {
  SessionDownload(this.id, this.items);
  @override
  final String id;
  final List<DownloadTask> items;
  Completer<void> finished = Completer<void>();
  bool failed = false;
  bool paused = true;
  int starts = 0;
  String error = '';
  @override
  ComicType get comicType => ComicType.local;
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
  String get message => error;
  @override
  int get speed => 0;
  @override
  double get progress => 0;
  @override
  void resume() {
    if (!paused) return;
    finished = Completer<void>();
    paused = false;
    failed = false;
    starts++;
  }

  void succeed() {
    items.remove(this);
    paused = true;
    finished.complete();
  }

  void fail(String message) {
    error = message;
    failed = true;
    paused = true;
    finished.complete();
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

Future<void> until(bool Function() check) async {
  for (var n = 0; n < 600; n++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Operation did not settle');
}

void main() {
  late Directory root;
  late List<DownloadTask> items;
  late ServiceQueue queue;
  late DownloadSession session;
  late DateTime clock;
  Completer<void>? additionGate;
  void setupQueue({ServiceQueuePolicy policy = const ServiceQueuePolicy()}) {
    queue = ServiceQueue(
      directory: root.path,
      policy: policy,
      execute: (request, control, report) async {
        if (request.command == 'downloads step') {
          return session.executeStep(request, control, report);
        }
        if (request.command == 'downloads add') {
          await additionGate?.future;
          items.add(SessionDownload(request.arguments[1], items));
        }
        return const CliResult(null);
      },
    );
    session = DownloadSession(
      directory: root.path,
      tasks: () => items,
      flush: () async {},
      jobs: CliJobs(root.path),
      queue: queue,
      now: () => clock,
    );
  }

  Future<void> start([List<String> options = const []]) async {
    await session.start(CliRequest.parse(['downloads', 'start', ...options]));
    await session.tick();
  }

  Future<void> settledStep() async {
    final id = session.status['activeRequestId'] as String?;
    if (id != null) {
      await until(
        () => !['queued', 'running'].contains(queue.records[id]?.state),
      );
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-session-');
    items = [];
    clock = DateTime.utc(2026, 11, 13);
    additionGate = null;
    setupQueue();
  });
  tearDown(() async {
    await session.close();
    await queue.shutdown();
    await root.delete(recursive: true);
  });

  test(
    'one session survives the old execution budget and accepts new items during transfer',
    () async {
      setupQueue(
        policy: const ServiceQueuePolicy(
          executionTimeout: Duration(milliseconds: 40),
        ),
      );
      final first = SessionDownload('first', items);
      items.add(first);
      await start();
      await until(() => first.starts == 1);
      final id = session.id;
      expect(
        (await session.start(CliRequest.parse(['downloads', 'start']))).data,
        containsPair('sessionId', id),
      );
      final step = queue.records[session.status['activeRequestId']]!;
      expect(step.executionTimeout, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(step.state, 'running');
      final added = await queue.submit([
        'downloads',
        'add',
        'fixture',
        'second',
        '--enqueue-only',
      ]);
      await until(() => added.state == 'completed');
      expect(first.isPaused, isFalse);
      expect(items, hasLength(2));
      first.succeed();
      await settledStep();
      await session.tick();
      final second = items.single as SessionDownload;
      await until(() => second.starts == 1);
      second.succeed();
      await settledStep();
      await session.tick();
      expect(session.status, containsPair('state', 'completed'));
      expect(session.status, containsPair('completed', 2));
    },
  );

  test('retry backoff is durable and other comics continue', () async {
    final first = SessionDownload('bad', items);
    final second = SessionDownload('good', items);
    items.addAll([first, second]);
    await start(['--retry-delay', '1']);
    await until(() => first.starts == 1);
    first.fail('429 https://host.invalid/?token=secret');
    await settledStep();
    await session.tick();
    await until(() => second.starts == 1);
    expect(first.starts, 1);
    second.succeed();
    await settledStep();
    await session.tick();
    expect(session.state, 'waiting_retry');
    final saved = await File(
      '${root.path}/download_session.json',
    ).readAsString();
    expect(saved, isNot(contains('secret')));
    clock = clock.add(const Duration(seconds: 2));
    await session.tick();
    await until(() => first.starts == 2);
    first.succeed();
    await settledStep();
    await session.tick();
    expect(session.state, 'completed');
  });

  test(
    'retry exhaustion stops automatic attempts until explicit resume',
    () async {
      final task = SessionDownload('bad', items);
      items.add(task);
      await start(['--max-attempts', '2', '--retry-delay', '1']);
      for (var attempt = 1; attempt <= 2; attempt++) {
        await until(() => task.starts == attempt);
        task.fail('Network offline');
        await settledStep();
        await session.tick();
        clock = clock.add(const Duration(seconds: 10));
        await session.tick();
      }
      expect(session.state, 'completed_with_errors');
      expect(session.enabled, isFalse);
      expect(task.starts, 2);
      await session.start(
        CliRequest.parse(['downloads', 'resume']),
        resume: true,
      );
      await session.tick();
      await until(() => task.starts == 3);
      task.succeed();
      await settledStep();
      await session.tick();
      expect(session.state, 'completed');
    },
  );

  test('manual stop is durable and start cannot silently undo it', () async {
    final task = SessionDownload('one', items);
    items.add(task);
    await start();
    await until(() => task.starts == 1);
    await session.stop();
    expect(task.isPaused, isTrue);
    expect(session.stopReason, 'user_paused');
    await session.start(CliRequest.parse(['downloads', 'start']));
    expect(session.enabled, isFalse);
    await session.close();
    await queue.shutdown();
    setupQueue();
    await queue.load();
    await session.load();
    queue.start();
    await session.tick();
    expect(session.enabled, isFalse);
    expect(task.starts, 1);
  });

  test(
    'worker restart resumes persisted intent without repeating completed comics',
    () async {
      final first = SessionDownload('one', items);
      final second = SessionDownload('two', items);
      items.addAll([first, second]);
      await start();
      await until(() => first.starts == 1);
      first.succeed();
      await settledStep();
      await session.tick();
      await until(() => second.starts == 1);
      await session.close();
      await queue.shutdown();
      setupQueue();
      await queue.load();
      await session.load();
      queue.start();
      expect(session.enabled, isTrue);
      await session.tick();
      await until(() => second.starts == 2);
      expect(first.starts, 1);
      second.succeed();
      await settledStep();
      await session.tick();
      expect(session.state, 'completed');
    },
  );

  test(
    'authentication and disk errors pause the session with safe diagnostics',
    () async {
      final task = SessionDownload('one', items);
      items.add(task);
      await start();
      await until(() => task.starts == 1);
      task.fail('401 password=private https://host.invalid');
      await settledStep();
      await session.tick();
      expect(session.enabled, isFalse);
      expect(session.stopReason, 'authentication_required');
      expect(session.status.toString(), isNot(contains('private')));
    },
  );

  test(
    'optional session runtime stops cooperatively and preserves remaining items',
    () async {
      final task = SessionDownload('one', items);
      items.add(task);
      await start(['--max-runtime', '1']);
      await until(() => task.starts == 1);
      clock = clock.add(const Duration(seconds: 2));
      await session.tick();
      await settledStep();
      expect(task.isPaused, isTrue);
      expect(session.stopReason, 'runtime_limit');
      expect(items, hasLength(1));
    },
  );

  test('an accepted queued step is reused after a worker restart', () async {
    await queue.load(); // Hold execution to model acceptance before a crash.
    final task = SessionDownload('one', items);
    items.add(task);
    await start();
    expect(queue.records.values.single.state, 'queued');
    await queue.shutdown();
    setupQueue();
    await queue.load();
    await session.load();
    queue.start();
    await session.tick();
    await until(() => task.starts == 1);
    expect(
      queue.records.values.where((r) => r.request.command == 'downloads step'),
      hasLength(1),
    );
    task.succeed();
    await settledStep();
    await session.tick();
    expect(session.completed, 1);
  });

  test(
    'idle detection produces a retryable reason instead of hanging',
    () async {
      final task = SessionDownload('stalled', items);
      items.add(task);
      await start(['--idle-timeout', '1']);
      await until(() => task.starts == 1);
      await settledStep();
      await session.tick();
      expect(task.isPaused, isTrue);
      expect(session.lastError?['code'], 'download_stalled');
      expect(session.state, 'waiting_retry');
    },
  );

  test(
    'failure to persist a user stop still pauses the active transfer',
    () async {
      final task = SessionDownload('one', items);
      items.add(task);
      await start();
      await until(() => task.starts == 1);
      await Directory('${root.path}/download_session.json.tmp').create();
      final stopped = await cliGuard(session.stop);
      expect(stopped.code, 'persistence_failed');
      expect(task.isPaused, isTrue);
      expect(session.enabled, isFalse);
      await Directory('${root.path}/download_session.json.tmp').delete();
    },
  );

  test('invalid resume settings do not discard existing retry state', () async {
    final task = SessionDownload('one', items);
    items.add(task);
    await start();
    await until(() => task.starts == 1);
    task.fail('404');
    await settledStep();
    await session.tick();
    final original = session.status;
    final result = await cliGuard(
      () => session.start(
        CliRequest.parse(['downloads', 'resume', '--max-attempts', '0']),
        resume: true,
      ),
    );
    expect(result.code, 'invalid_arguments');
    expect(session.status, original);
  });

  test('cancelling the exposed active request pauses its session', () async {
    final task = SessionDownload('one', items);
    items.add(task);
    await start();
    await until(() => task.starts == 1);
    await queue.cancel(session.status['activeRequestId'] as String);
    await settledStep();
    await session.tick();
    expect(session.enabled, isFalse);
    expect(session.stopReason, 'cancelled');
  });

  test(
    'immediate resume after stop does not consume the old cancellation again',
    () async {
      final task = SessionDownload('one', items);
      items.add(task);
      await start();
      await until(() => task.starts == 1);
      await session.stop();
      await session.start(
        CliRequest.parse(['downloads', 'resume']),
        resume: true,
      );
      await session.tick();
      await until(() => task.starts == 2);
      expect(session.enabled, isTrue);
      task.succeed();
      await settledStep();
      await session.tick();
      expect(session.state, 'completed');
    },
  );

  test('session steps cannot be submitted by an API client', () {
    expect(
      () => ServiceQueue.validate(['downloads', 'step', 'fixture', 'book']),
      throwsA(isA<CliException>()),
    );
  });

  test(
    'session waits for accepted enqueues before deciding the queue is empty',
    () async {
      final first = SessionDownload('one', items);
      items.add(first);
      await start();
      await until(() => first.starts == 1);
      additionGate = Completer<void>();
      final addition = await queue.submit([
        'downloads',
        'add',
        'fixture',
        'two',
        '--enqueue-only',
      ]);
      first.succeed();
      await settledStep();
      await session.tick();
      expect(session.enabled, isTrue);
      expect(session.state, 'waiting_enqueue');
      additionGate!.complete();
      await until(() => addition.state == 'completed');
      await session.tick();
      final second = items.single as SessionDownload;
      await until(() => second.starts == 1);
      second.succeed();
      await settledStep();
      await session.tick();
      expect(session.state, 'completed');
      expect(session.completed, 2);
    },
  );

  test(
    'scheduled queue planning respects a manually paused download session',
    () async {
      session.state = 'paused';
      const outcome = TaskRunOutcome(success: true);
      final task = TaskDefinition(
        id: 'task',
        typeKey: 'incrementalDownload',
        name: 'Fixture',
        schedule: ScheduleSpec.everyInterval(const Duration(hours: 1)),
        createdAt: clock,
      );
      final commands = HeadlessCommands(
        CliRequest.parse(['downloads', 'status']),
        CliControl(),
        CliJobs(root.path),
        (_) {},
        downloadSession: session,
      );
      expect(await commands.settleTask(task, outcome), same(outcome));
    },
  );
}

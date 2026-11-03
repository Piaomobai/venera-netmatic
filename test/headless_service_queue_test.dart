import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/service_queue.dart';
import 'package:venera_netmatic/headless/credentials.dart';

Future<void> waitDone(ServiceRequest request) async {
  for (var i = 0; i < 200; i++) {
    if (!['queued', 'running'].contains(request.state)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Request did not finish');
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('service-queue-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'login secrets stay in memory and are discarded on cancellation',
    () async {
      final release = Completer<void>();
      final queue = ServiceQueue(
        directory: directory.path,
        execute: (request, _, _) async {
          if (request.command == 'downloads run') await release.future;
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      final login = await queue.submit(
        ['sources', 'login', 'picacg'],
        credentials: SourceCredentials.parse({
          'username': 'private-account',
          'password': 'private-password',
        }),
      );
      final journal = await File(
        '${directory.path}/service_requests.json',
      ).readAsString();
      expect(journal, isNot(contains('private-account')));
      expect(journal, isNot(contains('private-password')));
      expect(login.request.credentials, isNotNull);
      await queue.cancel(login.id);
      expect(login.request.credentials, isNull);
      release.complete();
      await queue.shutdown();
    },
  );

  test(
    'queued login is not replayed after a crash without its credentials',
    () async {
      final release = Completer<void>();
      final queue = ServiceQueue(
        directory: directory.path,
        execute: (_, _, _) async {
          await release.future;
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      final login = await queue.submit(
        ['sources', 'login', 'picacg'],
        credentials: SourceCredentials.parse({
          'username': 'private-account',
          'password': 'private-password',
        }),
      );
      final restored = ServiceQueue(
        directory: directory.path,
        execute: (_, _, _) async {
          fail('A recovered login must not execute');
        },
      );
      await restored.load();
      final record = restored.records[login.id]!;
      expect(record.state, 'interrupted');
      expect(record.result?.code, 'interrupted');
      expect(record.request.credentials, isNull);
      await restored.shutdown();
      await queue.cancel(login.id);
      release.complete();
      await queue.shutdown();
    },
  );

  test('generic command submission cannot read credential files or stdin', () {
    for (final args in [
      ['sources', 'login', 'picacg'],
      ['sources', 'login', 'picacg', '--credentials-file', '/private/secret'],
      ['sources', 'login', 'picacg', '--credentials-stdin'],
    ]) {
      expect(() => ServiceQueue.validate(args), throwsA(isA<CliException>()));
    }
  });

  test(
    'storage failure is not hidden by a simultaneous cancellation',
    () async {
      final queue = ServiceQueue(
        directory: directory.path,
        execute: (_, control, _) async {
          control.cancelled = true;
          throw const CliException(
            'persistence_failed',
            'Could not clear stored session.',
          );
        },
      );
      final request = await queue.submit(['sources', 'logout', 'picacg']);
      await waitDone(request);
      expect(request.result?.code, 'persistence_failed');
      await queue.shutdown();
    },
  );

  test(
    'expired login drops credentials without executing or changing the session',
    () async {
      final release = Completer<void>();
      var logins = 0;
      final queue = ServiceQueue(
        directory: directory.path,
        policy: const ServiceQueuePolicy(
          queryQueueTimeout: Duration(milliseconds: 40),
        ),
        execute: (request, _, _) async {
          if (request.command == 'downloads run') await release.future;
          if (request.command == 'sources login') logins++;
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      final login = await queue.submit(
        ['sources', 'login', 'picacg'],
        credentials: SourceCredentials.parse({
          'username': 'account',
          'password': 'password',
        }),
      );
      await waitDone(login);
      expect(login.result?.code, 'queue_timeout');
      expect(login.request.credentials, isNull);
      expect(logins, 0);
      release.complete();
      await queue.shutdown();
    },
  );

  test(
    'live reads share the worker while transfers remain serialized',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final queue = ServiceQueue(
        directory: directory.path,
        execute: (request, _, _) async {
          if (request.command == 'downloads run') {
            started.complete();
            await release.future;
          }
          return const CliResult(null);
        },
      );
      final transfer = await queue.submit(['downloads', 'run']);
      await started.future;
      final query = await queue.submit(['library', 'list']);
      await waitDone(query);
      expect(transfer.state, 'running');
      expect(query.state, 'completed');
      release.complete();
      await waitDone(transfer);
      await queue.shutdown();
    },
  );

  test('import blocks queries until its exclusive mutation settles', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var queried = false;
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        if (request.command == 'webdav down') {
          started.complete();
          await release.future;
        }
        if (request.command == 'library list') queried = true;
        return const CliResult(null);
      },
    );
    final write = await queue.submit(['webdav', 'down']);
    await started.future;
    final read = await queue.submit(['library', 'list']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(read.state, 'queued');
    expect(queried, isFalse);
    release.complete();
    await waitDone(write);
    await waitDone(read);
    expect(queried, isTrue);
    await queue.shutdown();
  });

  test('queued cancellation never executes its mutation', () async {
    final release = Completer<void>();
    var executed = false;
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        if (request.command == 'webdav down') await release.future;
        if (request.command == 'scheduler delete') executed = true;
        return const CliResult(null);
      },
    );
    final first = await queue.submit(['webdav', 'down']);
    final pending = await queue.submit(['scheduler', 'delete', 'task']);
    await queue.cancel(pending.id);
    expect(pending.state, 'cancelled');
    release.complete();
    await waitDone(first);
    expect(executed, isFalse);
    await queue.shutdown();
  });

  test('restart preserves results and literal arguments', () async {
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async => CliResult(request.arguments),
    );
    final original = await queue.submit(['search', 's', '--', '--literal']);
    await waitDone(original);
    await queue.shutdown();
    final restored = ServiceQueue(
      directory: directory.path,
      execute: (_, _, _) async => const CliResult(null),
    );
    await restored.load();
    expect(restored.records[original.id]!.request.arguments, [
      's',
      '--literal',
    ]);
    expect(restored.records[original.id]!.state, 'completed');
    await restored.shutdown();
  });

  test('the API cannot override data paths or launch nested daemons', () {
    for (final args in [
      ['library', 'list', '--data-dir', '/other'],
      ['scheduler', 'serve'],
      ['service', 'serve', '--socket', '/other'],
      ['--headless', 'help'],
    ]) {
      expect(() => ServiceQueue.validate(args), throwsA(isA<CliException>()));
    }
  });

  test('shutdown preserves queued writes for the next owner', () async {
    final started = Completer<void>();
    final released = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      onCancel: (_) => released.complete(),
      execute: (_, control, _) async {
        started.complete();
        await released.future;
        control.check();
        return const CliResult(null);
      },
    );
    final active = await queue.submit(['downloads', 'run']);
    await started.future;
    final pending = await queue.submit(['scheduler', 'delete', 'task']);
    await queue.shutdown();
    expect(active.state, 'cancelled');
    expect(pending.state, 'queued');
    final executed = <String>[];
    final restored = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        executed.add(request.command);
        return const CliResult(null);
      },
    );
    await restored.load();
    restored.start();
    await waitDone(restored.records[pending.id]!);
    expect(executed, ['scheduler delete']);
    expect(restored.records[active.id]!.state, 'cancelled');
    await restored.shutdown();
  });

  test(
    'oversized source errors cannot exceed the IPC response bound',
    () async {
      final queue = ServiceQueue(
        directory: directory.path,
        execute: (_, _, _) async {
          throw CliException(
            'source_error',
            List.filled(1024 * 1024, 'x').join(),
          );
        },
      );
      final request = await queue.submit(['search', 'source', 'query']);
      await waitDone(request);
      expect(request.state, 'failed');
      expect(request.result!.code, 'result_too_large');
      expect(request.result!.message.length, lessThan(100));
      await queue.shutdown();
    },
  );

  test('queries bypass pending writes while a transfer is running', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        if (request.command == 'downloads run') {
          started.complete();
          await release.future;
        }
        return const CliResult(null);
      },
    );
    final active = await queue.submit(['downloads', 'run']);
    await started.future;
    final write = await queue.submit(['scheduler', 'delete', 'task']);
    final read = await queue.submit(['search', 'source', 'query']);
    await waitDone(read);
    expect(active.state, 'running');
    expect(write.state, 'queued');
    expect(read.state, 'completed');
    release.complete();
    await waitDone(write);
    await queue.shutdown();
  });

  test('foreground writes overtake queued NAS transfers', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final order = <String>[];
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        order.add(request.command);
        if (request.command == 'downloads run') {
          started.complete();
          await release.future;
        }
        return const CliResult(null);
      },
    );
    await queue.submit(['downloads', 'run']);
    await started.future;
    final nas = await queue.submit(['nas', 'upload', 'nas']);
    final foreground = await queue.submit(['scheduler', 'delete', 'task']);
    release.complete();
    await waitDone(nas);
    await waitDone(foreground);
    expect(order, ['downloads run', 'scheduler delete', 'nas upload']);
    await queue.shutdown();
  });

  test('slow NAS queries leave query slots available for search', () async {
    final release = Completer<void>();
    var activeNas = 0;
    var maxNas = 0;
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (request, _, _) async {
        if (request.command == 'nas library') {
          activeNas++;
          if (activeNas > maxNas) maxNas = activeNas;
          await release.future;
          activeNas--;
        }
        return const CliResult(null);
      },
    );
    final nas = <ServiceRequest>[];
    for (var i = 0; i < 4; i++) {
      nas.add(await queue.submit(['nas', 'library', 'nas']));
    }
    final search = await queue.submit(['search', 'source', 'query']);
    await waitDone(search);
    expect(search.state, 'completed');
    expect(maxNas, 1);
    expect(nas.where((r) => r.state == 'queued'), hasLength(3));
    release.complete();
    for (final request in nas) {
      await waitDone(request);
    }
    await queue.shutdown();
  });

  test(
    'exclusive changes eventually drain readers without starvation',
    () async {
      final firstRead = Completer<void>();
      final releaseRead = Completer<void>();
      final writerStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      var reads = 0;
      final queue = ServiceQueue(
        directory: directory.path,
        policy: const ServiceQueuePolicy(
          exclusiveGrace: Duration(milliseconds: 20),
          queryBurstLimit: 1000,
        ),
        execute: (request, _, _) async {
          if (request.command == 'library list' && reads++ == 0) {
            firstRead.complete();
            await releaseRead.future;
          }
          if (request.command == 'webdav down') {
            writerStarted.complete();
            await releaseWrite.future;
          }
          return const CliResult(null);
        },
      );
      await queue.submit(['library', 'list']);
      await firstRead.future;
      final writer = await queue.submit(['webdav', 'down']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final laterRead = await queue.submit(['library', 'list']);
      expect(laterRead.state, 'queued');
      releaseRead.complete();
      await writerStarted.future;
      expect(laterRead.state, 'queued');
      expect(writer.state, 'running');
      releaseWrite.complete();
      await waitDone(laterRead);
      await queue.shutdown();
    },
  );

  test(
    'expired queued writes never execute and their failure is durable',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      var executed = false;
      final queue = ServiceQueue(
        directory: directory.path,
        policy: const ServiceQueuePolicy(
          commandQueueTimeout: Duration(milliseconds: 40),
        ),
        execute: (request, _, _) async {
          if (request.command == 'downloads run') {
            started.complete();
            await release.future;
          } else {
            executed = true;
          }
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      await started.future;
      final pending = await queue.submit(['scheduler', 'delete', 'task']);
      await waitDone(pending);
      expect(pending.state, 'failed');
      expect(pending.result!.code, 'queue_timeout');
      expect(pending.result!.exitCode, 124);
      expect(executed, isFalse);
      release.complete();
      await queue.shutdown();
      final journal =
          jsonDecode(
                await File(
                  '${directory.path}/service_requests.json',
                ).readAsString(),
              )
              as List;
      expect(
        journal.singleWhere((r) => r['id'] == pending.id)['result']['code'],
        'queue_timeout',
      );
    },
  );

  test(
    'queue deadlines survive shutdown and expire before restart execution',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final queue = ServiceQueue(
        directory: directory.path,
        policy: const ServiceQueuePolicy(
          commandQueueTimeout: Duration(milliseconds: 150),
        ),
        onCancel: (_) {
          if (!release.isCompleted) release.complete();
        },
        execute: (_, control, _) async {
          started.complete();
          await release.future;
          control.check();
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      await started.future;
      final pending = await queue.submit(['scheduler', 'delete', 'task']);
      await queue.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      var executed = false;
      final restored = ServiceQueue(
        directory: directory.path,
        execute: (_, _, _) async {
          executed = true;
          return const CliResult(null);
        },
      );
      await restored.load();
      restored.start();
      expect(restored.records[pending.id]!.result!.code, 'queue_timeout');
      expect(executed, isFalse);
      await restored.shutdown();
    },
  );

  test('explicit queue timeout overrides the query default', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      policy: const ServiceQueuePolicy(
        queryQueueTimeout: Duration(milliseconds: 20),
      ),
      execute: (request, _, _) async {
        if (request.command == 'webdav down') {
          started.complete();
          await release.future;
        }
        return const CliResult(null);
      },
    );
    await queue.submit(['webdav', 'down']);
    await started.future;
    final query = await queue.submit([
      'library',
      'list',
      '--queue-timeout',
      '1',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(query.state, 'queued');
    release.complete();
    await waitDone(query);
    expect(query.state, 'completed');
    await queue.shutdown();
  });

  test('execution timeout interrupts a stalled cancellable read', () async {
    final never = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      policy: const ServiceQueuePolicy(
        executionTimeout: Duration(milliseconds: 30),
      ),
      execute: (request, control, _) async {
        if (request.command == 'search') await control.wait(never.future);
        return const CliResult(null);
      },
    );
    final query = await queue.submit(['search', 'source', 'query']);
    await waitDone(query);
    expect(query.result!.code, 'timeout');
    expect(query.result!.exitCode, 124);
    final next = await queue.submit(['library', 'list']);
    await waitDone(next);
    expect(next.state, 'completed');
    never.complete();
    await queue.shutdown();
  });

  test('timed out writes retain their slot until safe completion', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    var firstSettled = false;
    var overlap = false;
    final queue = ServiceQueue(
      directory: directory.path,
      policy: const ServiceQueuePolicy(
        executionTimeout: Duration(milliseconds: 20),
      ),
      execute: (request, _, _) async {
        if (request.command == 'downloads run') {
          started.complete();
          await release.future;
          firstSettled = true;
        } else {
          overlap = !firstSettled;
        }
        return const CliResult(null);
      },
    );
    final first = await queue.submit(['downloads', 'run']);
    await started.future;
    final second = await queue.submit(['scheduler', 'delete', 'task']);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(first.state, 'running');
    expect(first.control.timedOut, isTrue);
    expect(second.state, 'queued');
    release.complete();
    await waitDone(second);
    expect(first.result!.code, 'timeout');
    expect(overlap, isFalse);
    await queue.shutdown();
  });

  test(
    'aged NAS writes regain a turn ahead of newer foreground writes',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final order = <String>[];
      final queue = ServiceQueue(
        directory: directory.path,
        policy: const ServiceQueuePolicy(
          writerAging: Duration(milliseconds: 80),
        ),
        execute: (request, _, _) async {
          order.add(request.command);
          if (request.command == 'downloads run') {
            started.complete();
            await release.future;
          }
          return const CliResult(null);
        },
      );
      await queue.submit(['downloads', 'run']);
      await started.future;
      final nas = await queue.submit(['nas', 'upload', 'nas']);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      final fresh = await queue.submit(['scheduler', 'delete', 'task']);
      release.complete();
      await waitDone(fresh);
      await waitDone(nas);
      expect(order, ['downloads run', 'nas upload', 'scheduler delete']);
      await queue.shutdown();
    },
  );
  test('background saturation reserves admission slots for queries', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      policy: const ServiceQueuePolicy(
        maxPending: 8,
        reservedInteractivePending: 2,
        maxBackgroundPending: 4,
      ),
      execute: (request, _, _) async {
        if (request.command == 'webdav down') {
          started.complete();
          await release.future;
        }
        return const CliResult(null);
      },
    );
    await queue.submit(['webdav', 'down']);
    await started.future;
    for (var i = 0; i < 4; i++) {
      await queue.submit(['nas', 'upload', 'nas']);
    }
    await expectLater(
      queue.submit(['nas', 'upload', 'nas']),
      throwsA(isA<CliException>().having((e) => e.code, 'code', 'queue_full')),
    );
    final query = await queue.submit(['search', 'source', 'q']);
    expect(query.state, 'queued');
    release.complete();
    await waitDone(query);
    expect(query.state, 'completed');
    await queue.shutdown();
  });
  test('stop reason survives a simultaneous transport failure', () async {
    final started = Completer<void>();
    final fail = Completer<void>();
    final queue = ServiceQueue(
      directory: directory.path,
      execute: (_, _, _) async {
        started.complete();
        await fail.future;
        throw StateError('transport closed');
      },
    );
    final request = await queue.submit(['downloads', 'run']);
    await started.future;
    await queue.cancel(request.id);
    fail.complete();
    await waitDone(request);
    expect(request.state, 'cancelled');
    expect(request.result!.code, 'cancelled');
    expect(request.result!.exitCode, 130);
    await queue.shutdown();
  });
}

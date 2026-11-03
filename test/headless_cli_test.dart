import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/process_lock.dart';
import 'package:venera_netmatic/headless/cli.dart';
import 'package:venera_netmatic/headless/jobs.dart';

void main() {
  test('parses global options, Unicode queries and literal arguments', () {
    final request = CliRequest.parse([
      '--headless',
      '--json',
      '--data-dir',
      '/tmp/profile',
      'search',
      'source',
      '--',
      '--中文',
    ]);
    expect(request.command, 'search');
    expect(request.arguments, ['source', '--中文']);
    expect(request.json, isTrue);
    expect(request.options['data-dir'], '/tmp/profile');
  });

  test('supports the existing single-subscription syntax', () {
    final request = CliRequest.parse([
      '--headless',
      'updatesubscribe',
      '--update-comic-by-id-type',
      'id',
      'source',
    ]);
    expect(request.arguments, ['id', 'source']);
  });

  for (final args in <List<String>>[
    [],
    ['unknown'],
    ['search', 's'],
    ['search', 's', 'q', '--page', '0'],
    ['search', 's', 'q', '--queue-timeout', '0'],
    ['search', 's', 'q', '--queue-timeout', '-1'],
    ['search', 's', 'q', '--queue-timeout', '86401'],
    ['search', 's', 'q', '--page', '1', '--page', '2'],
    ['nas', 'upload'],
    ['updatesubscribe', '--update-comic-by-id-type', 'id'],
    ['scheduler', 'create', 'nasSync', '--config', '[]'],
    ['library', 'list', '--password', 'secret'],
  ]) {
    test('invalid syntax is rejected before bootstrap: $args', () {
      expect(
        () => CliRequest.parse(args),
        throwsA(isA<CliException>().having((e) => e.exitCode, 'exit', 2)),
      );
    });
  }

  test('failure produces a nonzero exit and structured error', () async {
    final result = await cliGuard(
      () async => throw const CliException('sync_failed', 'offline'),
    );
    expect(result.exitCode, 1);
    expect(jsonDecode(jsonEncode(result.toJson()))['code'], 'sync_failed');
    expect(result.status, 'error');
  });

  test('unexpected errors and timeouts are terminal errors', () async {
    expect((await cliGuard(() async => throw StateError('bad'))).exitCode, 1);
    expect(
      (await cliGuard(() async => throw TimeoutException('slow'))).exitCode,
      124,
    );
  });

  test(
    'journal survives restart and marks abandoned active jobs interrupted',
    () async {
      final temp = await Directory.systemTemp.createTemp('headless-jobs-');
      try {
        final jobs = CliJobs(temp.path);
        final id = await jobs.create('download', {
          'sourceKey': 's',
          'comicId': '1',
        });
        await jobs.update(id, 'running');
        final restored = CliJobs(temp.path);
        await restored.load();
        expect(restored.find(id)!['state'], 'interrupted');
        expect(restored.pendingDownload('s', '1'), id);
        await restored.update(id, 'completed');
        final finished = CliJobs(temp.path);
        await finished.load();
        expect(finished.find(id)!['state'], 'completed');
        expect(finished.pendingDownload('s', '1'), isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'OS lock excludes a second process and is reusable after release',
    () async {
      final temp = await Directory.systemTemp.createTemp('venera-lock-');
      AppProcessLock? lock;
      try {
        final config = File('.dart_tool/package_config.json').absolute;
        final packages =
            jsonDecode(await config.readAsString())['packages'] as List;
        final flutter = packages.firstWhere((e) => e['name'] == 'flutter');
        final flutterPackage = Directory.fromUri(
          config.uri.resolve(flutter['rootUri']),
        );
        final sdk = flutterPackage.parent.parent.path;
        final dart =
            '$sdk/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}';
        lock = await AppProcessLock.acquire(temp.path);
        await expectLater(
          AppProcessLock.acquire(temp.path),
          throwsA(isA<AppBusyException>()),
        );
        final busy = await Process.run(dart, [
          'test/fixtures/process_lock_probe.dart',
          temp.path,
        ]);
        expect(busy.exitCode, 3, reason: '${busy.stderr}');
        expect(busy.stdout, contains('busy'));
        await lock.close();
        final free = await Process.run(dart, [
          'test/fixtures/process_lock_probe.dart',
          temp.path,
        ]);
        expect(free.exitCode, 0, reason: '${free.stderr}');
        expect(free.stdout, contains('acquired'));
      } finally {
        await lock?.close();
        await temp.delete(recursive: true);
      }
    },
  );
}

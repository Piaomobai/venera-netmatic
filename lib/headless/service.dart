import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/utils/io.dart' show overrideIO;
import 'cli.dart';
import 'commands.dart';
import 'jobs.dart';
import 'service_queue.dart';
import 'credentials.dart';
import 'download_session.dart';

class HeadlessService {
  HeadlessService(this.request, this.control, this.jobs, this.report);
  final CliRequest request;
  final CliControl control;
  final CliJobs jobs;
  final void Function(Map<String, dynamic>) report;
  final engine = SchedulerEngine();
  late final ServiceQueue queue;
  late final DownloadSession downloads;
  bool closing = false;

  Future<CliResult> serve() async {
    if (Platform.isWindows) {
      throw const CliException(
        'unsupported',
        'The service socket currently requires Linux or macOS.',
      );
    }
    final path = request.options['socket'];
    if (path == null ||
        !path.startsWith('/') ||
        utf8.encode(path).length > (Platform.isMacOS ? 100 : 104)) {
      throw const CliException(
        'invalid_arguments',
        'Provide a short absolute --socket path.',
        exitCode: 2,
      );
    }
    final socketFile = File(path);
    await socketFile.parent.create(recursive: true);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.unixDomainSock) {
        throw const CliException(
          'invalid_arguments',
          'Socket path is occupied by another file.',
          exitCode: 2,
        );
      }
      Socket? existing;
      try {
        existing = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
      } on SocketException {
        /* stale socket after an interrupted worker */
      }
      if (existing != null) {
        existing.destroy();
        throw const CliException(
          'app_busy',
          'The service socket is already in use.',
          exitCode: 3,
        );
      }
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await socketFile.delete();
      }
    }
    await engine.init(
      databasePath: '${App.dataPath}/scheduler.db',
      startTimer: false,
      recoverRuns: true,
      markRunOnStart: true,
      strict: true,
    );
    queue = ServiceQueue(
      directory: App.dataPath,
      execute: (request, control, progress) => overrideIO(() async {
        final outcome = await HeadlessCommands(
          request,
          control,
          jobs,
          progress,
          managedScheduler: true,
          downloadSession: downloads,
        ).execute();
        try {
          await App.local.flushDownloadingTasks();
          await appdata.flushPendingData();
          for (final source in ComicSource.all()) {
            await source.flushPendingData();
          }
        } catch (_) {
          throw const CliException(
            'persistence_failed',
            'Could not flush profile storage. Fix storage before retrying.',
          );
        }
        return outcome;
      }),
      onCancel: (r) {
        if (['scheduler run', 'scheduler rundue'].contains(r.request.command)) {
          engine.requestCancel();
        }
      },
    );
    downloads = DownloadSession(
      directory: App.dataPath,
      tasks: () => App.local.downloadingTasks,
      flush: App.local.flushDownloadingTasks,
      jobs: jobs,
      queue: queue,
    );
    await queue.load();
    await downloads.load();
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    await Process.run('chmod', ['660', path]);
    final subscription = server.listen((socket) {
      unawaited(_client(socket));
    });
    var checking = false;
    Future<void> checkDue() async {
      if (closing ||
          checking ||
          queue.hasScheduledBatch ||
          !engine.tasks.any((t) => t.isDue)) {
        return;
      }
      checking = true;
      try {
        // Release the write slot between due tasks so foreground commands can
        // overtake background work instead of waiting for an entire batch.
        await queue.submit([
          'scheduler',
          'rundue',
          '--max-tasks',
          '1',
        ], origin: 'scheduler');
      } catch (_) {
        if (!closing) report({'state': 'scheduler_enqueue_failed'});
      } finally {
        checking = false;
      }
    }

    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(checkDue());
      unawaited(downloads.tick());
    });
    queue.start();
    report({'state': 'ready', 'mode': 'service', 'pid': pid, 'socket': path});
    try {
      while (!control.cancelled && !control.timedOut) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      closing = true;
      timer.cancel();
      await server.close();
      await subscription.cancel();
      try {
        await downloads.close();
      } finally {
        try {
          await queue.shutdown();
        } finally {
          engine.close();
          if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            await socketFile.delete();
          }
        }
      }
    }
    control.check();
    return const CliResult(null, message: 'Worker stopped.');
  }

  Future<void> _client(Socket socket) async {
    try {
      final bytes = <int>[];
      var complete = false;
      await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
        final newline = chunk.indexOf(10);
        bytes.addAll(newline < 0 ? chunk : chunk.sublist(0, newline));
        if (bytes.length > 256 * 1024) {
          throw const CliException(
            'invalid_arguments',
            'Request is too large.',
          );
        }
        if (newline >= 0) {
          complete = true;
          break;
        }
      }
      if (!complete) {
        throw const CliException('invalid_arguments', 'Expected a JSON line.');
      }
      final message = jsonDecode(utf8.decode(bytes));
      if (message is! Map) {
        throw const CliException(
          'invalid_arguments',
          'Expected a JSON object.',
        );
      }
      final result = await _rpc(message);
      socket.write('${jsonEncode(result)}\n');
      await socket.flush();
    } on CliException catch (e) {
      socket.write(
        '${jsonEncode({'ok': false, 'code': e.code, 'message': e.message})}\n',
      );
      try {
        await socket.flush();
      } catch (_) {}
    } catch (_) {
      try {
        socket.write(
          '${jsonEncode({'ok': false, 'code': 'request_failed', 'message': 'Invalid request or worker storage error.'})}\n',
        );
        await socket.flush();
      } catch (_) {}
    } finally {
      socket.destroy();
    }
  }

  Future<Map<String, dynamic>> _rpc(Map message) async {
    if (closing) return {'ok': false, 'code': 'stopping'};
    switch (message['op']) {
      case 'health':
        return {
          'ok': true,
          'data': {'pid': pid},
        };
      case 'status':
        return {
          'ok': true,
          'data': {
            ...queue.status,
            'scheduledTasks': engine.tasks.length,
            'schedulerActiveTaskId': engine.activeTaskId,
            'schedulerProgress': engine.activeProgress,
            'downloadSession': downloads.status,
          },
        };
      case 'list':
        return {
          'ok': true,
          'data': {
            'requests': queue.records.values
                .toList()
                .reversed
                .map((r) => r.summary())
                .toList(),
          },
        };
      case 'get':
        final item = queue.records[message['id']];
        if (item == null) {
          throw const CliException('not_found', 'Request not found.');
        }
        return {'ok': true, 'data': item.publicJson()};
      case 'submit':
        if (message['args'] is! List) {
          throw const CliException('invalid_arguments', 'Expected args array.');
        }
        final item = await queue.submit(message['args'] as List);
        return {'ok': true, 'data': item.summary()};
      case 'source_auth':
        const allowed = {
          'op',
          'sourceKey',
          'action',
          'credentials',
          'replace',
          'timeout',
          'queueTimeout',
        };
        final action = message['action'];
        final key = message['sourceKey'];
        if (message.keys.any((k) => !allowed.contains(k)) ||
            key is! String ||
            !RegExp(r'^[a-zA-Z0-9_]{1,128}$').hasMatch(key) ||
            ![
              'login',
              'logout',
              'status',
              'verify',
              'reauth',
            ].contains(action) ||
            message['replace'] != null && message['replace'] is! bool ||
            action != 'login' &&
                (message.containsKey('credentials') ||
                    message.containsKey('replace'))) {
          throw const CliException(
            'invalid_arguments',
            'Invalid source-auth request.',
            exitCode: 2,
          );
        }
        for (final name in ['timeout', 'queueTimeout']) {
          final value = message[name];
          if (value != null && (value is! int || value < 1 || value > 86400)) {
            throw const CliException(
              'invalid_arguments',
              'Invalid account operation deadline.',
              exitCode: 2,
            );
          }
        }
        final credentials = action == 'login'
            ? SourceCredentials.parse(message['credentials'])
            : null;
        final auth = await queue.submit([
          'sources',
          action,
          key,
          if (message['replace'] == true) '--replace',
          if (message['timeout'] != null) ...[
            '--timeout',
            '${message['timeout']}',
          ],
          if (message['queueTimeout'] != null) ...[
            '--queue-timeout',
            '${message['queueTimeout']}',
          ],
        ], credentials: credentials);
        return {'ok': true, 'data': auth.summary()};
      case 'cancel':
        if (message['id'] is! String) {
          throw const CliException('invalid_arguments', 'Expected request id.');
        }
        return {
          'ok': true,
          'data': (await queue.cancel(message['id'] as String)).publicJson(),
        };
      default:
        throw const CliException(
          'invalid_arguments',
          'Unknown worker operation.',
        );
    }
  }
}

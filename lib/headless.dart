import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/process_lock.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/init.dart';
import 'package:venera_netmatic/utils/io.dart' show overrideIO;
import 'headless/cli.dart';
import 'headless/commands.dart';
import 'headless/jobs.dart';
import 'headless/service.dart';
import 'headless/policy.dart';

/// Kept for integrations which recognize the legacy output prefix.
void cliPrint(Map<String, dynamic> data) =>
    stdout.writeln('[CLI PRINT] ${jsonEncode(data)}');

Future<void> runHeadlessMode(List<String> args) async {
  // Native plugins may write diagnostics directly to file descriptor 1,
  // bypassing Dart's print zone. Keep the CLI protocol on a separate copy of
  // the original stdout and send native diagnostics to stderr on Linux.
  IOSink output = stdout;
  int? protocolFd;
  int Function(int)? closeFd;
  if (Platform.isLinux) {
    final libc = DynamicLibrary.process();
    final dup = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'dup',
    );
    final dup2 = libc
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'dup2',
        );
    closeFd = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    final fd = dup(1);
    if (fd < 0) throw const FileSystemException('Cannot duplicate stdout');
    try {
      final file = File('/proc/self/fd/$fd');
      // Validate the descriptor before changing process-wide stdout. Append
      // also preserves existing output when stdout is redirected to a file.
      final probe = await file.open(mode: FileMode.append);
      await probe.close();
      if (dup2(2, 1) < 0) {
        throw const FileSystemException('Cannot redirect native stdout');
      }
      protocolFd = fd;
      output = file.openWrite(mode: FileMode.append);
    } catch (_) {
      closeFd(fd);
      rethrow;
    }
  }
  final json = args.contains('--json');
  final control = CliControl();
  Timer? timeout;
  final signals = <StreamSubscription<ProcessSignal>>[];
  var ready = false;
  void emit(Map<String, dynamic> data) {
    final encoded = jsonEncode(data);
    output.writeln(json ? encoded : '[CLI PRINT] $encoded');
  }

  final result = await runZoned(
    () => cliGuard(() async {
      final request = CliRequest.parse(args);
      if (request.command == 'help') {
        return CliResult({
          'usage': 'venera --headless [--json] <command> [arguments] [options]',
          'commands':
              Map.fromEntries(
                CliRequest.specs.entries.where(
                  (entry) => entry.key != 'downloads step',
                ),
              ).map(
                (name, spec) => MapEntry(name, {
                  'minArguments': spec.$1,
                  'maxArguments': spec.$2,
                  'options': spec.$3.toList(),
                }),
              ),
          'globalOptions': [
            '--json',
            '--data-dir PATH',
            '--cache-dir PATH',
            '--timeout SECONDS',
          ],
          'notes': [
            'Downloads wait for completion unless --enqueue-only is supplied.',
            'One process owns a data directory. Close the GUI before using this CLI.',
            'SIGINT/SIGTERM stop cooperatively; in-flight file writes settle first.',
          ],
        });
      }
      if (request.options.containsKey('queue-timeout')) {
        throw const CliException(
          'invalid_arguments',
          '--queue-timeout applies to commands submitted to service serve.',
          exitCode: 2,
        );
      }
      WidgetsFlutterBinding.ensureInitialized();
      App.isHeadless = true;
      Log.isMuted = true;
      App.dataPathOverride = request.options['data-dir'] == null
          ? null
          : Directory(request.options['data-dir']!).absolute.path;
      App.cachePathOverride = request.options['cache-dir'] == null
          ? null
          : Directory(request.options['cache-dir']!).absolute.path;
      void cancel() {
        control.cancelled = true;
        SchedulerEngine().requestCancel();
      }

      for (final signal in [
        ProcessSignal.sigint,
        if (!Platform.isWindows) ProcessSignal.sigterm,
      ]) {
        signals.add(signal.watch().listen((_) => cancel()));
      }
      final executionTimeout = request.options.containsKey('timeout')
          ? Duration(
              seconds: request.integer('timeout', 60, min: 1, max: 86400),
            )
          : defaultExecutionTimeout(request.command);
      if (executionTimeout != null) {
        timeout = Timer(executionTimeout, () {
          control.timedOut = true;
          SchedulerEngine().requestCancel();
        });
      }
      try {
        await overrideIO(() => init());
      } on AppBusyException catch (e) {
        throw CliException('app_busy', e.toString(), exitCode: 3);
      }
      ready = true;
      control.check();
      final jobs = CliJobs(App.dataPath);
      await jobs.load();
      if (request.command == 'service serve') {
        return await HeadlessService(
          request,
          control,
          jobs,
          (data) => emit({
            'protocolVersion': 1,
            'status': 'running',
            'message': 'Progress',
            'data': data,
          }),
        ).serve();
      }
      final commands = HeadlessCommands(
        request,
        control,
        jobs,
        (data) => emit({
          'protocolVersion': 1,
          'status': 'running',
          'message': 'Progress',
          'data': data,
        }),
      );
      return await overrideIO(commands.execute);
    }),
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, text) => stderr.writeln(text),
    ),
  );

  // Complete writes before reporting a terminal result. The OS releases the
  // profile lock only when this process exits, including on failure.
  final finalResult = await cliGuard(() async {
    if (ready) {
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
    }
    if (result.code == 'persistence_failed') return result;
    control.check();
    return result;
  });
  timeout?.cancel();
  for (final signal in signals) {
    await signal.cancel();
  }
  emit(finalResult.toJson());
  await output.flush();
  await stderr.flush();
  // Read and release the retained handle at the end of its lifetime. Without
  // this production use, AOT can remove the write-only field and the file's
  // finalizer releases the OS lock while the worker is still running.
  await App.processLock?.close();
  App.processLock = null;
  if (protocolFd != null) {
    await output.close();
    closeFd!(protocolFd);
  }
  exit(finalResult.exitCode);
}

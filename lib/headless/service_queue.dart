import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'cli.dart';
import 'policy.dart';
import 'credentials.dart';

export 'policy.dart' show ServiceQueuePolicy;

typedef ServiceExecutor =
    Future<CliResult> Function(
      CliRequest,
      CliControl,
      void Function(Map<String, dynamic>) report,
    );

class ServiceRequest {
  ServiceRequest(this.id, this.request, {this.origin = 'api'});
  final String id;
  final CliRequest request;
  final String origin;
  final control = CliControl();
  String state = 'queued';
  String createdAt = DateTime.now().toUtc().toIso8601String();
  String updatedAt = DateTime.now().toUtc().toIso8601String();
  late DateTime queueDeadline;
  late Duration executionTimeout;
  DateTime? startedAt;
  DateTime? executionDeadline;
  Map<String, dynamic>? progress;
  CliResult? result;
  bool savingResult = false;
  String? _stateDuringSave;
  bool _accepted = false;
  Timer? _queueTimer;
  Future<void>? running;

  bool get isRead => ServiceQueue._reads.contains(request.command);
  bool get isBackground =>
      origin == 'scheduler' ||
      ServiceQueue._background.contains(request.command);
  String get priority => isBackground
      ? 'background'
      : isRead
      ? 'interactive'
      : 'normal';
  Map<String, dynamic> summary() => {
    'id': id,
    'command': request.command,
    if (request.command.startsWith('sources ') && request.arguments.isNotEmpty)
      'sourceKey': request.arguments.first,
    'origin': origin,
    'priority': priority,
    'state': savingResult ? _stateDuringSave : state,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'queueDeadlineAt': queueDeadline.toIso8601String(),
    'timeoutMs': executionTimeout.inMilliseconds,
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (executionDeadline != null)
      'executionDeadlineAt': executionDeadline!.toIso8601String(),
    if (state == 'running')
      'stopRequested': control.cancelled || control.timedOut,
  };
  Map<String, dynamic> publicJson() => {
    ...summary(),
    if (progress != null) 'progress': progress,
    if (result != null && !savingResult) 'result': result!.toJson(),
    if (result != null && !savingResult) 'exitCode': result!.exitCode,
  };
  Map<String, dynamic> privateJson() => {
    ...summary(),
    'state': state,
    if (result != null) 'result': result!.toJson(),
    if (result != null) 'exitCode': result!.exitCode,
    'args': request.toArguments(),
  };
}

/// Queries bypass queued writes and share ordinary transfers. Import/reload
/// still requires an exclusive barrier. Aging and a bounded query burst let
/// exclusive changes eventually acquire that barrier without queue-head stalls.
class ServiceQueue {
  ServiceQueue({
    required this.directory,
    required this.execute,
    this.onCancel,
    this.policy = const ServiceQueuePolicy(),
  });
  final String directory;
  final ServiceExecutor execute;
  final void Function(ServiceRequest)? onCancel;
  final ServiceQueuePolicy policy;
  final Map<String, ServiceRequest> records = {};
  final List<ServiceRequest> _pending = [];
  final Set<ServiceRequest> _readers = {};
  final Set<Future<void>> _finishing = {};
  ServiceRequest? _writer;
  bool _stopping = false;
  bool _pausedForLoad = false;
  int _queryBurst = 0;
  Timer? _wake;
  Future<void> _writes = Future<void>.value();

  static const _reads = {
    'help',
    'sources list',
    'sources status',
    'search',
    'ranking options',
    'ranking get',
    'categories list',
    'categories options',
    'categories get',
    'tags resolve',
    'comic get',
    'comic chapters',
    'library list',
    'favorites list',
    'history list',
    'jobs list',
    'jobs get',
    'downloads list',
    'nas list',
    'nas test',
    'nas library',
    'scheduler list',
    'scheduler types',
    'scheduler history',
  };
  static const _background = {
    'nas upload',
    'nas download',
    'nas test',
    'nas library',
    'webdav up',
  };
  static const _transferWrites = {
    'downloads add',
    'downloads run',
    'nas upload',
    'nas download',
    'scheduler run',
    'scheduler rundue',
  };

  static CliRequest validate(List<dynamic> args, {bool allowLogin = false}) {
    if (args.isEmpty ||
        args.length > 64 ||
        args.any((e) => e is! String) ||
        args.fold<int>(0, (n, e) => n + (e as String).length) > 65536) {
      throw const CliException(
        'invalid_arguments',
        'Expected a bounded array of command strings.',
        exitCode: 2,
      );
    }
    final request = CliRequest.parse(args.cast<String>());
    if (request.command == 'service serve' ||
        request.command == 'scheduler serve' ||
        request.options.keys.any(
          (k) => [
            'data-dir',
            'cache-dir',
            'socket',
            'json',
            'ignore-disheadless-log',
            'credentials-file',
            'credentials-stdin',
          ].contains(k),
        ) ||
        args.contains('--headless') ||
        args.contains('--help')) {
      throw const CliException(
        'invalid_arguments',
        'Service requests cannot change runtime options or start another service.',
        exitCode: 2,
      );
    }
    if (request.command == 'sources login' && !allowLogin) {
      throw const CliException(
        'credentials_required',
        'Use the dedicated source-auth endpoint for login.',
        exitCode: 2,
      );
    }
    return request;
  }

  Duration _queueLimit(ServiceRequest r) {
    if (r.request.options.containsKey('queue-timeout')) {
      return Duration(
        seconds: r.request.integer('queue-timeout', 30, min: 1, max: 86400),
      );
    }
    return r.isBackground
        ? policy.backgroundQueueTimeout
        : r.isRead || r.request.command == 'sources login'
        ? policy.queryQueueTimeout
        : policy.commandQueueTimeout;
  }

  Duration _executionLimit(ServiceRequest r) =>
      r.request.options.containsKey('timeout')
      ? Duration(seconds: r.request.integer('timeout', 60, min: 1, max: 86400))
      : policy.executionTimeout ??
            defaultExecutionTimeout(r.request.command) ??
            const Duration(minutes: 1);

  bool get stopping => _stopping;
  bool get hasScheduledBatch => records.values.any(
    (r) => r.origin == 'scheduler' && ['queued', 'running'].contains(r.state),
  );
  Map<String, dynamic> get status => {
    'pid': pid,
    'queued': _pending.length,
    'queuedByPriority': {
      for (final priority in ['interactive', 'normal', 'background'])
        priority: _pending.where((r) => r.priority == priority).length,
    },
    'activeRequestId': _writer?.id,
    'activeQueries': _readers.map((r) => r.id).toList(),
    'stopping': _stopping,
    'queuePolicy': {
      'maxConcurrentQueries': 4,
      'maxBackgroundQueries': 1,
      'maxPending': policy.maxPending,
      'reservedInteractivePending': policy.reservedInteractivePending,
      'maxBackgroundPending': policy.maxBackgroundPending,
      'queryQueueTimeoutMs': policy.queryQueueTimeout.inMilliseconds,
      'commandQueueTimeoutMs': policy.commandQueueTimeout.inMilliseconds,
      'backgroundQueueTimeoutMs': policy.backgroundQueueTimeout.inMilliseconds,
      'writerAgingMs': policy.writerAging.inMilliseconds,
    },
  };

  Future<void> load() async {
    _pausedForLoad = true;
    final file = File('$directory/service_requests.json');
    if (!await file.exists()) return;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List) {
      throw const FormatException('Invalid service request journal');
    }
    for (final item in raw) {
      final map = Map<String, dynamic>.from(item as Map);
      final r = ServiceRequest(
        map['id'] as String,
        validate(map['args'] as List, allowLogin: true),
        origin: map['origin'] as String? ?? 'api',
      );
      r.state = map['state'] == 'running'
          ? 'interrupted'
          : map['state'] as String;
      r.createdAt = map['createdAt'] as String;
      r.updatedAt = map['updatedAt'] as String;
      r.queueDeadline =
          DateTime.tryParse(map['queueDeadlineAt'] as String? ?? '') ??
          DateTime.parse(r.createdAt).toUtc().add(_queueLimit(r));
      r.executionTimeout = map['timeoutMs'] is int
          ? Duration(milliseconds: map['timeoutMs'] as int)
          : _executionLimit(r);
      r.startedAt = DateTime.tryParse(map['startedAt'] as String? ?? '');
      r.executionDeadline = DateTime.tryParse(
        map['executionDeadlineAt'] as String? ?? '',
      );
      if (map['result'] is Map) {
        final result = map['result'] as Map;
        r.result = CliResult(
          result['data'],
          status: result['status'] as String,
          code: result['code'] as String?,
          message: result['message'] as String,
          exitCode: map['exitCode'] as int? ?? 1,
        );
      }
      if (r.request.command.startsWith('sources ') &&
          !['sources list', 'sources status'].contains(r.request.command) &&
          ['queued', 'interrupted'].contains(r.state)) {
        r.state = 'interrupted';
        r.result = const CliResult(
          null,
          status: 'error',
          code: 'interrupted',
          message:
              'Account operation interrupted. Check source status and explicitly resubmit; credentials are never journaled.',
          exitCode: 1,
        );
      }
      r._accepted = true;
      records[r.id] = r;
      if (r.state == 'queued') _pending.add(r);
    }
    // Expired work must never execute after a long outage, including journals
    // from older versions which did not persist an explicit queue deadline.
    for (final r in _pending.toList()) {
      if (!r.queueDeadline.isAfter(DateTime.now().toUtc())) await _expire(r);
    }
    await _save();
  }

  void start() {
    _pausedForLoad = false;
    for (final r in _pending) {
      _armQueueTimer(r);
    }
    _pump();
  }

  Future<ServiceRequest> submit(
    List<dynamic> args, {
    String origin = 'api',
    SourceCredentials? credentials,
  }) async {
    if (_stopping) throw const CliException('stopping', 'Worker is stopping.');
    final request = validate(args, allowLogin: credentials != null);
    if (credentials != null && request.command != 'sources login') {
      throw const CliException(
        'invalid_arguments',
        'Credentials are only accepted for source login.',
        exitCode: 2,
      );
    }
    request.credentials = credentials;
    final r = ServiceRequest(const Uuid().v4(), request, origin: origin);
    final nonInteractive = _pending
        .where((r) => r.priority != 'interactive')
        .length;
    final background = _pending.where((r) => r.isBackground).length;
    if (_pending.length >= policy.maxPending ||
        (r.priority != 'interactive' &&
            nonInteractive >=
                policy.maxPending - policy.reservedInteractivePending) ||
        (r.isBackground && background >= policy.maxBackgroundPending)) {
      throw const CliException(
        'queue_full',
        'The command queue is full for this priority.',
      );
    }
    r.queueDeadline = DateTime.parse(r.createdAt).add(_queueLimit(r));
    r.executionTimeout = _executionLimit(r);
    records[r.id] = r;
    _pending.add(r);
    try {
      await _save();
    } catch (_) {
      _pending.remove(r);
      records.remove(r.id);
      rethrow;
    }
    r._accepted = true;
    _armQueueTimer(r);
    _pump();
    return r;
  }

  void _armQueueTimer(ServiceRequest r) {
    r._queueTimer?.cancel();
    if (_stopping || r.state != 'queued') return;
    final remaining = r.queueDeadline.difference(DateTime.now().toUtc());
    r._queueTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      final future = _expire(r);
      _finishing.add(future);
      unawaited(future.whenComplete(() => _finishing.remove(future)));
    });
  }

  Future<void> _expire(ServiceRequest r) async {
    if (!_pending.remove(r)) return;
    r._queueTimer?.cancel();
    await _finish(
      r,
      const CliResult(
        null,
        status: 'error',
        code: 'queue_timeout',
        message: 'Request expired in the queue without executing.',
        exitCode: 124,
      ),
    );
    _pump();
  }

  Future<ServiceRequest> cancel(String id) async {
    final r = records[id];
    if (r == null) throw const CliException('not_found', 'Request not found.');
    if (r.state == 'queued' && _pending.remove(r)) {
      r._queueTimer?.cancel();
      await _finish(
        r,
        const CliResult(
          null,
          status: 'error',
          code: 'cancelled',
          message: 'Cancelled before execution.',
          exitCode: 130,
        ),
      );
      _pump();
    } else if (r.state == 'running') {
      r.control.cancelled = true;
      onCancel?.call(r);
    }
    return r;
  }

  Duration _age(ServiceRequest r) =>
      DateTime.now().toUtc().difference(DateTime.parse(r.createdAt));
  ServiceRequest? _nextWrite() {
    final writes = _pending.where((r) => r._accepted && !r.isRead).toList();
    final now = DateTime.now().toUtc();
    writes.sort((a, b) {
      int rank(ServiceRequest r) =>
          now.difference(DateTime.parse(r.createdAt)) >= policy.writerAging
          ? 0
          : r.isBackground
          ? 2
          : 1;
      final order = rank(a).compareTo(rank(b));
      return order != 0 ? order : a.createdAt.compareTo(b.createdAt);
    });
    return writes.isEmpty ? null : writes.first;
  }

  ServiceRequest? _nextRead() {
    final reads = _pending.where((r) => r._accepted && r.isRead).toList();
    for (final r in reads) {
      if (!r.isBackground) return r;
    }
    if (_readers.where((r) => r.isBackground).isNotEmpty) return null;
    return reads.isEmpty ? null : reads.first;
  }

  void _wakeAfter(Duration delay) {
    if (_stopping) return;
    _wake = Timer(delay.isNegative ? Duration.zero : delay, _pump);
  }

  void _pump() {
    if (_stopping || _pausedForLoad) return;
    _wake?.cancel();
    final write = _nextWrite();
    final exclusive =
        write != null && !_transferWrites.contains(write.request.command);
    final grace = write?.isBackground == true
        ? policy.writerAging
        : policy.exclusiveGrace;
    final barrier =
        _writer == null &&
        exclusive &&
        (_age(write) >= grace || _queryBurst >= policy.queryBurstLimit);
    final readsAllowed = _writer == null
        ? !barrier
        : _transferWrites.contains(_writer!.request.command);
    if (readsAllowed) {
      while (_readers.length < 4) {
        final next = _nextRead();
        if (next == null) break;
        _start(next);
        if (!next.isBackground) _queryBurst++;
      }
    }
    if (_writer != null || write == null) {
      if (write == null) _queryBurst = 0;
      return;
    }
    if (exclusive && _readers.isNotEmpty) {
      if (!barrier) _wakeAfter(grace - _age(write));
      return;
    }
    final interactiveWork =
        _readers.any((r) => !r.isBackground) ||
        _pending.any((r) => r._accepted && r.isRead && !r.isBackground);
    if (write.isBackground &&
        interactiveWork &&
        _age(write) < policy.backgroundDeferral) {
      _wakeAfter(policy.backgroundDeferral - _age(write));
      return;
    }
    _start(write);
    _queryBurst = 0;
  }

  void _start(ServiceRequest r) {
    if (!_pending.remove(r)) return;
    r._queueTimer?.cancel();
    if (!r.queueDeadline.isAfter(DateTime.now().toUtc())) {
      final future = _finish(
        r,
        const CliResult(
          null,
          status: 'error',
          code: 'queue_timeout',
          message: 'Request expired in the queue without executing.',
          exitCode: 124,
        ),
      );
      _finishing.add(future);
      unawaited(
        future.whenComplete(() {
          _finishing.remove(future);
          _pump();
        }),
      );
      return;
    }
    if (r.isRead) {
      _readers.add(r);
    } else {
      _writer = r;
    }
    r.state = 'running';
    r.startedAt = DateTime.now().toUtc();
    r.executionDeadline = r.startedAt!.add(r.executionTimeout);
    r.running = _run(r).whenComplete(() {
      _readers.remove(r);
      if (identical(_writer, r)) _writer = null;
      _pump();
    });
  }

  Future<void> _run(ServiceRequest r) async {
    r.updatedAt = r.startedAt!.toIso8601String();
    final timeout = Timer(r.executionTimeout, () {
      r.control.timedOut = true;
      onCancel?.call(r);
    });
    var result = await cliGuard(() async {
      await _save();
      r.control.check();
      // The executor keeps its slot until safe cleanup/rollback settles. It
      // must not be abandoned by Future.timeout on a mutating operation.
      final outcome = await execute(r.request, r.control, (progress) {
        r.progress = progress;
        r.updatedAt = DateTime.now().toUtc().toIso8601String();
      });
      r.control.check();
      if (utf8.encode(jsonEncode(outcome.toJson())).length > 1024 * 1024) {
        throw const CliException(
          'result_too_large',
          'Use a smaller query page.',
        );
      }
      return outcome;
    });
    timeout.cancel();
    // A transport may fail while cancellation/timeout is taking effect. Keep
    // the terminal reason consistent with the stop that was requested.
    final completed = result;
    result = await cliGuard(() async {
      if (completed.code == 'persistence_failed') return completed;
      r.control.check();
      return completed;
    });
    if (result.exitCode != 0 &&
        utf8.encode(jsonEncode(result.toJson())).length > 1024 * 1024) {
      result = const CliResult(
        null,
        status: 'error',
        code: 'result_too_large',
        message: 'The command error exceeded the service response limit.',
        exitCode: 1,
      );
    }
    await _finish(r, result);
  }

  Future<void> _finish(ServiceRequest r, CliResult result) async {
    r.request.credentials = null;
    r._stateDuringSave = r.state;
    r.savingResult = true;
    r.result = result;
    r.state = result.exitCode == 0
        ? 'completed'
        : ['cancelled', 'timeout'].contains(result.code)
        ? 'cancelled'
        : 'failed';
    r.updatedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await _save();
    } catch (_) {
      r.state = 'failed';
      r.result = const CliResult(
        null,
        status: 'error',
        code: 'persistence_failed',
        message: 'Could not persist the final request state.',
        exitCode: 1,
      );
    } finally {
      r.savingResult = false;
    }
  }

  Future<void> shutdown() async {
    _stopping = true;
    _wake?.cancel();
    for (final r in _pending) {
      r._queueTimer?.cancel();
    }
    for (final r in _pending.toList()) {
      if (r.request.command == 'sources login') {
        _pending.remove(r);
        await _finish(
          r,
          const CliResult(
            null,
            status: 'error',
            code: 'interrupted',
            message: 'Worker stopped before login. Resubmit credentials.',
            exitCode: 1,
          ),
        );
      }
    }
    final active = [..._readers, if (_writer != null) _writer!];
    for (final r in active) {
      r.control.cancelled = true;
      onCancel?.call(r);
    }
    await Future.wait(active.map((r) => r.running!));
    await Future.wait(_finishing.toList());
    await _save();
  }

  Future<void> _save() {
    var terminal = 0;
    final ordered = records.values.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final retained = ordered.reversed
        .where(
          (r) => ['queued', 'running'].contains(r.state) || ++terminal <= 100,
        )
        .toList()
        .reversed
        .toList();
    final retainedIds = retained.map((r) => r.id).toSet();
    records.removeWhere((id, _) => !retainedIds.contains(id));
    final contents = jsonEncode(retained.map((r) => r.privateJson()).toList());
    final write = _writes.then((_) async {
      final temp = File('$directory/service_requests.json.tmp');
      await temp.writeAsString(contents, flush: true);
      if (!Platform.isWindows) await Process.run('chmod', ['600', temp.path]);
      await temp.rename('$directory/service_requests.json');
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}

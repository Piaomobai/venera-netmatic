import 'dart:async';
import 'dart:convert';
import 'package:venera_netmatic/foundation/async_control.dart';
import 'credentials.dart';

class CliException implements Exception {
  const CliException(this.code, this.message, {this.exitCode = 1});
  final String code;
  final String message;
  final int exitCode;
  @override
  String toString() => message;
}

class CliResult {
  const CliResult(
    this.data, {
    this.message = 'Completed.',
    this.status = 'success',
    this.code,
    this.exitCode = 0,
  });
  final Object? data;
  final String message;
  final String status;
  final String? code;
  final int exitCode;
  Map<String, dynamic> toJson() => {
    'protocolVersion': 1,
    'status': status,
    'message': message,
    if (code != null) 'code': code,
    'data': data,
  };
}

/// Validates syntax before touching the profile, network or databases.
class CliRequest {
  CliRequest._(this.command, this.arguments, this.options);
  final String command;
  final List<String> arguments;
  final Map<String, String> options;
  SourceCredentials? credentials;
  bool get json => options.containsKey('json');

  static const _global = {
    'json',
    'ignore-disheadless-log',
    'data-dir',
    'cache-dir',
    'timeout',
    'queue-timeout',
  };
  static const _flags = {
    'json',
    'ignore-disheadless-log',
    'disabled',
    'run-on-start',
    'enqueue-only',
    'credentials-stdin',
    'replace',
  };
  // command -> (minimum positional arguments, maximum, accepted options).
  static const specs = <String, (int, int, Set<String>)>{
    'help': (0, 0, {}),
    'service serve': (0, 0, {'socket'}),
    'sources list': (0, 0, {}),
    'sources status': (1, 1, {}),
    'sources login': (
      1,
      1,
      {'credentials-file', 'credentials-stdin', 'replace'},
    ),
    'sources logout': (1, 1, {}),
    'sources verify': (1, 1, {}),
    'sources reauth': (1, 1, {}),
    'search': (2, 2, {'page', 'cursor', 'options'}),
    'ranking options': (1, 1, {}),
    'ranking get': (2, 2, {'page', 'cursor'}),
    'categories list': (1, 1, {'query', 'offset', 'limit'}),
    'categories options': (2, 2, {'param'}),
    'categories get': (2, 2, {'param', 'options', 'page'}),
    'tags resolve': (3, 3, {}),
    'tags search': (3, 3, {'page', 'cursor', 'options'}),
    'comic get': (2, 2, {}),
    'comic chapters': (2, 2, {}),
    'library list': (0, 0, {'query', 'offset', 'limit'}),
    'favorites list': (0, 0, {'folder', 'query', 'offset', 'limit'}),
    'history list': (0, 0, {'query', 'offset', 'limit'}),
    'jobs list': (0, 0, {}),
    'jobs get': (1, 1, {}),
    'downloads list': (0, 0, {}),
    'downloads start': (
      0,
      0,
      {'max-attempts', 'retry-delay', 'idle-timeout', 'max-runtime'},
    ),
    'downloads resume': (
      0,
      0,
      {'max-attempts', 'retry-delay', 'idle-timeout', 'max-runtime'},
    ),
    'downloads status': (0, 0, {}),
    'downloads stop': (0, 0, {}),
    'downloads step': (2, 2, {}),
    'downloads add': (2, 2, {'chapters', 'nas', 'enqueue-only'}),
    'downloads run': (0, 0, {}),
    'downloads remove': (2, 2, {}),
    'nas list': (0, 0, {}),
    'nas test': (1, 1, {}),
    'nas library': (1, 1, {'query', 'offset', 'limit'}),
    'nas upload': (1, 1, {}),
    'nas download': (3, 3, {}),
    'webdav up': (0, 0, {}),
    'webdav down': (0, 0, {}),
    'updatescript all': (0, 0, {}),
    'updatesubscribe': (0, 2, {'folder'}),
    'scheduler list': (0, 0, {}),
    'scheduler types': (0, 0, {}),
    'scheduler run': (1, 1, {}),
    'scheduler rundue': (0, 0, {'max-tasks'}),
    'scheduler serve': (0, 0, {}),
    'scheduler history': (1, 1, {'limit'}),
    'scheduler create': (
      1,
      1,
      {'name', 'config', 'schedule', 'disabled', 'run-on-start'},
    ),
    'scheduler update': (1, 1, {'name', 'config', 'schedule'}),
    'scheduler enable': (1, 1, {}),
    'scheduler disable': (1, 1, {}),
    'scheduler delete': (1, 1, {}),
  };

  factory CliRequest.parse(List<String> raw) {
    final args = List<String>.from(raw);
    args.remove('--headless');
    if (args.contains('--help')) {
      return CliRequest._('help', [], {
        if (args.contains('--json')) 'json': 'true',
      });
    }
    final positional = <String>[];
    final options = <String, String>{};
    var literal = false;
    for (var i = 0; i < args.length; i++) {
      final value = args[i];
      if (!literal && value == '--') {
        literal = true;
        continue;
      }
      if (!literal && value == '--update-comic-by-id-type') {
        if (i + 2 >= args.length) {
          throw const CliException(
            'invalid_arguments',
            'Expected comic id and source key.',
            exitCode: 2,
          );
        }
        positional.addAll(args.sublist(i + 1, i + 3));
        i += 2;
        continue;
      }
      if (!literal && value.startsWith('--')) {
        final equal = value.indexOf('=');
        final key = value.substring(2, equal < 0 ? null : equal);
        if (options.containsKey(key)) {
          throw CliException(
            'invalid_arguments',
            'Repeated option --$key.',
            exitCode: 2,
          );
        }
        if (_flags.contains(key)) {
          if (equal >= 0) {
            throw CliException(
              'invalid_arguments',
              '--$key does not take a value.',
              exitCode: 2,
            );
          }
          options[key] = 'true';
        } else if (equal >= 0) {
          options[key] = value.substring(equal + 1);
        } else {
          if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
            throw CliException(
              'invalid_arguments',
              'Missing value for --$key.',
              exitCode: 2,
            );
          }
          options[key] = args[++i];
        }
      } else {
        positional.add(value);
      }
    }
    if (positional.isEmpty) {
      throw const CliException(
        'invalid_arguments',
        'No command. Use --headless help.',
        exitCode: 2,
      );
    }
    var command = positional.removeAt(0);
    if (!specs.containsKey(command) && positional.isNotEmpty) {
      command += ' ${positional.removeAt(0)}';
    }
    final spec = specs[command];
    if (spec == null) {
      throw CliException(
        'invalid_arguments',
        'Unknown command: $command',
        exitCode: 2,
      );
    }
    if (positional.length < spec.$1 ||
        positional.length > spec.$2 ||
        (command == 'updatesubscribe' && positional.length == 1)) {
      throw CliException(
        'invalid_arguments',
        'Invalid arguments for $command. Use --headless help.',
        exitCode: 2,
      );
    }
    for (final key in options.keys) {
      if (!_global.contains(key) && !spec.$3.contains(key)) {
        throw CliException(
          'invalid_arguments',
          'Unsupported option --$key for $command.',
          exitCode: 2,
        );
      }
    }
    final result = CliRequest._(command, positional, options);
    for (final key in [
      'page',
      'limit',
      'max-tasks',
      'timeout',
      'queue-timeout',
    ]) {
      if (options.containsKey(key)) {
        result.integer(key, 1, min: 1, max: key == 'limit' ? 1000 : 86400);
      }
    }
    result.integer('offset', 0, min: 0);
    for (final key in ['config', 'schedule']) {
      if (options.containsKey(key)) result.object(key);
    }
    for (final key in ['options', 'chapters']) {
      if (options.containsKey(key)) result.strings(key);
    }
    if (options.containsKey('page') && options.containsKey('cursor')) {
      throw const CliException(
        'invalid_arguments',
        'Use either --page or --cursor.',
        exitCode: 2,
      );
    }
    if (options.containsKey('credentials-file') &&
        options.containsKey('credentials-stdin')) {
      throw const CliException(
        'invalid_arguments',
        'Use one credentials input method.',
        exitCode: 2,
      );
    }
    if (options['credentials-file']?.trim().isEmpty == true) {
      throw const CliException(
        'invalid_arguments',
        'Credentials file path must not be empty.',
        exitCode: 2,
      );
    }
    for (final key in ['data-dir', 'cache-dir']) {
      if (options.containsKey(key) && options[key]!.trim().isEmpty) {
        throw CliException(
          'invalid_arguments',
          '--$key must not be empty.',
          exitCode: 2,
        );
      }
    }
    return result;
  }

  int integer(String key, int fallback, {int min = 0, int max = 1000000}) {
    final value = options[key];
    if (value == null) return fallback;
    final number = int.tryParse(value);
    if (number == null || number < min || number > max) {
      throw CliException(
        'invalid_arguments',
        '--$key must be between $min and $max.',
        exitCode: 2,
      );
    }
    return number;
  }

  Map<String, dynamic> object(String key) {
    try {
      final value = jsonDecode(options[key] ?? '{}');
      if (value is Map<String, dynamic>) return value;
    } catch (_) {}
    throw CliException(
      'invalid_arguments',
      '--$key must be a JSON object.',
      exitCode: 2,
    );
  }

  List<String> toArguments() => [
    for (final option in options.entries) ...[
      '--${option.key}',
      if (!_flags.contains(option.key)) option.value,
    ],
    '--',
    ...command.split(' '),
    ...arguments,
  ];

  List<String>? strings(String key) {
    if (!options.containsKey(key)) return null;
    try {
      final value = jsonDecode(options[key]!);
      if (value is List && value.every((e) => e is String)) {
        return value.cast<String>();
      }
    } catch (_) {}
    throw CliException(
      'invalid_arguments',
      '--$key must be a JSON array of strings.',
      exitCode: 2,
    );
  }
}

/// Cancellation is cooperative: callers finish/roll back their current write.
class CliControl {
  bool cancelled = false;
  bool timedOut = false;
  Future<T> wait<T>(Future<T> operation, {Duration? timeout}) =>
      waitCancellable(
        operation,
        checkCancelled: check,
        timeout: timeout ?? const Duration(seconds: 60),
      );
  void check() {
    if (timedOut) {
      throw const CliException(
        'timeout',
        'Operation timed out.',
        exitCode: 124,
      );
    }
    if (cancelled) {
      throw const CliException(
        'cancelled',
        'Operation cancelled.',
        exitCode: 130,
      );
    }
  }
}

Future<CliResult> cliGuard(Future<CliResult> Function() action) async {
  try {
    return await action();
  } on CliException catch (e) {
    return CliResult(
      null,
      status: 'error',
      code: e.code,
      message: e.message,
      exitCode: e.exitCode,
    );
  } on TimeoutException {
    return const CliResult(
      null,
      status: 'error',
      code: 'timeout',
      message: 'Operation timed out.',
      exitCode: 124,
    );
  } catch (e) {
    return CliResult(
      null,
      status: 'error',
      code: 'operation_failed',
      message: e.toString(),
      exitCode: 1,
    );
  }
}

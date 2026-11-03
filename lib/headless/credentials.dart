import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cli.dart';

/// Never serialized with command arguments or returned in a result.
class SourceCredentials {
  SourceCredentials._(this.username, this.password, this.cookies);
  final String? username;
  final String? password;
  final List<String>? cookies;
  String get method => cookies == null ? 'password' : 'cookies';
  static const maxBytes = 32768;

  factory SourceCredentials.parse(Object? value) {
    if (value is Map && value.keys.every((k) => k is String)) {
      if (utf8.encode(jsonEncode(value)).length > maxBytes) {
        throw const CliException(
          'invalid_credentials',
          'Credentials input is too large.',
          exitCode: 2,
        );
      }
      final keys = value.keys.toSet();
      if (keys.length == 2 && keys.containsAll(['username', 'password'])) {
        final user = value['username'];
        final password = value['password'];
        if (user is String &&
            user.trim().isNotEmpty &&
            user.length <= 1024 &&
            password is String &&
            password.isNotEmpty &&
            password.length <= 8192) {
          return SourceCredentials._(user, password, null);
        }
      }
      if (keys.length == 1 && keys.contains('cookies')) {
        final cookies = value['cookies'];
        if (cookies is List &&
            cookies.isNotEmpty &&
            cookies.length <= 64 &&
            cookies.every(
              (c) => c is String && c.isNotEmpty && c.length <= 8192,
            ) &&
            utf8.encode(jsonEncode(value)).length <= maxBytes) {
          return SourceCredentials._(null, null, List<String>.from(cookies));
        }
      }
    }
    throw const CliException(
      'invalid_credentials',
      'Provide username/password or an ordered cookies array as JSON.',
      exitCode: 2,
    );
  }

  static SourceCredentials decode(List<int> bytes) {
    try {
      if (bytes.length <= maxBytes) {
        return SourceCredentials.parse(jsonDecode(utf8.decode(bytes)));
      }
    } on CliException {
      rethrow;
    } catch (_) {}
    throw const CliException(
      'invalid_credentials',
      'Invalid or oversized credentials JSON.',
      exitCode: 2,
    );
  }

  static Future<SourceCredentials> read(
    CliRequest request,
    CliControl control,
  ) async {
    final path = request.options['credentials-file'];
    if (path != null) {
      try {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const CliException(
            'invalid_credentials',
            'Credentials must be a regular file.',
            exitCode: 2,
          );
        }
        final file = File(path);
        final stat = await file.stat();
        if (!Platform.isWindows && (stat.mode & 0x3f) != 0) {
          throw const CliException(
            'insecure_credentials',
            'Credentials file must have mode 0600 or 0400.',
            exitCode: 2,
          );
        }
        if (stat.size > maxBytes) return decode(List.filled(maxBytes + 1, 0));
        control.check();
        // Bound reads even if the file grows after stat().
        final bytes = <int>[];
        await for (final chunk in file.openRead(0, maxBytes + 1)) {
          bytes.addAll(chunk);
        }
        control.check();
        return decode(bytes);
      } on CliException {
        rethrow;
      } catch (_) {
        throw const CliException(
          'credentials_unreadable',
          'Could not read the credentials file.',
          exitCode: 2,
        );
      }
    }
    if (request.options.containsKey('credentials-stdin')) {
      final bytes = <int>[];
      final done = Completer<SourceCredentials>();
      final subscription = stdin.listen(
        (chunk) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes && !done.isCompleted) {
            done.completeError(
              const CliException(
                'invalid_credentials',
                'Credentials input is too large.',
                exitCode: 2,
              ),
            );
          }
        },
        onDone: () {
          if (done.isCompleted) return;
          try {
            done.complete(decode(bytes));
          } catch (e, s) {
            done.completeError(e, s);
          }
        },
        onError: (Object _) {
          if (!done.isCompleted) {
            done.completeError(
              const CliException(
                'credentials_unreadable',
                'Could not read credentials from stdin.',
                exitCode: 2,
              ),
            );
          }
        },
      );
      try {
        return await control.wait(
          done.future,
          timeout: Duration(
            seconds: request.integer('timeout', 60, min: 1, max: 86400),
          ),
        );
      } finally {
        await subscription.cancel();
      }
    }
    throw const CliException(
      'credentials_required',
      'Use --credentials-file or --credentials-stdin. The service requires its dedicated source-auth endpoint.',
      exitCode: 2,
    );
  }
}

import 'dart:convert';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/network/cache.dart';
import 'package:venera_netmatic/network/cookie_jar.dart';
import 'cli.dart';
import 'credentials.dart';

/// Account mutation stays in the owning worker, with script writes staged until
/// completion. We await mutating JS even after cancellation, then roll it back:
/// releasing its queue slot early could let an old login overwrite a new one.
class SourceAuth {
  SourceAuth(this.source, this.control);
  final ComicSource source;
  final CliControl control;

  static Map<String, dynamic> describe(ComicSource source) {
    final account = source.account;
    final saved = source.isLogged;
    final metadata = source.data['__headlessAuth'];
    final storedState = metadata is Map ? metadata['state'] : null;
    final state = source.accountCleanupFailed
        ? 'cleanup_required'
        : !saved
        ? 'logged_out'
        : storedState == 'expired'
        ? 'expired'
        : storedState == 'authenticated'
        ? 'authenticated'
        : 'unverified';
    return {
      'sourceKey': source.key,
      'loggedIn': saved,
      'state': state,
      'methods': [
        if (account?.login != null) 'password',
        if (account?.validateCookies != null) 'cookies',
        if (account?.loginWebsite != null) 'webview',
      ],
      'cookieFields': account?.cookieFields ?? const <String>[],
      'canVerify': account?.validateSession != null,
      'canReauthenticate':
          account?.login != null && source.data['account'] is List,
      if (saved && metadata is Map && metadata['verifiedAt'] is String)
        'lastVerifiedAt': metadata['verifiedAt'],
      'credentialStorage': 'private_profile_file',
    };
  }

  Future<void> _idle() async {
    control.check();
    if (source.accountMutationInProgress) {
      throw const CliException(
        'source_busy',
        'An account operation is already running.',
      );
    }
    // This includes promises from queries that stopped awaiting on timeout.
    final idle = source.account?.waitForIdle;
    if (idle != null) await control.wait(idle());
    try {
      await source.flushPendingData();
    } catch (_) {
      throw const CliException(
        'persistence_failed',
        'Source storage could not be flushed. Fix profile storage before retrying.',
      );
    }
    control.check();
  }

  Map<String, dynamic> _settingsOnly() => {
    if (source.data.containsKey('settings'))
      'settings': jsonDecode(jsonEncode(source.data['settings'])),
  };

  Future<bool> _clear() async {
    final settings = _settingsOnly();
    var cleanupFailed = false;
    source.accountMutationInProgress = true;
    try {
      try {
        final logout = source.account?.logoutAsync;
        if (logout != null) {
          await logout();
        } else {
          source.account?.logout();
        }
      } catch (_) {
        cleanupFailed = true;
      }
    } finally {
      source.data = settings;
      source.accountCleanupFailed = cleanupFailed;
      var cookiesCleared = true;
      try {
        SingleInstanceCookieJar.instance?.deleteForSource(source.key);
      } catch (_) {
        cookiesCleared = false;
        source.accountCleanupFailed = true;
      }
      source.accountMutationInProgress = false;
      NetworkCacheManager().clear();
      try {
        await source.saveData();
      } catch (_) {
        throw const CliException(
          'persistence_failed',
          'Could not persist the logged-out state. Stop the worker and fix profile storage before retrying.',
        );
      }
      if (!cookiesCleared) {
        throw const CliException(
          'persistence_failed',
          'Local account data was cleared, but cookie storage could not be cleared. Fix storage and restart before retrying.',
        );
      }
    }
    return cleanupFailed;
  }

  Future<CliResult> logout() async {
    if (source.account == null) {
      throw const CliException(
        'unsupported',
        'This source has no account support.',
      );
    }
    await _idle();
    final cleanupFailed = await _clear();
    control.check();
    return CliResult(
      describe(source),
      status: cleanupFailed ? 'error' : 'success',
      code: cleanupFailed ? 'source_cleanup_failed' : null,
      exitCode: cleanupFailed ? 1 : 0,
      message: cleanupFailed
          ? 'Local credentials cleared, but the source logout hook failed. Restart the worker before retrying.'
          : 'Logged out. Source settings were preserved.',
    );
  }

  Future<CliResult> login(
    SourceCredentials credentials, {
    bool replace = false,
  }) async {
    final account = source.account;
    if (account == null) {
      throw const CliException(
        'unsupported',
        'This source has no account support.',
      );
    }
    if (credentials.method == 'password' && account.login == null ||
        credentials.method == 'cookies' && account.validateCookies == null) {
      throw CliException(
        account.loginWebsite != null ? 'interaction_required' : 'unsupported',
        account.loginWebsite != null
            ? 'Complete this source login in the GUI, then retry.'
            : 'This source does not support that login method.',
      );
    }
    if (credentials.cookies != null &&
        credentials.cookies!.length != account.cookieFields?.length) {
      throw const CliException(
        'invalid_credentials',
        'Cookie count must match the source cookieFields order.',
        exitCode: 2,
      );
    }
    await _idle();
    if (source.isLogged && !replace) {
      throw const CliException(
        'already_logged_in',
        'Log out first, or pass --replace to switch accounts.',
      );
    }
    // Durably remove the old identity before the new request. A failed switch
    // remains logged out instead of falling back to the previous account.
    final cleanupFailed = await _clear();
    if (cleanupFailed) {
      throw const CliException(
        'source_cleanup_failed',
        'Local credentials cleared, but source cleanup failed. Restart the worker before retrying.',
      );
    }
    control.check();
    source.accountMutationInProgress = true;
    try {
      if (credentials.cookies == null) {
        final result = await account.login!(
          credentials.username!,
          credentials.password!,
        );
        if (result.error || result.data != true) {
          throw _failure(result.errorMessage);
        }
        // Do not require every custom AccountConfig to duplicate the parser.
        source.data['account'] = [credentials.username!, credentials.password!];
      } else {
        if (!await account.validateCookies!(credentials.cookies!)) {
          throw const CliException(
            'authentication_failed',
            'Cookie login was rejected. Session cleared.',
          );
        }
        source.data['account'] = 'ok';
      }
      control.check();
      final validate = account.validateSession;
      final verified = validate != null;
      if (validate != null && !await validate()) {
        throw const CliException(
          'authentication_failed',
          'The new session was rejected. Session cleared.',
        );
      }
      control.check();
      source.data['__headlessAuth'] = {
        'state': verified ? 'authenticated' : 'unverified',
        if (verified) 'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      };
      source.accountMutationInProgress = false;
      try {
        await source.saveData();
      } catch (_) {
        throw const CliException(
          'persistence_failed',
          'Could not save the new session.',
        );
      }
      control.check();
      NetworkCacheManager().clear();
      return CliResult(
        describe(source),
        message: verified
            ? 'Logged in and verified.'
            : 'Logged in. This source has no remote session validator.',
      );
    } catch (error) {
      // Waited for the script above; no late token write can follow this reset.
      final cleanupFailed = await _clear();
      control.check();
      if (cleanupFailed) {
        throw const CliException(
          'source_cleanup_failed',
          'Local credentials cleared, but source cleanup failed. Restart the worker before retrying.',
        );
      }
      if (error is CliException) rethrow;
      throw _failure(error);
    } finally {
      source.accountMutationInProgress = false;
    }
  }

  Future<CliResult> reauthenticate() async {
    final saved = source.data['account'];
    if (saved is! List || saved.length != 2 || saved.any((v) => v is! String)) {
      throw const CliException(
        'credentials_required',
        'No reusable password credentials. Submit a new login.',
      );
    }
    return login(
      SourceCredentials.parse({'username': saved[0], 'password': saved[1]}),
      replace: true,
    );
  }

  Future<CliResult> verify() async {
    await _idle();
    if (!source.isLogged) {
      throw const CliException(
        'authentication_required',
        'Log in before verifying a session.',
      );
    }
    final validate = source.account?.validateSession;
    if (validate == null) {
      throw const CliException(
        'unsupported',
        'This source has no remote session validator.',
      );
    }
    bool valid;
    try {
      valid = await validate();
    } catch (error) {
      control.check();
      throw _failure(error);
    }
    control.check();
    source.data['__headlessAuth'] = {
      'state': valid ? 'authenticated' : 'expired',
      'verifiedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await source.saveData();
    return CliResult(
      describe(source),
      status: valid ? 'success' : 'error',
      code: valid ? null : 'authentication_required',
      exitCode: valid ? 0 : 1,
      message: valid
          ? 'Session verified.'
          : 'Session expired. Reauthenticate, or log out and use another account.',
    );
  }

  static CliException _failure(Object? error) {
    final text = error.toString();
    if (text.contains('interaction_required')) {
      return const CliException(
        'interaction_required',
        'Complete the required interaction in the GUI, then retry.',
      );
    }
    if (text.contains('auth_rate_limited')) {
      return const CliException(
        'auth_rate_limited',
        'Login rate limited. Wait before retrying.',
      );
    }
    if (text.contains('auth_network_error')) {
      return const CliException(
        'network_error',
        'The account service could not be reached. Retry after checking connectivity.',
      );
    }
    if (text.contains('auth_invalid_response')) {
      return const CliException(
        'auth_invalid_response',
        'The account service returned an invalid response.',
      );
    }
    return const CliException(
      'authentication_failed',
      'Authentication failed. Check source status, then retry or use another account.',
    );
  }
}

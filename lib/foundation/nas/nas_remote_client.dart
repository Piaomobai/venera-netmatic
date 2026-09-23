import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'nas_connection.dart';

typedef NasProgress = void Function(int sent, int total);

/// A direct child returned when browsing a remote NAS directory.
class NasRemoteEntry {
  const NasRemoteEntry({
    required this.name,
    required this.isDirectory,
    this.size,
  });

  final String name;
  final bool isDirectory;
  final int? size;
}

abstract interface class NasRemoteClient {
  Future<void> connect();
  Future<void> close();
  Future<void> ensureDirectory(String path);
  Future<int?> fileSize(String path);
  Future<Uint8List?> readBytes(String path);
  Future<List<NasRemoteEntry>> listDirectory(String path);
  Future<void> uploadFile(
    File file,
    String path, {
    NasProgress? onProgress,
    bool preservePrevious = false,
  });
  Future<void> uploadBytes(
    Uint8List data,
    String path, {
    NasProgress? onProgress,
  });
}

NasRemoteClient createNasRemoteClient(NasConnection connection) {
  return switch (connection.protocol) {
    NasProtocol.webdav => _WebDavNasClient(connection),
    NasProtocol.ftp || NasProtocol.ftps => _FtpNasClient(connection),
    NasProtocol.smb => _SmbNasClient(connection),
  };
}

String _parentOf(String path) {
  final normalized = normalizeRemotePath(path);
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? '' : normalized.substring(0, slash);
}

String _temporaryUploadPath(String path) =>
    '$path.venera-uploading-${DateTime.now().microsecondsSinceEpoch}';

/// Keeps the previous remote file available until the new upload has been
/// promoted. Protocols that cannot rename over an existing target use this
/// backup-and-rollback sequence.
Future<void> replaceRemoteFileKeepingBackup({
  required String temporary,
  required String target,
  bool preservePrevious = false,
  required Future<bool> Function(String path) exists,
  required Future<void> Function(String from, String to) rename,
  required Future<void> Function(String path) delete,
}) async {
  final backup =
      '$target.venera-backup-${DateTime.now().microsecondsSinceEpoch}';
  var hasBackup = false;
  try {
    if (await exists(target)) {
      await rename(target, backup);
      hasBackup = true;
    }
    await rename(temporary, target);
  } catch (error) {
    if (hasBackup) {
      try {
        if (await exists(target)) await delete(target);
        await rename(backup, target);
      } catch (restoreError) {
        throw StateError(
          'Could not restore the old NAS file. It remains at $backup. '
          'Upload error: $error; restore error: $restoreError',
        );
      }
    }
    rethrow;
  }
  if (hasBackup && !preservePrevious) {
    try {
      await delete(backup);
    } catch (_) {
      // A leftover backup is safer than reporting a failed, completed upload.
    }
  }
}

class _WebDavNasClient implements NasRemoteClient {
  _WebDavNasClient(this.connection);

  final NasConnection connection;
  late final webdav.Client _client;

  @override
  Future<void> connect() async {
    _client = webdav.newClient(
      connection.host.replaceFirst(RegExp(r'/+$'), ''),
      user: connection.username,
      password: connection.password,
    );
    await _client.readDir('/');
  }

  String _path(String path) => '/${normalizeRemotePath(path)}';

  @override
  Future<void> close() async {}

  @override
  Future<void> ensureDirectory(String path) async {
    final normalized = normalizeRemotePath(path);
    if (normalized.isNotEmpty) await _client.mkdirAll(_path(normalized));
  }

  @override
  Future<int?> fileSize(String path) async {
    try {
      return (await _client.readProps(_path(path))).size;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    try {
      return Uint8List.fromList(await _client.read(_path(path)));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasRemoteEntry>> listDirectory(String path) async {
    final entries = await _client.readDir(_path(path));
    return entries
        .where((entry) => entry.name != null && entry.name!.isNotEmpty)
        .map(
          (entry) => NasRemoteEntry(
            name: entry.name!,
            isDirectory: entry.isDir ?? false,
            size: entry.size,
          ),
        )
        .toList();
  }

  @override
  Future<void> uploadFile(
    File file,
    String path, {
    NasProgress? onProgress,
    bool preservePrevious = false,
  }) async {
    await ensureDirectory(_parentOf(path));
    final temporary = _temporaryUploadPath(path);
    try {
      await _client.writeFromFile(
        file.path,
        _path(temporary),
        onProgress: onProgress,
      );
      if (preservePrevious) {
        await replaceRemoteFileKeepingBackup(
          temporary: _path(temporary),
          target: _path(path),
          preservePrevious: true,
          exists: (remote) async {
            try {
              await _client.readProps(remote);
              return true;
            } catch (_) {
              return false;
            }
          },
          rename: (from, to) => _client.rename(from, to, false),
          delete: _client.remove,
        );
      } else {
        await _client.rename(_path(temporary), _path(path), true);
      }
    } catch (_) {
      try {
        await _client.remove(_path(temporary));
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> uploadBytes(
    Uint8List data,
    String path, {
    NasProgress? onProgress,
  }) async {
    await ensureDirectory(_parentOf(path));
    final temporary = _temporaryUploadPath(path);
    try {
      await _client.write(_path(temporary), data, onProgress: onProgress);
      await _client.rename(_path(temporary), _path(path), true);
    } catch (_) {
      try {
        await _client.remove(_path(temporary));
      } catch (_) {}
      rethrow;
    }
  }
}

class _FtpNasClient implements NasRemoteClient {
  _FtpNasClient(this.connection);

  final NasConnection connection;
  late final FTPConnect _client;

  @override
  Future<void> connect() async {
    _client = FTPConnect(
      connection.host,
      port: connection.effectivePort,
      user: connection.username,
      pass: connection.password,
      securityType: connection.protocol == NasProtocol.ftps
          ? SecurityType.ftpes
          : SecurityType.ftp,
      timeout: 30,
    );
    if (!await _client.connect()) throw Exception('FTP connection failed');
  }

  @override
  Future<void> close() async {
    await _client.disconnect();
  }

  @override
  Future<void> ensureDirectory(String path) async {
    var current = '';
    for (final part in normalizeRemotePath(path).split('/')) {
      if (part.isEmpty) continue;
      current = '$current/$part';
      if (!await _client.createFolderIfNotExist(current)) {
        throw Exception('Could not create FTP directory: $current');
      }
    }
  }

  @override
  Future<int?> fileSize(String path) async {
    final size = await _client.sizeFile(_ftpPath(path));
    return size < 0 ? null : size;
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    try {
      return await _client.downloadToBytes(_ftpPath(path));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasRemoteEntry>> listDirectory(String path) async {
    final entries = await _client.listDirectoryContent(_ftpPath(path));
    return entries
        .where((entry) => entry.name != '.' && entry.name != '..')
        .map(
          (entry) => NasRemoteEntry(
            name: entry.name,
            isDirectory: entry.type.name == 'dir',
            size: entry.size,
          ),
        )
        .toList();
  }

  @override
  Future<void> uploadFile(
    File file,
    String path, {
    NasProgress? onProgress,
    bool preservePrevious = false,
  }) async {
    await ensureDirectory(_parentOf(path));
    final temporary = _ftpPath(_temporaryUploadPath(path));
    final target = _ftpPath(path);
    try {
      final ok = await _client.uploadFile(
        file,
        sRemoteName: temporary,
        onProgress: onProgress == null
            ? null
            : (_, sent, total) => onProgress(sent, total),
      );
      if (!ok) throw Exception('FTP upload failed: $path');
      await replaceRemoteFileKeepingBackup(
        temporary: temporary,
        target: target,
        preservePrevious: preservePrevious,
        exists: _client.existFile,
        rename: (from, to) async {
          if (!await _client.rename(from, to)) {
            throw StateError('FTP rename failed: $from -> $to');
          }
        },
        delete: _client.deleteFile,
      );
    } catch (_) {
      try {
        await _client.deleteFile(temporary);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> uploadBytes(
    Uint8List data,
    String path, {
    NasProgress? onProgress,
  }) async {
    await ensureDirectory(_parentOf(path));
    final temporary = _ftpPath(_temporaryUploadPath(path));
    final target = _ftpPath(path);
    try {
      final ok = await _client.uploadData(
        data,
        temporary,
        onProgress: onProgress == null
            ? null
            : (_, sent, total) => onProgress(sent, total),
      );
      if (!ok) throw Exception('FTP upload failed: $path');
      await replaceRemoteFileKeepingBackup(
        temporary: temporary,
        target: target,
        exists: _client.existFile,
        rename: (from, to) async {
          if (!await _client.rename(from, to)) {
            throw StateError('FTP rename failed: $from -> $to');
          }
        },
        delete: _client.deleteFile,
      );
    } catch (_) {
      try {
        await _client.deleteFile(temporary);
      } catch (_) {}
      rethrow;
    }
  }

  String _ftpPath(String path) => '/${normalizeRemotePath(path)}';
}

class _SmbNasClient implements NasRemoteClient {
  _SmbNasClient(this.connection);

  final NasConnection connection;
  Smb2Pool? _pool;

  Smb2Pool get pool =>
      _pool ?? (throw StateError('SMB client is not connected'));

  @override
  Future<void> connect() async {
    _pool = await Smb2Pool.connect(
      host: connection.host,
      share: connection.share,
      user: connection.username,
      password: connection.password,
      domain: connection.domain,
      workers: 1,
      timeoutSeconds: 30,
      seal: connection.smbEncryption,
      signing: true,
      version: connection.smbEncryption ? Smb2Version.any3 : Smb2Version.any,
    );
    await pool.echo();
  }

  @override
  Future<void> close() async {
    await _pool?.disconnect();
    _pool = null;
  }

  @override
  Future<void> ensureDirectory(String path) async {
    var current = '';
    for (final part in normalizeRemotePath(path).split('/')) {
      if (part.isEmpty) continue;
      current = current.isEmpty ? part : '$current/$part';
      if (!await pool.exists(current)) await pool.mkdir(current);
    }
  }

  @override
  Future<int?> fileSize(String path) async {
    try {
      return await pool.fileSize(normalizeRemotePath(path));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    try {
      return await pool.readFile(normalizeRemotePath(path));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasRemoteEntry>> listDirectory(String path) async {
    final entries = await pool.listDirectory(normalizeRemotePath(path));
    return entries
        .where((entry) => entry.name != '.' && entry.name != '..')
        .map(
          (entry) => NasRemoteEntry(
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.size,
          ),
        )
        .toList();
  }

  @override
  Future<void> uploadFile(
    File file,
    String path, {
    NasProgress? onProgress,
    bool preservePrevious = false,
  }) async {
    await ensureDirectory(_parentOf(path));
    final target = normalizeRemotePath(path);
    final temporary = normalizeRemotePath(_temporaryUploadPath(path));
    var sent = 0;
    final total = await file.length();
    final stream = file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return Uint8List.fromList(chunk);
    });
    try {
      await pool.streamWrite(temporary, stream);
      await replaceRemoteFileKeepingBackup(
        temporary: temporary,
        target: target,
        preservePrevious: preservePrevious,
        exists: pool.exists,
        rename: pool.rename,
        delete: pool.deleteFile,
      );
    } catch (_) {
      try {
        if (await pool.exists(temporary)) await pool.deleteFile(temporary);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> uploadBytes(
    Uint8List data,
    String path, {
    NasProgress? onProgress,
  }) async {
    await ensureDirectory(_parentOf(path));
    final target = normalizeRemotePath(path);
    final temporary = normalizeRemotePath(_temporaryUploadPath(path));
    try {
      await pool.writeFile(temporary, data);
      await replaceRemoteFileKeepingBackup(
        temporary: temporary,
        target: target,
        exists: pool.exists,
        rename: pool.rename,
        delete: pool.deleteFile,
      );
      onProgress?.call(data.length, data.length);
    } catch (_) {
      try {
        if (await pool.exists(temporary)) await pool.deleteFile(temporary);
      } catch (_) {}
      rethrow;
    }
  }
}

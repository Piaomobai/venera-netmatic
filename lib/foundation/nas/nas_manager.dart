import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/data.dart';

import 'nas_connection.dart';
import 'nas_remote_client.dart';

class NasSyncProgress {
  const NasSyncProgress({
    required this.scannedFiles,
    required this.totalFiles,
    required this.uploadedFiles,
    required this.skippedFiles,
    required this.currentPath,
    required this.sentBytes,
    required this.currentFileTotalBytes,
    required this.completedBytes,
    required this.totalBytes,
    required this.uploadedBytes,
    required this.bytesPerSecond,
  });

  final int scannedFiles;
  final int totalFiles;
  final int uploadedFiles;
  final int skippedFiles;
  final String currentPath;

  /// Bytes sent for the current file.
  final int sentBytes;
  final int currentFileTotalBytes;

  /// Bytes accounted for in the overall operation, including skipped files.
  final int completedBytes;
  final int totalBytes;

  /// Bytes sent over the network, excluding skipped files.
  final int uploadedBytes;
  final int bytesPerSecond;

  int get transferredBytes => uploadedBytes + sentBytes;

  double get fraction {
    if (totalBytes > 0) {
      return (completedBytes + sentBytes) / totalBytes;
    }
    if (totalFiles > 0) return scannedFiles / totalFiles;
    return 0;
  }

  Duration? get estimatedRemaining {
    if (bytesPerSecond <= 0 || totalBytes <= 0) return null;
    final remaining = totalBytes - completedBytes - sentBytes;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / bytesPerSecond).ceil());
  }
}

class NasSyncResult {
  const NasSyncResult({
    required this.uploadedFiles,
    required this.skippedFiles,
    required this.totalBytes,
  });

  final int uploadedFiles;
  final int skippedFiles;
  final int totalBytes;
}

class NasManager with ChangeNotifier {
  NasManager._();

  static final NasManager instance = NasManager._();

  static const _syncMarkersSetting = 'nasSyncedComics';

  bool _isSyncing = false;
  NasSyncProgress? _progress;
  Object? _lastError;

  bool get isSyncing => _isSyncing;
  NasSyncProgress? get progress => _progress;
  Object? get lastError => _lastError;

  String _comicMarkerKey(LocalComic comic) =>
      '${comic.comicType.value}|${comic.id}';

  String _comicFingerprint(LocalComic comic) => jsonEncode({
    'id': comic.id,
    'type': comic.comicType.value,
    'title': comic.title,
    'subtitle': comic.subtitle,
    'directory': comic.directory.replaceAll('\\', '/'),
    'cover': comic.cover,
    'chapters': comic.chapters?.toJson(),
    'downloadedChapters': (comic.downloadedChapters.toSet().toList()..sort()),
  });

  Map<String, dynamic> _readSyncMarkers() {
    final raw = appdata.settings[_syncMarkersSetting];
    if (raw is! Map) return <String, dynamic>{};
    return <String, dynamic>{
      for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
  }

  /// Whether this comic was completely synchronized to this NAS and its
  /// inexpensive local metadata fingerprint is still unchanged.
  bool isComicSynced(String connectionId, LocalComic comic) {
    final connectionMarkers = _readSyncMarkers()[connectionId];
    if (connectionMarkers is! Map) return false;
    final marker = connectionMarkers[_comicMarkerKey(comic)];
    return marker is Map && marker['fingerprint'] == _comicFingerprint(comic);
  }

  /// Returns the NAS connections that have a current sync marker for [comic].
  /// The local library uses this to render a cloud badge without contacting
  /// any NAS while the list is being displayed.
  List<NasConnection> syncedConnections(LocalComic comic) => connections
      .where((connection) => isComicSynced(connection.id, comic))
      .toList(growable: false);

  Future<void> markComicsSynced(
    String connectionId,
    Iterable<LocalComic> comics,
  ) async {
    final items = comics.toList(growable: false);
    if (items.isEmpty) return;
    final markers = _readSyncMarkers();
    final rawConnection = markers[connectionId];
    final connectionMarkers = <String, dynamic>{
      if (rawConnection is Map)
        for (final entry in rawConnection.entries)
          entry.key.toString(): entry.value,
    };
    final timestamp = DateTime.now().toUtc().toIso8601String();
    for (final comic in items) {
      connectionMarkers[_comicMarkerKey(comic)] = {
        'fingerprint': _comicFingerprint(comic),
        'syncedAt': timestamp,
      };
    }
    markers[connectionId] = connectionMarkers;
    appdata.settings[_syncMarkersSetting] = markers;
    await appdata.saveData(false);
    notifyListeners();
  }

  Future<void> markComicSynced(String connectionId, LocalComic comic) =>
      markComicsSynced(connectionId, [comic]);

  List<NasConnection> get connections {
    final raw = appdata.settings['nasConnections'];
    if (raw is! List) return const [];
    final result = <NasConnection>[];
    for (final item in raw) {
      try {
        if (item is Map) {
          result.add(NasConnection.fromJson(Map<String, dynamic>.from(item)));
        }
      } catch (_) {
        // One damaged entry must not hide every valid NAS connection.
      }
    }
    return result;
  }

  NasConnection? find(String? id) {
    if (id == null) return null;
    for (final connection in connections) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  String? get defaultConnectionId =>
      appdata.settings['defaultNasConnectionId'] as String?;

  Future<void> saveConnection(NasConnection connection) async {
    final updated = connections;
    final index = updated.indexWhere((item) => item.id == connection.id);
    if (index < 0) {
      updated.add(connection);
    } else {
      updated[index] = connection;
    }
    appdata.settings['nasConnections'] = updated
        .map((item) => item.toJson())
        .toList();
    if (defaultConnectionId == null) {
      appdata.settings['defaultNasConnectionId'] = connection.id;
    }
    await appdata.saveData(false);
    notifyListeners();
  }

  Future<void> deleteConnection(String id) async {
    final updated = connections.where((item) => item.id != id).toList();
    appdata.settings['nasConnections'] = updated
        .map((item) => item.toJson())
        .toList();
    if (defaultConnectionId == id) {
      appdata.settings['defaultNasConnectionId'] = updated.isEmpty
          ? null
          : updated.first.id;
    }
    await appdata.saveData(false);
    notifyListeners();
  }

  Future<void> setDefaultConnection(String? id) async {
    appdata.settings['defaultNasConnectionId'] = id;
    await appdata.saveData(false);
    notifyListeners();
  }

  Future<void> testConnection(NasConnection connection) async {
    final error = connection.validationError();
    if (error != null) throw FormatException(error);
    final client = createNasRemoteClient(connection);
    try {
      await client.connect();
      await client.ensureDirectory(connection.remotePath);
    } finally {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  Future<NasSyncResult> syncAll(
    String connectionId, {
    bool skipMarkedComics = false,
  }) async {
    if (_isSyncing) throw StateError('A NAS sync is already running');
    final connection = find(connectionId);
    if (connection == null) throw StateError('NAS connection not found');
    _isSyncing = true;
    _lastError = null;
    _progress = const NasSyncProgress(
      scannedFiles: 0,
      totalFiles: 0,
      uploadedFiles: 0,
      skippedFiles: 0,
      currentPath: '',
      sentBytes: 0,
      currentFileTotalBytes: 0,
      completedBytes: 0,
      totalBytes: 0,
      uploadedBytes: 0,
      bytesPerSecond: 0,
    );
    notifyListeners();

    final client = createNasRemoteClient(connection);
    try {
      await client.connect();
      final files = await _libraryFiles();
      final comics = LocalManager().getComics(LocalSortType.timeDesc);
      final markedComicKeys = skipMarkedComics
          ? comics
                .where((comic) => isComicSynced(connectionId, comic))
                .map(_comicMarkerKey)
                .toSet()
          : <String>{};
      final comicsWithFiles = <String, LocalComic>{};
      final stats = <File, FileStat>{};
      var overallBytes = 0;
      for (final file in files) {
        final stat = await file.stat();
        stats[file] = stat;
        overallBytes += stat.size;
      }
      final manifest = await _readRemoteManifest(client, connection);
      var uploaded = 0;
      var skipped = 0;
      var uploadedBytes = 0;
      var completedBytes = 0;
      var scanned = 0;
      final startedAt = DateTime.now();
      _setProgress(
        scanned: 0,
        totalFiles: files.length,
        uploaded: 0,
        skipped: 0,
        path: '',
        sent: 0,
        currentTotal: 0,
        completedBytes: 0,
        totalBytes: overallBytes,
        uploadedBytes: 0,
        startedAt: startedAt,
      );
      for (final file in files) {
        scanned++;
        final relative = _relativeLocalPath(file.path);
        final stat = stats[file]!;
        final owner = _findOwningComic(file, comics);
        if (owner != null) {
          comicsWithFiles[_comicMarkerKey(owner)] = owner;
        }
        if (owner != null && markedComicKeys.contains(_comicMarkerKey(owner))) {
          skipped++;
          completedBytes += stat.size;
          _setProgress(
            scanned: scanned,
            totalFiles: files.length,
            uploaded: uploaded,
            skipped: skipped,
            path: relative,
            sent: 0,
            currentTotal: stat.size,
            completedBytes: completedBytes,
            totalBytes: overallBytes,
            uploadedBytes: uploadedBytes,
            startedAt: startedAt,
          );
          continue;
        }
        final remote = joinRemotePath([
          connection.remotePath,
          'library',
          relative,
        ]);
        final digest = await computeNasFileSha256(file);
        final remoteSize = await client.fileSize(remote);
        if (manifest[relative]?.matches(digest, stat.size) == true &&
            remoteSize == stat.size) {
          skipped++;
          completedBytes += stat.size;
          _setProgress(
            scanned: scanned,
            totalFiles: files.length,
            uploaded: uploaded,
            skipped: skipped,
            path: relative,
            sent: 0,
            currentTotal: stat.size,
            completedBytes: completedBytes,
            totalBytes: overallBytes,
            uploadedBytes: uploadedBytes,
            startedAt: startedAt,
          );
          continue;
        }
        _setProgress(
          scanned: scanned,
          totalFiles: files.length,
          uploaded: uploaded,
          skipped: skipped,
          path: relative,
          sent: 0,
          currentTotal: stat.size,
          completedBytes: completedBytes,
          totalBytes: overallBytes,
          uploadedBytes: uploadedBytes,
          startedAt: startedAt,
        );
        await client.uploadFile(
          file,
          remote,
          onProgress: (sent, total) {
            _setProgress(
              scanned: scanned,
              totalFiles: files.length,
              uploaded: uploaded,
              skipped: skipped,
              path: relative,
              sent: sent,
              currentTotal: total,
              completedBytes: completedBytes,
              totalBytes: overallBytes,
              uploadedBytes: uploadedBytes,
              startedAt: startedAt,
            );
          },
        );
        uploaded++;
        uploadedBytes += stat.size;
        completedBytes += stat.size;
        manifest[relative] = _NasManifestEntry(sha256: digest, size: stat.size);
        await _writeRemoteManifest(client, connection, manifest);
        _setProgress(
          scanned: scanned,
          totalFiles: files.length,
          uploaded: uploaded,
          skipped: skipped,
          path: relative,
          sent: 0,
          currentTotal: stat.size,
          completedBytes: completedBytes,
          totalBytes: overallBytes,
          uploadedBytes: uploadedBytes,
          startedAt: startedAt,
        );
      }

      _setProgress(
        scanned: files.length,
        totalFiles: files.length,
        uploaded: uploaded,
        skipped: skipped,
        path: '_venera',
        sent: 0,
        currentTotal: 0,
        completedBytes: completedBytes,
        totalBytes: overallBytes,
        uploadedBytes: uploadedBytes,
        startedAt: startedAt,
      );
      await _uploadMetadata(client, connection);
      await markComicsSynced(connection.id, comicsWithFiles.values);
      return NasSyncResult(
        uploadedFiles: uploaded,
        skippedFiles: skipped,
        totalBytes: uploadedBytes,
      );
    } catch (e) {
      _lastError = e;
      rethrow;
    } finally {
      try {
        await client.close();
      } catch (_) {}
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> uploadComicDirectory(
    String connectionId,
    LocalComic comic, {
    NasProgress? onProgress,
  }) async {
    if (_isSyncing) throw StateError('A NAS sync is already running');
    final connection = find(connectionId);
    if (connection == null) throw StateError('NAS connection not found');
    final base = Directory(comic.baseDir);
    if (!await base.exists()) {
      throw StateError('Downloaded comic directory is missing');
    }
    final client = createNasRemoteClient(connection);
    _isSyncing = true;
    _lastError = null;
    _progress = const NasSyncProgress(
      scannedFiles: 0,
      totalFiles: 0,
      uploadedFiles: 0,
      skippedFiles: 0,
      currentPath: '',
      sentBytes: 0,
      currentFileTotalBytes: 0,
      completedBytes: 0,
      totalBytes: 0,
      uploadedBytes: 0,
      bytesPerSecond: 0,
    );
    notifyListeners();
    try {
      await client.connect();
      final manifest = await _readRemoteManifest(client, connection);
      final files = <File>[];
      await for (final entity in base.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity);
      }
      final stats = <File, FileStat>{};
      var overallBytes = 0;
      for (final file in files) {
        final stat = await file.stat();
        stats[file] = stat;
        overallBytes += stat.size;
      }
      var completedBytes = 0;
      var uploadedBytes = 0;
      var uploaded = 0;
      var skipped = 0;
      final startedAt = DateTime.now();
      for (var index = 0; index < files.length; index++) {
        final entity = files[index];
        final stat = stats[entity]!;
        final relative = entity.path
            .substring(base.path.length)
            .replaceFirst(RegExp(r'^[\\/]'), '')
            .replaceAll('\\', '/');
        final remote = joinRemotePath([
          connection.remotePath,
          'library',
          comic.directory,
          relative,
        ]);
        final manifestKey = joinRemotePath([comic.directory, relative]);
        final digest = await computeNasFileSha256(entity);
        final remoteSize = await client.fileSize(remote);
        if (manifest[manifestKey]?.matches(digest, stat.size) == true &&
            remoteSize == stat.size) {
          skipped++;
          completedBytes += stat.size;
          _setProgress(
            scanned: index + 1,
            totalFiles: files.length,
            uploaded: uploaded,
            skipped: skipped,
            path: relative,
            sent: 0,
            currentTotal: stat.size,
            completedBytes: completedBytes,
            totalBytes: overallBytes,
            uploadedBytes: uploadedBytes,
            startedAt: startedAt,
          );
          continue;
        }
        _setProgress(
          scanned: index + 1,
          totalFiles: files.length,
          uploaded: uploaded,
          skipped: skipped,
          path: relative,
          sent: 0,
          currentTotal: stat.size,
          completedBytes: completedBytes,
          totalBytes: overallBytes,
          uploadedBytes: uploadedBytes,
          startedAt: startedAt,
        );
        await client.uploadFile(
          entity,
          remote,
          onProgress: (sent, total) {
            onProgress?.call(sent, total);
            _setProgress(
              scanned: index + 1,
              totalFiles: files.length,
              uploaded: uploaded,
              skipped: skipped,
              path: relative,
              sent: sent,
              currentTotal: total,
              completedBytes: completedBytes,
              totalBytes: overallBytes,
              uploadedBytes: uploadedBytes,
              startedAt: startedAt,
            );
          },
        );
        uploaded++;
        completedBytes += stat.size;
        uploadedBytes += stat.size;
        manifest[manifestKey] = _NasManifestEntry(
          sha256: digest,
          size: stat.size,
        );
        await _writeRemoteManifest(client, connection, manifest);
        _setProgress(
          scanned: index + 1,
          totalFiles: files.length,
          uploaded: uploaded,
          skipped: skipped,
          path: relative,
          sent: 0,
          currentTotal: stat.size,
          completedBytes: completedBytes,
          totalBytes: overallBytes,
          uploadedBytes: uploadedBytes,
          startedAt: startedAt,
        );
      }
      _setProgress(
        scanned: files.length,
        totalFiles: files.length,
        uploaded: uploaded,
        skipped: skipped,
        path: '_venera',
        sent: 0,
        currentTotal: 0,
        completedBytes: completedBytes,
        totalBytes: overallBytes,
        uploadedBytes: uploadedBytes,
        startedAt: startedAt,
      );
      await _uploadMetadata(client, connection, extraComic: comic);
      await markComicSynced(connection.id, comic);
    } catch (e) {
      _lastError = e;
      rethrow;
    } finally {
      try {
        await client.close();
      } catch (_) {}
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<List<File>> _libraryFiles() async {
    final root = Directory(LocalManager().path);
    if (!await root.exists()) return const [];
    final result = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) result.add(entity);
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  String _relativeLocalPath(String absolutePath) {
    return absolutePath
        .substring(LocalManager().path.length)
        .replaceFirst(RegExp(r'^[\\/]'), '')
        .replaceAll('\\', '/');
  }

  LocalComic? _findOwningComic(File file, List<LocalComic> comics) {
    final path = file.absolute.path.replaceAll('\\', '/').toLowerCase();
    LocalComic? owner;
    var longest = 0;
    for (final comic in comics) {
      final base = comic.baseDir.replaceAll('\\', '/').toLowerCase();
      final prefix = base.endsWith('/') ? base : '$base/';
      if (path.startsWith(prefix) && prefix.length > longest) {
        owner = comic;
        longest = prefix.length;
      }
    }
    return owner;
  }

  Future<void> _uploadMetadata(
    NasRemoteClient client,
    NasConnection connection, {
    LocalComic? extraComic,
  }) async {
    final comics = LocalManager().getComics(LocalSortType.timeDesc);
    if (extraComic != null &&
        !comics.any(
          (item) =>
              item.id == extraComic.id &&
              item.comicType == extraComic.comicType,
        )) {
      comics.add(extraComic);
    }
    final index = {
      'format': 1,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'comics': comics
          .map(
            (comic) => {
              ...comic.toJson(),
              'directory': comic.directory.replaceAll('\\', '/'),
              'downloadedChapters': comic.downloadedChapters,
              'createdAt': comic.createdAt.toUtc().toIso8601String(),
            },
          )
          .toList(),
    };
    final metadataRoot = joinRemotePath([connection.remotePath, '_venera']);
    await client.uploadBytes(
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(index)),
      ),
      joinRemotePath([metadataRoot, 'library-index.json']),
    );

    await appdata.saveData(false);
    final backup = await exportAppData(true);
    try {
      await client.uploadFile(
        backup,
        joinRemotePath([metadataRoot, 'app-data.venera']),
      );
    } finally {
      if (await backup.exists()) await backup.delete();
    }
  }

  void _setProgress({
    required int scanned,
    required int totalFiles,
    required int uploaded,
    required int skipped,
    required String path,
    required int sent,
    required int currentTotal,
    required int completedBytes,
    required int totalBytes,
    required int uploadedBytes,
    required DateTime startedAt,
  }) {
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final speed = elapsedMs <= 0
        ? 0
        : ((uploadedBytes + sent) * 1000 / elapsedMs).round();
    _progress = NasSyncProgress(
      scannedFiles: scanned,
      totalFiles: totalFiles,
      uploadedFiles: uploaded,
      skippedFiles: skipped,
      currentPath: path,
      sentBytes: sent,
      currentFileTotalBytes: currentTotal,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
      uploadedBytes: uploadedBytes,
      bytesPerSecond: speed,
    );
    notifyListeners();
  }

  String _manifestPath(NasConnection connection) =>
      joinRemotePath([connection.remotePath, '_venera', 'sync-manifest.json']);

  Future<Map<String, _NasManifestEntry>> _readRemoteManifest(
    NasRemoteClient client,
    NasConnection connection,
  ) async {
    try {
      final bytes = await client.readBytes(_manifestPath(connection));
      if (bytes == null) return {};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['format'] != 1) return {};
      final rawFiles = decoded['files'];
      if (rawFiles is! Map) return {};
      final result = <String, _NasManifestEntry>{};
      for (final entry in rawFiles.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final value = Map<String, dynamic>.from(entry.value as Map);
        final hash = value['sha256'];
        final size = value['size'];
        if (hash is String && size is num) {
          result[entry.key as String] = _NasManifestEntry(
            sha256: hash,
            size: size.toInt(),
          );
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeRemoteManifest(
    NasRemoteClient client,
    NasConnection connection,
    Map<String, _NasManifestEntry> manifest,
  ) async {
    final data = <String, dynamic>{
      'format': 1,
      'hash': 'sha256',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'files': manifest.map((path, entry) => MapEntry(path, entry.toJson())),
    };
    await client.uploadBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      _manifestPath(connection),
    );
  }
}

@visibleForTesting
Future<String> computeNasFileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class _NasManifestEntry {
  const _NasManifestEntry({required this.sha256, required this.size});

  final String sha256;
  final int size;

  bool matches(String otherHash, int otherSize) =>
      size == otherSize && sha256 == otherHash;

  Map<String, dynamic> toJson() => {'sha256': sha256, 'size': size};
}

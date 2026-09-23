import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/history.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/utils/io.dart';

import 'nas_connection.dart';
import 'nas_manager.dart';
import 'nas_remote_client.dart';

typedef NasLibraryDownloadProgress =
    void Function(int completedFiles, int totalFiles, String currentPath);

/// Installs validated files while keeping the previous local files available
/// for rollback until the library database has been updated.
class NasFileInstall {
  NasFileInstall._(this._entries);

  final List<({File target, File? backup})> _entries;

  static Future<NasFileInstall> begin(
    Directory staging,
    Directory destination,
    List<String> relativePaths,
  ) async {
    final entries = <({File target, File? backup})>[];
    final install = NasFileInstall._(entries);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    try {
      await destination.create(recursive: true);
      for (final relative in relativePaths) {
        final parts = relative.replaceAll('\\', '/').split('/');
        if (FilePath.isAbsolute(relative) ||
            parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
          throw FormatException('Invalid local install path: $relative');
        }
        final staged = File(FilePath.join(staging.path, relative));
        final target = File(FilePath.join(destination.path, relative));
        await target.parent.create(recursive: true);
        File? backup;
        if (await target.exists()) {
          backup = File('${target.path}.venera-backup-$stamp');
          await target.rename(backup.path);
        }
        entries.add((target: target, backup: backup));
        try {
          await staged.rename(target.path);
        } on FileSystemException {
          // Storage Access Framework destinations can live on a different
          // volume, where rename is unsupported.
          await staged.copyMem(target.path);
          await staged.delete();
        }
      }
      return install;
    } catch (_) {
      await install.rollback();
      rethrow;
    }
  }

  Future<void> rollback() async {
    for (final entry in _entries.reversed) {
      if (await entry.target.exists()) await entry.target.delete();
      final backup = entry.backup;
      if (backup != null && await backup.exists()) {
        await backup.rename(entry.target.path);
      }
    }
    _entries.clear();
  }

  Future<void> finish() async {
    for (final entry in _entries) {
      final backup = entry.backup;
      if (backup != null) {
        try {
          if (await backup.exists()) await backup.delete();
        } catch (_) {
          // A leftover backup does not invalidate the installed comic.
        }
      }
    }
    _entries.clear();
  }
}

/// Metadata written by [NasManager] alongside a synchronized comic library.
///
/// It deliberately contains only the information needed to browse the NAS.
/// Loading the index is read-only; an explicit [NasLibraryService.downloadComic]
/// call is required before anything is added to the local SQLite library.
class NasLibraryComic with HistoryMixin {
  const NasLibraryComic({
    required this.id,
    required this.sourceKey,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.cover,
    required this.chapters,
    required this.downloadedChapters,
    required this.createdAt,
  });

  @override
  final String id;
  final String sourceKey;
  @override
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;
  @override
  final String cover;
  final ComicChapters? chapters;
  final List<String> downloadedChapters;
  final DateTime? createdAt;

  bool get hasChapters => chapters != null;

  /// Returns the best source identifier available for persistence.
  ///
  /// Older NAS indexes were generated from a local row that only knew the
  /// integer source hash, so they contain `Unknown:<hash>`.  The directory
  /// hierarchy still carries the source folder (for example `Picacg/...`),
  /// which lets us repair those old records instead of losing the source name
  /// forever.  New indexes keep the exact source key and take the first path.
  String get resolvedSourceKey {
    final stored = sourceKey.trim();
    if (!stored.startsWith('Unknown:')) return stored;
    final normalized = normalizeRemotePath(directory);
    final first = normalized.split('/').first.trim();
    if (first.isEmpty || first.toLowerCase().startsWith('source ')) {
      return stored;
    }
    for (final source in ComicSource.all()) {
      if (source.key.toLowerCase() == first.toLowerCase() ||
          source.name.toLowerCase() == first.toLowerCase()) {
        return source.key;
      }
    }
    return first.toLowerCase();
  }

  ComicType get comicType {
    const unknownPrefix = 'Unknown:';
    if (sourceKey.startsWith(unknownPrefix)) {
      final value = int.tryParse(sourceKey.substring(unknownPrefix.length));
      if (value != null) return ComicType(value);
    }
    return ComicType.fromKey(sourceKey);
  }

  @override
  String? get subTitle => subtitle;

  @override
  HistoryType get historyType => comicType;

  factory NasLibraryComic.fromJson(Map<String, dynamic> json) {
    final tags = json['tags'];
    final downloaded = json['downloadedChapters'];
    return NasLibraryComic(
      id: json['id']?.toString() ?? '',
      sourceKey: json['sourceKey']?.toString() ?? 'local',
      title: json['title']?.toString() ?? 'Untitled',
      subtitle: (json['subtitle'] ?? json['subTitle'])?.toString() ?? '',
      tags: tags is List ? tags.map((value) => value.toString()).toList() : [],
      directory: json['directory']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      chapters: ComicChapters.fromJsonOrNull(json['chapters']),
      downloadedChapters: downloaded is List
          ? downloaded.map((value) => value.toString()).toList()
          : [],
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
    );
  }
}

/// Reads the NAS index and individual image files for one configured NAS.
class NasLibraryService {
  NasLibraryService(this.connection);

  final NasConnection connection;

  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'jpe',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  String get _indexPath =>
      joinRemotePath([connection.remotePath, '_venera', 'library-index.json']);

  String get _manifestPath =>
      joinRemotePath([connection.remotePath, '_venera', 'sync-manifest.json']);

  Future<Map<String, ({int size, String hash})>> _loadManifest() async {
    final bytes = await _withClient(
      (client) => client.readBytes(_manifestPath),
    );
    if (bytes == null) return {};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['format'] != 1 || decoded['files'] is! Map) {
      throw const FormatException('The NAS sync manifest is invalid');
    }
    final result = <String, ({int size, String hash})>{};
    for (final entry in (decoded['files'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final item = entry.value as Map;
      if (item['size'] is num && item['sha256'] is String) {
        result[entry.key as String] = (
          size: (item['size'] as num).toInt(),
          hash: item['sha256'] as String,
        );
      }
    }
    return result;
  }

  Future<List<NasLibraryComic>> loadComics() async {
    final bytes = await _withClient((client) => client.readBytes(_indexPath));
    if (bytes == null) {
      throw StateError('The NAS has no Venera library index yet');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['comics'] is! List) {
      throw const FormatException('The NAS library index is invalid');
    }
    final comics = <NasLibraryComic>[];
    for (final entry in decoded['comics'] as List) {
      try {
        if (entry is Map) {
          final comic = NasLibraryComic.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (comic.directory.isNotEmpty) comics.add(comic);
        }
      } catch (_) {
        // A malformed comic record must not hide the remaining NAS library.
      }
    }
    comics.sort((a, b) {
      final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return comics;
  }

  Future<Uint8List?> readComicFile(NasLibraryComic comic, String relativePath) {
    return _withClient(
      (client) => client.readBytes(_comicPath(comic, relativePath)),
    );
  }

  Future<List<String>> imagePaths(NasLibraryComic comic, {String? chapterId}) =>
      _withClient((client) => _imagePaths(client, comic, chapterId));

  /// Downloads the files currently available for [comic] into the local
  /// library and registers the result as a normal [LocalComic].  The NAS
  /// marker is written only after every file has been read successfully, so a
  /// partial transfer can never be mistaken for a fully synchronized comic.
  Future<LocalComic> downloadComic(
    NasLibraryComic comic, {
    NasLibraryDownloadProgress? onProgress,
  }) async {
    final type = comic.comicType;
    final existing = LocalManager().find(comic.id, type);
    final baseDirectory = await _findLocalDirectory(comic, existing);
    final base = Directory(baseDirectory);
    final staging = Directory(
      '${base.path}.venera-download-${DateTime.now().microsecondsSinceEpoch}',
    );
    final manifest = await _loadManifest();
    await staging.create(recursive: true);

    final session = openSession();
    final remoteFiles = <String>[];
    final downloadedChapters = <String>[];
    try {
      if (comic.cover.trim().isNotEmpty) {
        remoteFiles.add(_relativeFilePath(comic.cover));
      }

      if (comic.chapters == null) {
        remoteFiles.addAll(await session.imagePaths(comic));
      } else {
        // Older index files did not always persist downloadedChapters.  In
        // that case probe all chapter directories and keep only those that
        // actually contain images.
        final chapterIds = comic.downloadedChapters.isNotEmpty
            ? comic.downloadedChapters
            : comic.chapters!.ids.toList();
        for (final chapterId in chapterIds) {
          final images = await session.imagePaths(comic, chapterId: chapterId);
          if (images.isEmpty) continue;
          downloadedChapters.add(chapterId);
          remoteFiles.addAll(images);
        }
      }

      final files = <String>[];
      final seen = <String>{};
      for (final path in remoteFiles) {
        final normalized = _relativeFilePath(path);
        if (seen.add(normalized)) files.add(normalized);
      }
      if (files.isEmpty) {
        throw StateError('No readable files found for this comic on the NAS');
      }

      for (var index = 0; index < files.length; index++) {
        final relative = files[index];
        final bytes = await session.readComicFile(comic, relative);
        if (bytes == null || bytes.isEmpty) {
          throw StateError('NAS file not found: $relative');
        }
        final expected = manifest[joinRemotePath([comic.directory, relative])];
        if (expected != null &&
            (bytes.length != expected.size ||
                sha256.convert(bytes).toString() != expected.hash)) {
          throw StateError('NAS file checksum mismatch: $relative');
        }
        final stagedFile = File(FilePath.join(staging.path, relative));
        await stagedFile.parent.create(recursive: true);
        await stagedFile.writeAsBytes(bytes, flush: true);
        onProgress?.call(index + 1, files.length, relative);
      }

      final allDownloadedChapters = <String>{
        ...?existing?.downloadedChapters,
        ...downloadedChapters,
      }.toList();
      final localComic = LocalComic(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        tags: List<String>.from(comic.tags),
        directory: LocalManager().relativeDirectoryOf(base.path),
        chapters: comic.chapters,
        cover: comic.cover.trim().isEmpty ? '' : _relativeFilePath(comic.cover),
        comicType: type,
        originalSourceKey: comic.resolvedSourceKey,
        downloadedChapters: allDownloadedChapters,
        createdAt: comic.createdAt ?? DateTime.now(),
      );
      final install = await NasFileInstall.begin(staging, base, files);
      try {
        await LocalManager().add(localComic);
      } catch (_) {
        await install.rollback();
        rethrow;
      }
      await install.finish();
      final persisted = LocalManager().find(comic.id, type) ?? localComic;
      try {
        await NasManager.instance.markComicSynced(connection.id, persisted);
      } catch (error, stack) {
        Log.error(
          'NAS',
          'Downloaded comic, but could not save its sync marker: $error',
          stack,
        );
      }
      return persisted;
    } finally {
      await session.close();
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (error, stack) {
        Log.error(
          'NAS',
          'Could not remove NAS download staging files: $error',
          stack,
        );
      }
    }
  }

  NasLibrarySession openSession() => NasLibrarySession._(this);

  Future<List<String>> _imagePaths(
    NasRemoteClient client,
    NasLibraryComic comic,
    String? chapterId,
  ) async {
    final relativeDirectory = chapterId == null
        ? ''
        : LocalManager.getChapterDirectoryName(chapterId);
    final directory = _comicPath(comic, relativeDirectory);
    final entries = await client.listDirectory(directory);
    final names =
        entries
            .where(
              (entry) =>
                  !entry.isDirectory &&
                  !entry.name.startsWith('.') &&
                  !entry.name.toLowerCase().startsWith('cover.') &&
                  _isImage(entry.name),
            )
            .map((entry) => entry.name)
            .toList()
          ..sort(_compareImageNames);
    return names
        .map((name) => joinRemotePath([relativeDirectory, name]))
        .toList();
  }

  String _comicPath(NasLibraryComic comic, String relativePath) =>
      joinRemotePath([
        connection.remotePath,
        'library',
        normalizeRemotePath(comic.directory),
        relativePath,
      ]);

  String _relativeFilePath(String path) {
    final normalized = normalizeRemotePath(path);
    if (normalized.isEmpty) {
      throw const FormatException('NAS file path cannot be empty');
    }
    return normalized;
  }

  Future<String> _findLocalDirectory(
    NasLibraryComic comic,
    LocalComic? existing,
  ) async {
    if (existing != null) return existing.baseDir;

    String? candidatePath;
    try {
      final relative = normalizeRemotePath(comic.directory);
      if (relative.isNotEmpty) {
        candidatePath = FilePath.join(LocalManager().path, relative);
      }
    } catch (_) {
      candidatePath = null;
    }
    if (candidatePath != null) {
      final candidate = Directory(candidatePath);
      final occupied = LocalManager()
          .getComics(LocalSortType.timeDesc)
          .any((item) => item.baseDir == candidate.path);
      if (!occupied &&
          (!candidate.existsSync() || candidate.listSync().isEmpty)) {
        return candidate.path;
      }
    }
    final directory = await LocalManager().findValidDirectory(
      comic.id,
      comic.comicType,
      comic.title,
      author: comic.subtitle,
      sourceKey: comic.resolvedSourceKey,
    );
    return directory.path;
  }

  bool _isImage(String path) {
    final dot = path.lastIndexOf('.');
    return dot >= 0 &&
        _imageExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  int _compareImageNames(String a, String b) {
    int? number(String value) => int.tryParse(value.split('.').first);
    final aNumber = number(a);
    final bNumber = number(b);
    if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
    return a.compareTo(b);
  }

  Future<T> _withClient<T>(
    Future<T> Function(NasRemoteClient client) action,
  ) async {
    final client = createNasRemoteClient(connection);
    try {
      await client.connect();
      return await action(client);
    } finally {
      try {
        await client.close();
      } catch (_) {}
    }
  }
}

/// A connected NAS session for reading one comic. Keeping it open while the
/// reader is visible avoids a fresh SMB/FTP/WebDAV login for every page turn.
class NasLibrarySession {
  NasLibrarySession._(this._service);

  final NasLibraryService _service;
  NasRemoteClient? _client;
  Future<void> _operation = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _operation;
    final gate = Completer<void>();
    _operation = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<NasRemoteClient> _connectedClient() async {
    final current = _client;
    if (current != null) return current;
    final client = createNasRemoteClient(_service.connection);
    try {
      await client.connect();
      _client = client;
      return client;
    } catch (_) {
      try {
        await client.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List?> readComicFile(
    NasLibraryComic comic,
    String relativePath,
  ) async {
    return _exclusive(() async {
      final path = _service._comicPath(comic, relativePath);
      // FTP servers in particular do not permit overlapping commands on one
      // control connection.  Serialize reads and reconnect once after a
      // dropped/expired connection so page preloading cannot break the
      // reader for the rest of the session.
      for (var attempt = 0; attempt < 2; attempt++) {
        final client = await _connectedClient();
        final bytes = await client.readBytes(path);
        if (bytes != null && bytes.isNotEmpty) return bytes;
        await close();
      }
      return null;
    });
  }

  Future<List<String>> imagePaths(
    NasLibraryComic comic, {
    String? chapterId,
  }) async {
    return _exclusive(() async {
      final client = await _connectedClient();
      return _service._imagePaths(client, comic, chapterId);
    });
  }

  Future<void> close() async {
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      await client.close();
    } catch (_) {}
  }
}

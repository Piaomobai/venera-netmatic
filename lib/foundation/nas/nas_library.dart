import 'dart:convert';
import 'dart:typed_data';

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

import 'nas_connection.dart';
import 'nas_remote_client.dart';

/// Metadata written by [NasManager] alongside a synchronized comic library.
///
/// It deliberately contains only the information needed to browse the NAS. It
/// does not add NAS records to the local SQLite library, so browsing a remote
/// connection never changes the user's local collection.
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
        comic.directory,
        relativePath,
      ]);

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
    final client = await _connectedClient();
    return client.readBytes(_service._comicPath(comic, relativePath));
  }

  Future<List<String>> imagePaths(
    NasLibraryComic comic, {
    String? chapterId,
  }) async {
    final client = await _connectedClient();
    return _service._imagePaths(client, comic, chapterId);
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

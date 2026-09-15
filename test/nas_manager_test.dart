import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';

void main() {
  late Directory dataDirectory;
  late Object? oldMarkers;

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp('venera-nas-test-');
    App.dataPath = dataDirectory.path;
    oldMarkers = appdata.settings['nasSyncedComics'];
    appdata.settings['nasSyncedComics'] = <String, dynamic>{};
  });

  tearDown(() async {
    appdata.settings['nasSyncedComics'] = oldMarkers;
    await dataDirectory.delete(recursive: true);
  });

  test('a current marker is accepted and changes invalidate it', () async {
    final comic = LocalComic(
      id: 'comic-1',
      title: 'Comic',
      subtitle: 'Author',
      tags: ['tag'],
      directory: 'source/Author/Comic',
      chapters: ComicChapters({'chapter-1': 'Chapter 1'}),
      cover: 'cover.webp',
      comicType: ComicType.local,
      downloadedChapters: ['chapter-1'],
      createdAt: DateTime(2026, 9, 13),
    );

    final manager = NasManager.instance;
    expect(manager.isComicSynced('nas-1', comic), isFalse);
    await manager.markComicSynced('nas-1', comic);
    expect(manager.isComicSynced('nas-1', comic), isTrue);

    final changed = LocalComic(
      id: 'comic-1',
      title: 'Comic',
      subtitle: 'Author',
      tags: ['tag'],
      directory: 'source/Author/Comic',
      chapters: ComicChapters({
        'chapter-1': 'Chapter 1',
        'chapter-2': 'Chapter 2',
      }),
      cover: 'cover.webp',
      comicType: ComicType.local,
      downloadedChapters: ['chapter-1', 'chapter-2'],
      createdAt: DateTime(2026, 9, 13),
    );
    expect(manager.isComicSynced('nas-1', changed), isFalse);
  });

  test('merging NAS index preserves comics absent from this device', () {
    final existing = {
      'format': 1,
      'generatedAt': '2026-09-14T00:00:00.000Z',
      'deviceMetadata': {'owner': 'other-device'},
      'comics': [
        {
          'id': 'nas-only',
          'sourceKey': 'jm',
          'title': 'Downloaded on another device',
          'directory': '禁漫天堂/Author/NAS only',
        },
        {
          'id': 'existing-local-copy',
          'sourceKey': 'picacg',
          'title': 'Old title',
          'directory': 'Picacg/Author/Comic',
        },
      ],
    };

    final merged = mergeNasLibraryIndex(existing, [
      _networkComic(
        id: 'existing-local-copy',
        sourceKey: 'picacg',
        title: 'Updated title',
        directory: 'Picacg/Author/Comic',
      ),
    ]);

    final comics = merged['comics'] as List;
    expect(comics, hasLength(2));
    expect((comics[0] as Map)['id'], 'nas-only');
    expect((comics[1] as Map)['title'], 'Updated title');
    expect(merged['deviceMetadata'], {'owner': 'other-device'});
  });

  test('empty local sync leaves the NAS comic list intact', () {
    final existingComics = [
      {
        'id': 'nas-only',
        'sourceKey': 'jm',
        'title': 'NAS comic',
        'directory': '禁漫天堂/Author/Comic',
      },
    ];

    final merged = mergeNasLibraryIndex({
      'format': 1,
      'comics': existingComics,
    }, const []);

    expect(merged['comics'], existingComics);
  });

  test('same comic id from different sources remains a separate record', () {
    final merged = mergeNasLibraryIndex(
      {
        'format': 1,
        'comics': [
          {
            'id': '42',
            'sourceKey': 'picacg',
            'title': 'Pica comic',
            'directory': 'Picacg/Author/Pica comic',
          },
          {
            'id': '42',
            'sourceKey': 'jm',
            'title': 'JM comic',
            'directory': '禁漫天堂/Author/JM comic',
          },
        ],
      },
      [
        _networkComic(
          id: '42',
          sourceKey: 'picacg',
          title: 'Updated Pica comic',
          directory: 'Picacg/Author/Pica comic',
        ),
      ],
    );

    final comics = merged['comics'] as List;
    expect(comics, hasLength(2));
    expect((comics[0] as Map)['title'], 'Updated Pica comic');
    expect((comics[1] as Map)['title'], 'JM comic');
  });

  test('legacy source hash is matched by its source directory', () {
    final merged = mergeNasLibraryIndex(
      {
        'format': 1,
        'comics': [
          {
            'id': 'comic-1',
            'sourceKey': 'Unknown:553570794',
            'title': 'Old record',
            'directory': 'Picacg/Author/Comic',
          },
        ],
      },
      [
        _networkComic(
          id: 'comic-1',
          sourceKey: 'picacg',
          title: 'Repaired record',
          directory: 'Picacg/Author/Comic',
        ),
      ],
    );

    final comics = merged['comics'] as List;
    expect(comics, hasLength(1));
    expect((comics.single as Map)['title'], 'Repaired record');
  });

  test('refuses to merge an invalid NAS index', () {
    expect(
      () => mergeNasLibraryIndex({'format': 1, 'comics': null}, []),
      throwsFormatException,
    );
    expect(
      () => mergeNasLibraryIndex({'format': 2, 'comics': []}, []),
      throwsFormatException,
    );
  });
}

LocalComic _networkComic({
  required String id,
  required String sourceKey,
  required String title,
  required String directory,
}) => LocalComic(
  id: id,
  title: title,
  subtitle: 'Author',
  tags: const [],
  directory: directory,
  chapters: null,
  cover: '',
  comicType: ComicType(sourceKey.hashCode),
  originalSourceKey: sourceKey,
  downloadedChapters: const [],
  createdAt: DateTime.utc(2026, 9, 13),
);

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
}

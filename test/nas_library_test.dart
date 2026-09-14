import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/nas/nas_library.dart';
import 'package:venera/pages/nas_library_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() {
    AppTranslation.translations = {
      'zh_CN': <String, String>{},
      'zh_TW': <String, String>{},
    };
  });

  test('parses the synchronized NAS library index comic format', () {
    final comic = NasLibraryComic.fromJson({
      'id': '42',
      'sourceKey': 'picacg',
      'title': 'NAS comic',
      'subTitle': 'Author',
      'tags': ['Action', 'Colour'],
      'directory': 'source/Author/NAS comic',
      'cover': 'cover.webp',
      'chapters': {'chapter-1': 'Chapter 1'},
      'downloadedChapters': ['chapter-1'],
      'createdAt': '2026-09-13T00:00:00.000Z',
    });

    expect(comic.id, '42');
    expect(comic.sourceKey, 'picacg');
    expect(comic.title, 'NAS comic');
    expect(comic.subtitle, 'Author');
    expect(comic.tags, ['Action', 'Colour']);
    expect(comic.directory, 'source/Author/NAS comic');
    expect(comic.cover, 'cover.webp');
    expect(comic.chapters?.ids, ['chapter-1']);
    expect(comic.downloadedChapters, ['chapter-1']);
    expect(comic.createdAt, isNotNull);
  });

  test(
    'keeps the library browseable when optional index values are absent',
    () {
      final comic = NasLibraryComic.fromJson({
        'title': 'Untitled NAS comic',
        'directory': 'local/Untitled NAS comic',
      });

      expect(comic.subtitle, isEmpty);
      expect(comic.sourceKey, 'local');
      expect(comic.tags, isEmpty);
      expect(comic.chapters, isNull);
      expect(comic.downloadedChapters, isEmpty);
    },
  );

  test('recovers a source key from legacy NAS directory metadata', () {
    final comic = NasLibraryComic.fromJson({
      'sourceKey': 'Unknown:553570794',
      'title': 'Legacy NAS comic',
      'directory': 'Picacg/Author/Legacy NAS comic',
    });

    expect(comic.resolvedSourceKey, 'picacg');
  });

  testWidgets('offers direct NAS connection management when none exist', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NasLibraryPage()));
    await tester.pump();

    expect(find.text('NAS Library'), findsOneWidget);
    expect(find.text('No NAS connections yet'), findsOneWidget);
    expect(find.byKey(const Key('nas-library-connections')), findsOneWidget);
  });
}

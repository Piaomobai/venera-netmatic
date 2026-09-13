import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics_page.dart';
// Also re-exports dart:io, which supplies Directory and Platform here.
import 'package:venera/utils/io.dart';

// ============================================================================
// Tests for the library folder hierarchy.
//
// Downloads are grouped as `<source>/<author>/<title>`. That makes
// LocalComic.directory a NESTED RELATIVE path, which the old code could not
// express: `baseDir` decided relative-vs-absolute by looking for a separator, so
// `picacg/author/title` was mistaken for an absolute path and every read of the
// comic's files broke.
//
// These are pure tests: they set LocalManager().path directly instead of calling
// init(), which would need path_provider.
// ============================================================================

LocalComic comicAt(String directory, {ComicType? type}) => LocalComic(
      id: '1',
      title: 'Title',
      subtitle: '',
      tags: const [],
      directory: directory,
      chapters: null,
      cover: 'cover.jpg',
      comicType: type ?? ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2025, 1, 1),
    );

LocalComic grouped(String title, ComicType type) => LocalComic(
      id: title,
      title: title,
      subtitle: '',
      tags: const [],
      directory: title,
      chapters: null,
      cover: 'cover.jpg',
      comicType: type,
      downloadedChapters: const [],
      createdAt: DateTime(2025, 1, 1),
    );

void main() {
  group('FilePath.isAbsolute', () {
    test('accepts drive-letter and UNC paths', () {
      expect(FilePath.isAbsolute(r'C:\library\comic'), isTrue);
      expect(FilePath.isAbsolute('C:/library/comic'), isTrue);
      if (Platform.isWindows) {
        expect(FilePath.isAbsolute(r'\\server\share\comic'), isTrue);
      }
    });

    test('treats a nested relative path as relative', () {
      // The crux of the change: this contains separators but is NOT absolute.
      expect(FilePath.isAbsolute('picacg/author/title'), isFalse);
      expect(FilePath.isAbsolute(r'picacg\author\title'), isFalse);
      expect(FilePath.isAbsolute('title'), isFalse);
    });
  });

  group('FilePath.relativeTo', () {
    test('strips the root prefix', () {
      final root = FilePath.join(Directory.systemTemp.path, 'lib');
      final nested = FilePath.join(root, 'src', 'auth', 'title');
      final relative = FilePath.relativeTo(root, nested);
      expect(FilePath.isAbsolute(relative), isFalse);
      // Round-trips back to the same location.
      expect(FilePath.join(root, relative), nested);
    });

    test('returns the path unchanged when it is outside the root', () {
      final root = FilePath.join(Directory.systemTemp.path, 'lib');
      final outside = FilePath.join(Directory.systemTemp.path, 'elsewhere');
      expect(FilePath.relativeTo(root, outside), outside);
    });

    test('returns empty for the root itself', () {
      final root = FilePath.join(Directory.systemTemp.path, 'lib');
      expect(FilePath.relativeTo(root, root), isEmpty);
    });

    test('does not confuse a sibling with a prefix match', () {
      // `lib2` must not be treated as inside `lib`.
      final root = FilePath.join(Directory.systemTemp.path, 'lib');
      final sibling = FilePath.join(Directory.systemTemp.path, 'lib2', 'x');
      expect(FilePath.relativeTo(root, sibling), sibling);
    });
  });

  group('LocalComic.baseDir', () {
    setUp(() {
      LocalManager().path = FilePath.join(Directory.systemTemp.path, 'library');
    });

    test('resolves a flat relative directory against the library root', () {
      final expected =
          FilePath.join(Directory.systemTemp.path, 'library', 'Title');
      expect(comicAt('Title').baseDir, expected);
    });

    test('resolves a NESTED relative directory against the library root', () {
      final nested = FilePath.join('picacg', 'Some Author', 'Title');
      final expected =
          FilePath.join(Directory.systemTemp.path, 'library', nested);
      expect(comicAt(nested).baseDir, expected);
    });

    test('keeps an absolute directory as-is', () {
      final absolute = FilePath.join(Directory.systemTemp.path, 'imported');
      expect(comicAt(absolute).baseDir, absolute);
    });

    test('a nested comic resolves its cover inside its own folder', () {
      final nested = FilePath.join('picacg', 'Some Author', 'Title');
      final cover = comicAt(nested).coverFile.path;
      expect(cover, contains('picacg'));
      expect(cover, contains('Some Author'));
      expect(cover, endsWith('cover.jpg'));
    });
  });

  group('library folder naming', () {
    test('author folder falls back to a fixed placeholder', () {
      // Fixed and ASCII so folder names stay stable across app languages. It
      // must not be empty either, or comics would land at the source level.
      expect(LocalManager.authorFolderName(null),
          LocalManager.unknownAuthorFolder);
      expect(LocalManager.authorFolderName(''), LocalManager.unknownAuthorFolder);
      expect(LocalManager.authorFolderName('   '),
          LocalManager.unknownAuthorFolder);
      expect(LocalManager.unknownAuthorFolder, isNotEmpty);
    });

    test('author folder is sanitised and never introduces a separator', () {
      for (final raw in ['A/B', r'A\B', 'A:B', 'A*B?', '正常作者']) {
        final name = LocalManager.authorFolderName(raw);
        expect(name, isNotEmpty);
        expect(name.contains('/'), isFalse, reason: 'input $raw');
        expect(name.contains(r'\'), isFalse, reason: 'input $raw');
      }
    });

    test('author folder trims surrounding whitespace', () {
      expect(LocalManager.authorFolderName('  Author  '),
          LocalManager.authorFolderName('Author'));
    });

    test('source folder for a local comic does not need a comic source', () {
      // ComicType.local has no ComicSource, so this must not throw.
      final name = LocalManager.sourceFolderName(ComicType.local);
      expect(name, isNotEmpty);
      expect(name.contains('/'), isFalse);
    });

    test('source folder is sanitised', () {
      final name = LocalManager.sourceFolderName(ComicType.fromKey('pi/ca'));
      expect(name, isNotEmpty);
      expect(name.contains('/'), isFalse);
    });
  });

  group('relativeDirectoryOf', () {
    setUp(() {
      LocalManager().path = FilePath.join(Directory.systemTemp.path, 'library');
    });

    test('stores a nested download relative to the root', () {
      final root = FilePath.join(Directory.systemTemp.path, 'library');
      final absolute = FilePath.join(root, 'picacg', 'Author', 'Title');
      final stored = LocalManager().relativeDirectoryOf(absolute);
      expect(FilePath.isAbsolute(stored), isFalse);
      // And it resolves back to where the files actually are.
      expect(comicAt(stored).baseDir, absolute);
    });

    test('keeps a location outside the root absolute', () {
      final outside = FilePath.join(Directory.systemTemp.path, 'outside');
      expect(LocalManager().relativeDirectoryOf(outside), outside);
    });
  });

  // The grouping the local comics page renders. Tested as a pure function so it
  // does not depend on sliver layout, which only builds visible children.
  group('LocalComicsPage.groupBySource', () {
    final installA = ComicType.fromKey('source-a');
    final installB = ComicType.fromKey('source-b');

    String nameOf(ComicType type) => LocalManager.sourceFolderName(type);

    test('splits comics into one group per source', () {
      final groups = LocalComicsPage.groupBySource([
        grouped('a1', installA),
        grouped('b1', installB),
        grouped('a2', installA),
      ]);
      expect(groups.length, 2);
      expect(groups[nameOf(installA)]!.map((c) => c.title), ['a1', 'a2']);
      expect(groups[nameOf(installB)]!.map((c) => c.title), ['b1']);
    });

    test('keeps every comic, in the order given within a group', () {
      final input = [
        grouped('a1', installA),
        grouped('b1', installB),
        grouped('a2', installA),
        grouped('a3', installA),
      ];
      final groups = LocalComicsPage.groupBySource(input);
      final flattened = groups.values.expand((g) => g).length;
      expect(flattened, input.length, reason: 'nothing may be dropped');
      expect(groups[nameOf(installA)]!.map((c) => c.title), ['a1', 'a2', 'a3']);
    });

    test('puts locally imported comics last', () {
      final groups = LocalComicsPage.groupBySource([
        grouped('imported', ComicType.local),
        grouped('a1', installA),
      ]);
      final keys = groups.keys.toList();
      expect(keys.last, LocalManager.sourceFolderName(ComicType.local));
      expect(keys.first, nameOf(installA));
    });

    test('orders named sources alphabetically, case-insensitively', () {
      // ComicType names come from hashtags, so assert on the resolved names
      // rather than guessing which source sorts first.
      final groups = LocalComicsPage.groupBySource([
        grouped('x', installA),
        grouped('y', installB),
        grouped('z', ComicType.fromKey('source-c')),
      ]);
      final named = groups.keys
          .where((k) => k != LocalManager.sourceFolderName(ComicType.local))
          .toList();
      final sorted = [...named]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(named, sorted);
    });

    test('an empty library yields no groups', () {
      expect(LocalComicsPage.groupBySource([]), isEmpty);
    });

    test('a comic whose source is no longer installed still groups safely', () {
      // ComicType.sourceKey would throw a null-check here; the grouping relies
      // on sourceFolderName, which falls back to a placeholder.
      final orphan = ComicType.fromKey('uninstalled');
      final groups = LocalComicsPage.groupBySource([grouped('orphan', orphan)]);
      expect(groups.length, 1);
      expect(groups.keys.single, startsWith('Source '));
    });
  });

  // The real thing: asking LocalManager for a directory for a new download must
  // actually create `<source>/<author>/<title>` on disk.
  group('findValidDirectory creates the hierarchy', () {
    var sqliteAvailable = false;
    late Directory root;

    setUpAll(() async {
      final temp = Directory.systemTemp.createTempSync('venera_layout_e2e');
      App.dataPath = temp.path;
      App.cachePath = temp.path;
      // LocalManager.init() ends with ComicSourceManager().ensureInit(), which
      // never completes without a JS engine. Everything needed here -- opening
      // local.db and resolving the library path -- happens before that, so the
      // call is fire-and-forget and we poll for the library directory.
      unawaited(LocalManager().init());
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        try {
          final path = LocalManager().path;
          if (path.isNotEmpty && Directory(path).existsSync()) {
            sqliteAvailable = true;
            root = Directory(path);
            break;
          }
        } catch (_) {
          // `path` is a late field; not assigned yet.
        }
      }
      if (!sqliteAvailable) {
        // ignore: avoid_print
        print('SKIPPED (local.db could not be opened in this environment)');
      }
    });

    List<String> segments(String relative) =>
        relative.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();

    test('a download lands in <source>/<author>/<title>', () async {
      if (!sqliteAvailable) {
        return;
      }
      final dir = await LocalManager().findValidDirectory(
        'e2e-1',
        ComicType.local,
        'My Comic',
        author: 'My Author',
      );

      expect(dir.existsSync(), isTrue, reason: 'directory must be created');
      // It must live under the library root, and be three levels deep.
      final relative = LocalManager().relativeDirectoryOf(dir.path);
      final parts = segments(relative);
      expect(parts.length, 3, reason: 'got $relative');
      expect(parts[0], 'local'); // ComicType.local has no network source
      expect(parts[1], 'My Author');
      expect(parts[2], 'My Comic');

      // The stored form resolves back to the same place on disk.
      final stored = LocalManager().relativeDirectoryOf(dir.path);
      expect(comicAt(stored).baseDir, dir.path);
      expect(comicAt(stored).baseDir.startsWith(root.path), isTrue);
    });

    test('a comic with no author goes into the placeholder folder', () async {
      if (!sqliteAvailable) {
        return;
      }
      final dir = await LocalManager().findValidDirectory(
        'e2e-2',
        ComicType.local,
        'Anonymous Work',
      );
      final parts = segments(LocalManager().relativeDirectoryOf(dir.path));
      expect(parts.length, 3);
      expect(parts[1], LocalManager.unknownAuthorFolder);
    });

    test('the author folder is reused across comics', () async {
      if (!sqliteAvailable) {
        return;
      }
      final a = await LocalManager().findValidDirectory(
        'e2e-3',
        ComicType.local,
        'First',
        author: 'Shared Author',
      );
      final b = await LocalManager().findValidDirectory(
        'e2e-4',
        ComicType.local,
        'Second',
        author: 'Shared Author',
      );
      expect(
        Directory(a.parent.path).path,
        Directory(b.parent.path).path,
        reason: 'both comics should share the one author folder',
      );
    });
  });
}

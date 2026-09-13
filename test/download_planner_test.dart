import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scheduler/tasks/comic_download_planner.dart';

// ============================================================================
// Tests for the incremental download delta.
//
// This is the core of the "only fetch chapters that appeared since last time"
// behaviour, and it was previously untestable because it read LocalManager
// directly. Extracting ComicDownloadPlanner.computeDelta made it a pure
// function, so the whole decision table is covered here without a Flutter
// binding, path_provider, or a real library on disk.
//
// The failure mode this guards against is expensive and quiet: passing the
// wrong chapter list to ImagesDownloadTask silently re-downloads chapters that
// are already stored, or downloads nothing at all.
// ============================================================================

void main() {
  ChapterDelta delta({
    required List<String> source,
    List<String> downloaded = const [],
    bool hasChapterList = true,
    bool existsLocally = false,
  }) {
    return ComicDownloadPlanner.computeDelta(
      sourceChapterIds: source,
      hasChapterList: hasChapterList,
      downloadedChapters: downloaded,
      comicExistsLocally: existsLocally,
    );
  }

  group('chaptered comics', () {
    test('nothing stored yet means every chapter is missing', () {
      final d = delta(source: ['1', '2', '3']);
      expect(d.missingChapters, ['1', '2', '3']);
      expect(d.missingCount, 3);
      expect(d.hasWork, isTrue);
      expect(d.chapterlessMissing, isFalse);
      // A chaptered comic always passes an explicit list, never null, because
      // null would mean "download every chapter" and ignore the chapter set the
      // source actually exposes.
      expect(d.taskChapters, ['1', '2', '3']);
    });

    test('only the delta is returned', () {
      final d = delta(
        source: ['1', '2', '3', '4'],
        downloaded: ['1', '3'],
        existsLocally: true,
      );
      expect(d.missingChapters, ['2', '4']);
      expect(d.missingCount, 2);
      expect(d.hasWork, isTrue);
    });

    test('a fully downloaded comic has no work', () {
      final d = delta(
        source: ['1', '2', '3'],
        downloaded: ['1', '2', '3'],
        existsLocally: true,
      );
      expect(d.missingChapters, isEmpty);
      expect(d.hasWork, isFalse);
      expect(d.missingCount, 0);
      // taskChapters is an empty list, NOT null: null would trigger a full
      // re-download of a comic that is already complete.
      expect(d.taskChapters, isEmpty);
    });

    test('source ordering is preserved', () {
      final d = delta(source: ['c', 'a', 'b']);
      expect(d.missingChapters, ['c', 'a', 'b']);
    });

    test('newly prepended chapters are detected', () {
      // Sources usually list newest first, so a new chapter appears at the front
      // of the list rather than the end.
      final d = delta(
        source: ['99', '1', '2'],
        downloaded: ['1', '2'],
        existsLocally: true,
      );
      expect(d.missingChapters, ['99']);
      expect(d.hasWork, isTrue);
    });

    test('repeated source ids are de-duplicated, keeping first position', () {
      // ComicChapters.ids walks groups in order, so the same id can in principle
      // appear twice; downloading it twice would be wrong.
      final d = delta(source: ['1', '2', '1', '3', '2']);
      expect(d.missingChapters, ['1', '2', '3']);
      expect(d.missingCount, 3);
    });

    test('stale stored ids that the source no longer lists are ignored', () {
      // A chapter removed upstream must not create phantom work, and must not
      // make an already-complete comic look incomplete.
      final d = delta(
        source: ['1', '2'],
        downloaded: ['1', '2', 'removed-chapter'],
        existsLocally: true,
      );
      expect(d.missingChapters, isEmpty);
      expect(d.hasWork, isFalse);
    });

    test('an empty chapter list means no work, not a full download', () {
      // A source that reports chapters but returns none yet.
      final d = delta(source: const [], existsLocally: true);
      expect(d.missingChapters, isEmpty);
      expect(d.hasWork, isFalse);
      expect(d.taskChapters, isEmpty);
    });
  });

  group('comics with no chapter list', () {
    test('an unstored comic is downloaded whole', () {
      final d = delta(
        source: const [],
        hasChapterList: false,
        existsLocally: false,
      );
      expect(d.chapterlessMissing, isTrue);
      expect(d.hasWork, isTrue);
      expect(d.missingCount, 1);
      // null is the documented way to say "every chapter" for this task.
      expect(d.taskChapters, isNull);
    });

    test('a stored comic has no work', () {
      final d = delta(
        source: const [],
        hasChapterList: false,
        existsLocally: true,
      );
      expect(d.chapterlessMissing, isFalse);
      expect(d.hasWork, isFalse);
      expect(d.taskChapters, isEmpty);
    });

    test('source chapter ids are ignored when there is no chapter list', () {
      // hasChapterList wins: a stale id list must not make a stored comic look
      // incomplete.
      final d = delta(
        source: ['1', '2'],
        hasChapterList: false,
        existsLocally: true,
      );
      expect(d.hasWork, isFalse);
    });
  });

  group('rate limiting', () {
    test('takeMissing caps the batch and keeps order', () {
      final d = delta(source: ['1', '2', '3', '4', '5']);
      final capped = d.takeMissing(2);
      expect(capped.missingChapters, ['1', '2']);
      expect(capped.missingCount, 2);
      expect(capped.hasWork, isTrue);
      // The original is untouched.
      expect(d.missingChapters, ['1', '2', '3', '4', '5']);
    });

    test('takeMissing is a no-op when the batch already fits', () {
      final d = delta(source: ['1', '2']);
      expect(identical(d.takeMissing(5), d), isTrue);
      expect(identical(d.takeMissing(2), d), isTrue);
    });

    test('takeMissing never turns a whole-comic download into nothing', () {
      final d = delta(
        source: const [],
        hasChapterList: false,
        existsLocally: false,
      );
      final capped = d.takeMissing(1);
      expect(capped.chapterlessMissing, isTrue);
      expect(capped.hasWork, isTrue);
      expect(capped.taskChapters, isNull);
      expect(identical(capped, d), isTrue);
    });

    test('a non-positive cap is ignored rather than emptying the plan', () {
      // 0 is the documented "no limit" value in the runner config, so treating
      // it as "download nothing" would silently disable the task.
      final d = delta(source: ['1', '2', '3']);
      expect(identical(d.takeMissing(0), d), isTrue);
      expect(identical(d.takeMissing(-1), d), isTrue);
    });
  });

  // The rule guarding `seen_items`. A comic that is recorded as seen is never
  // offered again, so if this answers "settled" for a comic that was not
  // actually dealt with, that comic is lost silently.
  group('a comic may only be remembered once its download is settled', () {
    test('nothing left to fetch is settled', () {
      expect(DownloadFollowUp.alreadyComplete.isSettled, isTrue);
    });

    test('chapters just queued are settled', () {
      expect(DownloadFollowUp.queued.isSettled, isTrue);
    });

    test('already waiting in the persistent queue is settled', () {
      expect(DownloadFollowUp.alreadyQueued.isSettled, isTrue);
    });

    test('a comic that could not be queued is NOT settled', () {
      expect(DownloadFollowUp.failed.isSettled, isFalse);
    });

    test('failed is the only unsettled outcome', () {
      final unsettled = DownloadFollowUp.values
          .where((action) => !action.isSettled)
          .toList();
      expect(unsettled, [DownloadFollowUp.failed]);
    });
  });

  group('exhaustive agreement', () {
    test('missing set equals source minus downloaded, for every combination',
        () {
      const source = ['a', 'b', 'c'];
      // Every subset of the source as the "already downloaded" set.
      for (var mask = 0; mask < 8; mask++) {
        final downloaded = <String>[
          for (var i = 0; i < 3; i++)
            if ((mask & (1 << i)) != 0) source[i],
        ];
        final d = delta(
          source: source,
          downloaded: downloaded,
          existsLocally: true,
        );
        final expected = source.where((id) => !downloaded.contains(id)).toList();
        expect(
          d.missingChapters,
          expected,
          reason: 'downloaded=$downloaded',
        );
        expect(d.hasWork, expected.isNotEmpty, reason: 'downloaded=$downloaded');
      }
    });
  });
}

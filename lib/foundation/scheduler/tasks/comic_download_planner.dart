import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/network/download.dart';

/// What still has to be fetched, independent of any particular comic.
///
/// This is the pure result of comparing a source's chapter list against what is
/// already stored. Keeping it free of `ComicSource` and `ComicDetails` is what
/// makes the delta logic unit-testable: `ComicDetails` has no public
/// constructor and `LocalManager` needs `path_provider`, so neither is
/// reachable from a plain test.
class ChapterDelta {
  const ChapterDelta({
    this.missingChapters = const [],
    this.chapterlessMissing = false,
  });

  /// Chapter ids present in the source but not yet stored locally, in source
  /// order and de-duplicated.
  final List<String> missingChapters;

  /// True for a comic that has no chapter list and is not stored at all yet.
  final bool chapterlessMissing;

  /// Whether anything needs downloading.
  bool get hasWork => chapterlessMissing || missingChapters.isNotEmpty;

  /// How many chapters (or whole comics) are outstanding.
  int get missingCount => chapterlessMissing ? 1 : missingChapters.length;

  /// The value to pass as `ImagesDownloadTask.chapters`.
  ///
  /// Null means "every chapter", which is only correct for
  /// [chapterlessMissing]. Never use this when [hasWork] is false.
  List<String>? get taskChapters => chapterlessMissing ? null : missingChapters;

  /// A copy limited to the first [max] missing chapters, for rate limiting.
  ChapterDelta takeMissing(int max) {
    if (max <= 0 || chapterlessMissing || missingChapters.length <= max) {
      return this;
    }
    return ChapterDelta(missingChapters: missingChapters.take(max).toList());
  }

  @override
  String toString() => chapterlessMissing
      ? 'ChapterDelta(whole comic)'
      : 'ChapterDelta(${missingChapters.length} missing)';
}

/// What still has to be fetched for one comic.
///
/// `ImagesDownloadTask.resume()` never consults `downloadedChapters` or the
/// filesystem -- it happily re-downloads chapters that are already on disk and
/// overwrites the same `"$index$ext"` filenames. So the delta has to be
/// computed by the caller, which is what [ComicDownloadPlanner] does.
class DownloadPlan {
  const DownloadPlan({
    required this.source,
    required this.details,
    required this.delta,
  });

  final ComicSource source;

  /// Full comic details, so the queued task does not have to re-fetch them.
  final ComicDetails details;

  final ChapterDelta delta;

  String get comicId => details.comicId;

  String get title => details.title;

  bool get hasWork => delta.hasWork;

  int get missingCount => delta.missingCount;

  List<String> get missingChapters => delta.missingChapters;

  bool get chapterlessMissing => delta.chapterlessMissing;

  List<String>? get taskChapters => delta.taskChapters;

  /// How many chapters this comic has in total, when known.
  int get totalChapters => details.chapters?.length ?? 0;

  DownloadPlan takeMissing(int max) => DownloadPlan(
    source: source,
    details: details,
    delta: delta.takeMissing(max),
  );

  @override
  String toString() =>
      'DownloadPlan($comicId, $missingCount missing of $totalChapters)';
}

/// What happened when one comic's download was handed off.
///
/// This exists so the rule that guards "remember this comic and never offer it
/// again" is a value that can be tested on its own. Getting that rule wrong is
/// silent: the comic simply never comes back.
enum DownloadFollowUp {
  /// Nothing was missing; every chapter is already on disk.
  alreadyComplete,

  /// The missing chapters were queued for download this run.
  queued,

  /// The comic was already waiting in the download queue.
  alreadyQueued,

  /// It could not be handed to the download queue at all.
  failed;

  /// Whether the comic's download is settled, and it may therefore be recorded
  /// as dealt with.
  ///
  /// [failed] is deliberately the only value that returns false: an unsettled
  /// comic has to stay out of the record so the next run picks it up again.
  /// Recording is a promise never to offer the comic a second time.
  bool get isSettled => this != DownloadFollowUp.failed;
}

/// Computes and enqueues incremental downloads.
abstract final class ComicDownloadPlanner {
  /// Compares what a source offers against what is already stored.
  ///
  /// Pure: no I/O, no app state. [sourceChapterIds] is ignored unless
  /// [hasChapterList] is true.
  static ChapterDelta computeDelta({
    required Iterable<String> sourceChapterIds,
    required bool hasChapterList,
    required List<String> downloadedChapters,
    required bool comicExistsLocally,
  }) {
    if (!hasChapterList) {
      // No chapter list: the comic is stored as a single flat directory, so it
      // is either entirely present or entirely absent.
      return ChapterDelta(chapterlessMissing: !comicExistsLocally);
    }

    final alreadyHave = downloadedChapters.toSet();
    final missing = <String>[];
    // `seen` both de-duplicates repeated ids and keeps the first occurrence
    // position, so source ordering is preserved.
    final seen = <String>{};
    for (final id in sourceChapterIds) {
      if (alreadyHave.contains(id)) {
        continue;
      }
      if (!seen.add(id)) {
        continue;
      }
      missing.add(id);
    }
    return ChapterDelta(missingChapters: missing);
  }

  /// Works out which chapters of [details] are missing locally.
  ///
  /// Reads only local state; the caller supplies the already-fetched details.
  static DownloadPlan plan(ComicDetails details, ComicSource source) {
    final type = ComicType(source.key.hashCode);
    final local = LocalManager().find(details.comicId, type);
    return DownloadPlan(
      source: source,
      details: details,
      delta: computeDelta(
        sourceChapterIds: details.chapters?.ids ?? const <String>[],
        hasChapterList: details.chapters != null,
        downloadedChapters: local?.downloadedChapters ?? const <String>[],
        comicExistsLocally: local != null,
      ),
    );
  }

  /// Fetches comic details, or null when the source cannot provide them.
  static Future<ComicDetails?> loadDetails(
    ComicSource source,
    String comicId,
  ) async {
    final load = source.loadComicInfo;
    if (load == null) {
      return null;
    }
    try {
      final res = await load(comicId);
      if (res.error) {
        Log.error(
          'Download',
          'Failed to load comic $comicId from ${source.key}: '
              '${res.errorMessage}',
        );
        return null;
      }
      return res.dataOrNull;
    } catch (e, s) {
      Log.error('Download', 'Failed to load comic $comicId: $e', s);
      return null;
    }
  }

  /// Adds [plan] to the download queue.
  ///
  /// Returns true when a task was queued, false when there was nothing to do or
  /// the comic is already queued.
  ///
  /// Note that `LocalManager().addTask` appends to the queue and then resumes
  /// the *head* of the queue, not the task just added, so this does not start
  /// the download immediately. Downloads are serialised by the app.
  static bool enqueue(DownloadPlan plan, {String? nasConnectionId}) {
    if (!plan.hasWork) {
      return false;
    }
    final type = ComicType(plan.source.key.hashCode);
    if (LocalManager().isDownloading(plan.comicId, type)) {
      Log.info(
        'Download',
        'Skipping ${plan.comicId}: already in the download queue',
      );
      return false;
    }
    try {
      LocalManager().addTask(
        ImagesDownloadTask(
          source: plan.source,
          comicId: plan.comicId,
          comic: plan.details,
          chapters: plan.taskChapters,
          nasConnectionId: nasConnectionId,
        ),
      );
      Log.info(
        'Download',
        'Queued ${plan.missingCount} chapter(s) for "${plan.title}"',
      );
      return true;
    } catch (e, s) {
      Log.error('Download', 'Failed to queue ${plan.comicId}: $e', s);
      return false;
    }
  }

  /// Whether [plan]'s comic already sits in the download queue.
  ///
  /// Callers need this to tell "this comic is on its way" apart from "queueing
  /// it failed". Only the former is a settled download; the latter has to be
  /// retried, so it must not be remembered as handled.
  static bool isQueued(DownloadPlan plan) {
    final type = ComicType(plan.source.key.hashCode);
    return LocalManager().isDownloading(plan.comicId, type);
  }

  /// Convenience: fetch details, plan, and enqueue in one call.
  static Future<bool> fetchAndEnqueue(
    ComicSource source,
    String comicId,
  ) async {
    final details = await loadDetails(source, comicId);
    if (details == null) {
      return false;
    }
    return enqueue(plan(details, source));
  }
}

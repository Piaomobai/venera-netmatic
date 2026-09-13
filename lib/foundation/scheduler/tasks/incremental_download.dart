import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scheduler/task.dart';
import 'package:venera/foundation/scheduler/tasks/comic_download_planner.dart';

/// Fetches only the chapters that appeared since the last check, for a set of
/// already-known comics.
///
/// "Silent" here means no dialog and no toast: the work is expressed by queueing
/// tasks in the app's existing download manager, which is already serialised to
/// one download at a time and is already persisted across restarts. Nothing in
/// this runner calls `ImagesDownloadTask.resume()` directly, and it never
/// re-downloads a chapter that is already stored, because
/// [ComicDownloadPlanner.plan] computes the delta first.
class IncrementalDownloadRunner extends SchedulableRunner {
  static const String key = 'incrementalDownload';

  /// Download missing chapters for comics in a favourites folder.
  static const String scopeFavorites = 'favorites';

  /// Download missing chapters for everything already in the local library.
  static const String scopeLibrary = 'library';

  @override
  String get typeKey => key;

  @override
  String get displayName => 'Incremental download';

  @override
  String get description =>
      'Fetch only newly appeared chapters of known comics and queue them for '
      'silent download';

  @override
  Map<String, dynamic> defaultConfig() => <String, dynamic>{
    /// 'favorites' or 'library'.
    'scope': scopeFavorites,

    /// Required when scope is 'favorites'.
    'favoriteFolder': '',

    /// How many comics to inspect per run. The per-comic check costs one
    /// detail request, so this bounds a run's network usage.
    'maxComicsPerRun': 20,

    /// Delay between detail requests, in milliseconds.
    'throttleMs': 300,

    /// Cap on chapters queued per comic. 0 means no cap.
    'maxChaptersPerComic': 0,

    /// Optional NAS connection id. The download is completed locally and
    /// then mirrored to that NAS before the task is marked successful.
    'nasConnectionId': null,
  };

  @override
  String? validateConfig(Map<String, dynamic> config) {
    final scope = config['scope'];
    if (scope is String && scope != scopeFavorites && scope != scopeLibrary) {
      return 'Scope must be "$scopeFavorites" or "$scopeLibrary"';
    }
    final effectiveScope = scope is String ? scope : scopeFavorites;
    if (effectiveScope == scopeFavorites) {
      final folder = config['favoriteFolder'];
      if (folder is! String || folder.trim().isEmpty) {
        return 'A favourites folder is required for the favourites scope';
      }
    }
    final maxComics = config['maxComicsPerRun'];
    if (maxComics is num && maxComics < 1) {
      return 'Maximum comics per run must be at least 1';
    }
    final maxChapters = config['maxChaptersPerComic'];
    if (maxChapters is num && maxChapters < 0) {
      return 'Maximum chapters per comic must not be negative';
    }
    return null;
  }

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    final scope = context.configValue('scope', scopeFavorites);
    final maxComics = context.configValue('maxComicsPerRun', 20).clamp(1, 1000);
    final throttleMs = context.configValue('throttleMs', 300).clamp(0, 10000);
    final maxChapters = context
        .configValue('maxChaptersPerComic', 0)
        .clamp(0, 100000);
    final nasConnectionId = context.task.config['nasConnectionId'] as String?;

    final targets = _collectTargets(context, scope);
    if (targets.isEmpty) {
      return TaskRunOutcome.skipped(
        scope == scopeLibrary
            ? 'The local library is empty'
            : 'No comics found in the configured favourites folder',
      );
    }

    var checked = 0;
    var queued = 0;
    var chaptersQueued = 0;
    var upToDate = 0;
    var failures = 0;

    for (final target in targets) {
      if (checked >= maxComics) {
        break;
      }
      context.throwIfCancelled();
      checked++;

      final details = await ComicDownloadPlanner.loadDetails(
        target.source,
        target.comicId,
      );
      if (details == null) {
        failures++;
        context.log('Failed to load "${target.name}"');
        continue;
      }

      // Keep the favourites "has new chapters" badge honest.
      if (target.folder != null) {
        _refreshUpdateState(target.folder!, target, details);
      }

      var plan = ComicDownloadPlanner.plan(details, target.source);
      if (!plan.hasWork) {
        upToDate++;
        context.log(
          '"${plan.title}" is up to date (${plan.totalChapters} chapter(s))',
        );
        continue;
      }

      if (maxChapters > 0) {
        plan = plan.takeMissing(maxChapters);
      }

      if (ComicDownloadPlanner.enqueue(
        plan,
        nasConnectionId: nasConnectionId,
      )) {
        queued++;
        chaptersQueued += plan.missingCount;
        context.log(
          'Queued ${plan.missingCount} new chapter(s) for "${plan.title}"',
        );
      }

      context.reportProgress(
        progress: checked / maxComics,
        message: 'Checked $checked/${targets.length} comics',
      );

      if (throttleMs > 0) {
        await Future.delayed(Duration(milliseconds: throttleMs));
      }
    }

    final remaining = targets.length - checked;
    final parts = <String>['$checked checked', '$upToDate up to date'];
    if (queued > 0) {
      parts.add('$queued comic(s) queued, $chaptersQueued chapter(s)');
    }
    if (failures > 0) {
      parts.add('$failures failed');
    }
    if (remaining > 0) {
      parts.add('$remaining left for the next run');
    }

    return TaskRunOutcome(
      success: true,
      message: parts.join(', '),
      summary: {
        'scope': scope,
        'targets': targets.length,
        'checked': checked,
        'upToDate': upToDate,
        'queued': queued,
        'chaptersQueued': chaptersQueued,
        'failures': failures,
        'remaining': remaining,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  List<_Target> _collectTargets(TaskRunContext context, String scope) {
    if (scope == scopeLibrary) {
      return _collectLibraryTargets();
    }
    return _collectFavoriteTargets(context);
  }

  List<_Target> _collectLibraryTargets() {
    final result = <_Target>[];
    List<LocalComic> comics;
    try {
      comics = LocalManager().getComics(LocalSortType.timeDesc);
    } catch (e, s) {
      Log.error('Download', 'Failed to list the local library: $e', s);
      return result;
    }
    for (final comic in comics) {
      final source = comic.comicType.comicSource;
      if (source == null || source.loadComicInfo == null) {
        continue;
      }
      result.add(_Target(source: source, comicId: comic.id, name: comic.title));
    }
    return result;
  }

  List<_Target> _collectFavoriteTargets(TaskRunContext context) {
    final result = <_Target>[];
    final folder = context.configValue('favoriteFolder', '').trim();
    if (folder.isEmpty) {
      return result;
    }
    final manager = LocalFavoritesManager();
    if (!manager.existsFolder(folder)) {
      context.log('Favourites folder "$folder" does not exist');
      return result;
    }
    // Ensure the update-tracking columns exist before reading them.
    manager.prepareTableForFollowUpdates(folder, false);

    List<FavoriteItemWithUpdateInfo> items;
    try {
      items = manager.getComicsWithUpdatesInfo(folder);
    } catch (e, s) {
      Log.error(
        'Download',
        'Failed to read favourites folder "$folder": $e',
        s,
      );
      return result;
    }
    for (final item in items) {
      final source = item.type.comicSource;
      if (source == null || source.loadComicInfo == null) {
        continue;
      }
      result.add(
        _Target(
          source: source,
          comicId: item.id,
          name: item.name,
          folder: folder,
          type: item.type,
        ),
      );
    }
    return result;
  }

  /// Mirrors the bookkeeping in `updateComic` (`follow_updates.dart:51-62`) so
  /// the favourites badge reflects what this run actually saw.
  void _refreshUpdateState(
    String folder,
    _Target target,
    ComicDetails details,
  ) {
    final type = target.type;
    if (type == null) {
      return;
    }
    try {
      final manager = LocalFavoritesManager();
      final updateTime = details.findUpdateTime();
      if (updateTime != null) {
        manager.updateUpdateTime(folder, target.comicId, type, updateTime);
      } else {
        manager.updateCheckTime(folder, target.comicId, type);
      }
    } catch (e, s) {
      Log.error('Download', 'Failed to update check state: $e', s);
    }
  }
}

/// A comic this runner should inspect.
class _Target {
  const _Target({
    required this.source,
    required this.comicId,
    required this.name,
    this.folder,
    this.type,
  });

  final ComicSource source;
  final String comicId;
  final String name;

  /// Set when the target came from a favourites folder.
  final String? folder;

  /// Set when the target came from a favourites folder.
  final ComicType? type;
}

import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/favorites.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/scheduler/store.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/comic_download_planner.dart';

/// Scans comic sources' ranking lists and reports comics that were not listed
/// before.
///
/// A comic is "new" the first time its `(source, comic id)` pair is observed.
/// That is stricter than comparing ranking positions, and much more robust:
/// rankings reshuffle constantly, but re-listing an existing title is not news.
/// Observed ids are remembered in the `seen_items` table, so the detection
/// survives restarts, and entries that have not been seen for
/// [`forgetAfterDays`] are pruned so a title that leaves and later returns is
/// reported again.
///
/// Ranking support detection deliberately does not trust
/// `CategoryData.enableRankingPage`. The UI gates on that flag alone and then
/// null-asserts `categoryComicsData!.rankingData!` (`ranking_page.dart:24-25`),
/// which throws for sources that set the flag without providing a loader. This
/// checks the loader itself instead.
class RankingMonitorRunner extends SchedulableRunner {
  static const String key = 'rankingMonitor';

  /// Configuration key for the per-source ranking selection.
  ///
  /// The value is a map from a comic-source key to a list of ranking option
  /// keys. An empty map keeps the legacy `options` configuration active.
  static const String optionsBySourceConfigKey = 'optionsBySource';

  @override
  String get typeKey => key;

  @override
  String get displayName => 'Ranking monitor';

  @override
  String get description =>
      'Scan comic sources\' ranking lists and report newly listed comics';

  @override
  Map<String, dynamic> defaultConfig() => <String, dynamic>{
    /// Source keys to scan. Empty means every ranking-capable source.
    'sources': <String>[],

    /// Legacy ranking option keys. Empty means the first option of each
    /// source. New tasks use [optionsBySourceConfigKey] so sources can select
    /// different ranking families.
    'options': <String>[],

    /// Ranking option keys grouped by source. An empty list for a source means
    /// that source's first option, matching the legacy behaviour.
    optionsBySourceConfigKey: <String, List<String>>{},

    /// How many pages to read per option.
    'pagesPerOption': 1,

    /// Upper bound on how many new comics get the expensive per-comic
    /// follow-up work (detail fetch, favourite, download) in one run.
    'maxNewPerRun': 50,

    /// Delay between network requests, in milliseconds.
    'throttleMs': 300,

    /// Add genuinely new entries to a local favourites folder.
    'autoFavorite': false,
    'favoriteFolder': '',

    /// Queue downloads for new entries, fetching only missing chapters.
    'autoDownload': false,
    'nasConnectionId': null,

    /// Forget an id that has not been seen for this many days. 0 disables
    /// pruning.
    'forgetAfterDays': 90,
  };

  @override
  String? validateConfig(Map<String, dynamic> config) {
    final pages = config['pagesPerOption'];
    if (pages is num && (pages < 1 || pages > 20)) {
      return 'Pages per option must be between 1 and 20';
    }
    final maxNew = config['maxNewPerRun'];
    if (maxNew is num && maxNew < 1) {
      return 'Maximum new comics per run must be at least 1';
    }
    final throttle = config['throttleMs'];
    if (throttle is num && throttle < 0) {
      return 'Throttle must not be negative';
    }
    if (config['autoFavorite'] == true) {
      final folder = config['favoriteFolder'];
      if (folder is! String || folder.trim().isEmpty) {
        return 'A favourites folder is required when auto-favourite is on';
      }
    }
    final optionsBySource = config[optionsBySourceConfigKey];
    if (optionsBySource != null) {
      if (optionsBySource is! Map) {
        return 'Ranking options by source must be a map';
      }
      for (final entry in optionsBySource.entries) {
        if (entry.key is! String || entry.value is! List) {
          return 'Each source ranking selection must be a list';
        }
        if ((entry.value as List).any((value) => value is! String)) {
          return 'Ranking option keys must be strings';
        }
      }
    }
    return null;
  }

  /// Every installed source that can actually serve a ranking list.
  static List<ComicSource> rankingCapableSources() {
    final result = <ComicSource>[];
    for (final source in ComicSource.all()) {
      if (supportsRanking(source)) {
        result.add(source);
      }
    }
    return result;
  }

  /// Whether [source] exposes a usable ranking list.
  static bool supportsRanking(ComicSource source) {
    if (source.categoryData == null) {
      return false;
    }
    final ranking = source.categoryComicsData?.rankingData;
    if (ranking == null || ranking.options.isEmpty) {
      return false;
    }
    return ranking.load != null || ranking.loadWithNext != null;
  }

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    final sources = _resolveSources(context);
    if (sources.isEmpty) {
      return const TaskRunOutcome.skipped(
        'No installed comic source exposes a ranking list',
      );
    }

    // Source init hooks can refresh API domains over the network. At app
    // startup they may still be running when a run-on-start task becomes due;
    // invoking a loader before they finish leaves source globals undefined.
    // Manual runs appeared to work only because enough time had elapsed.
    try {
      await Future.wait(sources.map((source) => source.ensureInitialized()));
    } catch (e, s) {
      Log.error('Ranking', 'Comic source initialization failed: $e', s);
      return TaskRunOutcome(
        success: false,
        error: 'Comic source initialization failed: $e',
        requestRetry: true,
      );
    }

    final pagesPerOption = context
        .configValue('pagesPerOption', 1)
        .clamp(1, 20);
    final throttleMs = context.configValue('throttleMs', 300).clamp(0, 10000);
    final forgetAfterDays = context.configValue('forgetAfterDays', 90);
    final maxNew = context.configValue('maxNewPerRun', 50).clamp(1, 10000);

    var optionsScanned = 0;
    var failedOptions = 0;
    var comicsSeen = 0;
    final discovered = <_DiscoveredComic>[];
    // A comic can be listed by more than one option (and by more than one page),
    // so de-duplicate within the run as well as against the store.
    final discoveredIds = <String>{};

    for (var index = 0; index < sources.length; index++) {
      context.throwIfCancelled();
      final source = sources[index];
      final ranking = source.categoryComicsData!.rankingData!;
      final options = _resolveOptions(context, ranking, source.key);
      final namespace = seenNamespace(source.key);

      // Ranked lists go stale slowly; forget ids that have vanished so a title
      // that leaves and later returns counts as new again.
      if (forgetAfterDays > 0 && SchedulerStore().isOpen) {
        SchedulerStore().pruneSeenBefore(
          namespace,
          DateTime.now().subtract(Duration(days: forgetAfterDays)),
        );
      }

      for (final option in options) {
        context.throwIfCancelled();
        optionsScanned++;
        final scan = await scanOption(
          ranking,
          option,
          pagesPerOption,
          logLabel: '${source.key}/$option',
        );
        if (scan.error != null) {
          failedOptions++;
          context.log('${source.name} / $option failed: ${scan.error}');
          continue;
        }

        for (final comic in scan.comics) {
          comicsSeen++;
          if (!discoveredIds.add('${source.key}\u0000${comic.id}')) {
            continue;
          }
          // Read-only on purpose. Recording a comic as seen is a promise that
          // it will never be offered again, so it may only be written once the
          // comic's download is actually settled -- see _remember. Doing it
          // here, at detection time, silently consumed comics that were never
          // downloaded: everything the maxNewPerRun limit skipped, everything
          // whose details failed to load, and the entire list whenever
          // auto-download was off.
          final alreadySeen = SchedulerStore().isOpen
              ? SchedulerStore().isSeen(namespace, comic.id)
              : false;
          if (!alreadySeen) {
            discovered.add(_DiscoveredComic(source, comic, option));
          }
        }
        context.log(
          '${source.name} / $option: ${scan.comics.length} listed, '
          '${discovered.length} new so far',
        );

        if (throttleMs > 0) {
          await Future.delayed(Duration(milliseconds: throttleMs));
        }
      }

      context.reportProgress(
        progress: (index + 1) / sources.length,
        message: 'Scanned ${index + 1}/${sources.length} sources',
      );
    }

    if (optionsScanned > 0 && failedOptions == optionsScanned) {
      return TaskRunOutcome.failed(
        'All $optionsScanned ranking request(s) failed',
        summary: {
          'sourcesScanned': sources.length,
          'optionsScanned': optionsScanned,
          'failedOptions': failedOptions,
        },
      );
    }

    final followUp = await _applyFollowUpActions(
      context,
      discovered,
      maxNew: maxNew,
      throttleMs: throttleMs,
    );

    // Everything not remembered is still owed a download, whether it was never
    // examined because maxNewPerRun ran out, read back as unreadable, or could
    // not be queued. This is what makes "left for the next run" true.
    final leftForNextRun = discovered.length - followUp.remembered;
    final summary = <String, dynamic>{
      'sourcesScanned': sources.length,
      'optionsScanned': optionsScanned,
      'failedOptions': failedOptions,
      'comicsListed': comicsSeen,
      'newComics': discovered.length,
      'processed': followUp.processed,
      'favorited': followUp.favorited,
      'queuedForDownload': followUp.queued,
      'upToDate': followUp.upToDate,
      'remembered': followUp.remembered,
      'leftForNextRun': leftForNextRun,
      'detailFailures': followUp.detailFailures,
    };

    final parts = <String>[
      '$comicsSeen listed across $optionsScanned option(s)',
      '${discovered.length} new',
    ];
    if (followUp.processed > 0) {
      parts.add('${followUp.processed} processed');
    }
    if (followUp.queued > 0) {
      parts.add('${followUp.queued} queued');
    }
    if (followUp.upToDate > 0) {
      parts.add('${followUp.upToDate} already complete');
    }
    if (followUp.favorited > 0) {
      parts.add('${followUp.favorited} favorited');
    }
    if (followUp.detailFailures > 0) {
      parts.add('${followUp.detailFailures} unreadable');
    }
    if (failedOptions > 0) {
      parts.add('$failedOptions option(s) failed');
    }
    if (leftForNextRun > 0) {
      parts.add('$leftForNextRun left for the next run');
    }

    return TaskRunOutcome(
      success: true,
      message: parts.join(', '),
      summary: summary,
    );
  }

  /// Namespace used to remember ids seen for [sourceKey].
  static String seenNamespace(String sourceKey) => 'ranking:$sourceKey';

  /// Reads the new per-source ranking selection from a persisted config.
  ///
  /// A defensive copy is returned because task configs come from JSON and may
  /// contain `Map<dynamic, dynamic>` and `List<dynamic>` values.
  static Map<String, List<String>> configuredOptionsBySource(
    Map<String, dynamic> config,
  ) {
    final raw = config[optionsBySourceConfigKey];
    if (raw is! Map) {
      return <String, List<String>>{};
    }
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      final sourceKey = entry.key;
      final values = entry.value;
      if (sourceKey is String && values is List) {
        result[sourceKey] = values.whereType<String>().toList();
      }
    }
    return result;
  }

  /// Resolves ranking option keys for one source from a task config.
  ///
  /// When any per-source selection is present it takes precedence over the
  /// old global `options` list. This makes a newly edited task deterministic:
  /// selecting one source's option does not accidentally apply a legacy option
  /// key to every other source. Empty or unknown selections fall back to the
  /// source's first option, as older tasks did.
  static List<String> resolveOptionsForConfig({
    required Map<String, dynamic> config,
    required RankingData ranking,
    required String sourceKey,
  }) {
    if (ranking.options.isEmpty) {
      return const <String>[];
    }
    final bySource = configuredOptionsBySource(config);
    final wanted = bySource.isNotEmpty
        ? (bySource[sourceKey] ?? const <String>[])
        : config['options'] is List
        ? (config['options'] as List).whereType<String>().toList()
        : const <String>[];
    final known = <String>[];
    final seen = <String>{};
    for (final option in wanted) {
      if (ranking.options.containsKey(option) && seen.add(option)) {
        known.add(option);
      }
    }
    return known.isEmpty ? <String>[ranking.options.keys.first] : known;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  List<ComicSource> _resolveSources(TaskRunContext context) {
    final wanted = context.configStringList('sources');
    final all = rankingCapableSources();
    if (wanted.isEmpty) {
      return all;
    }
    final selected = all.where((s) => wanted.contains(s.key)).toList();
    if (selected.isEmpty) {
      context.log(
        'None of the configured sources expose a ranking list; '
        'checked ${all.length} source(s)',
      );
    }
    return selected;
  }

  List<String> _resolveOptions(
    TaskRunContext context,
    RankingData ranking,
    String sourceKey,
  ) {
    final options = resolveOptionsForConfig(
      config: context.task.config,
      ranking: ranking,
      sourceKey: sourceKey,
    );
    final bySource = configuredOptionsBySource(context.task.config);
    final configured = bySource.isNotEmpty
        ? bySource[sourceKey]
        : context.configStringList('options');
    final hasInvalidSelection =
        configured != null &&
        configured.isNotEmpty &&
        !configured.any(ranking.options.containsKey);
    if (hasInvalidSelection) {
      context.log(
        'None of the configured ranking options exist for $sourceKey; '
        'falling back to "${ranking.options.keys.first}"',
      );
    }
    return options;
  }

  /// Reads up to [pages] pages of one ranking option.
  ///
  /// Static and loader-injected, so the paging rules can be unit-tested with
  /// fakes. The two shapes differ, and both were established by reading
  /// `ComicList`:
  ///
  /// * `ranking.load` is **1-based** (`ComicList` holds `int _page = 1` and
  ///   calls `loadPage(1)` first) and reports the last page through
  ///   `Res.subData` as an `int`.
  /// * `ranking.loadWithNext` starts with a **null** cursor and reports the next
  ///   cursor through `Res.subData` as a `String`. A null or non-String
  ///   `subData` means there is no next page.
  ///
  /// A failure mid-way returns the pages already read alongside the error, so a
  /// partial scan still contributes detections.
  static Future<RankingOptionScan> scanOption(
    RankingData ranking,
    String option,
    int pages, {
    String logLabel = '',
  }) async {
    final comics = <Comic>[];
    var pagesRead = 0;
    try {
      final load = ranking.load;
      if (load != null) {
        for (var page = 1; page <= pages; page++) {
          final res = await load(option, page);
          pagesRead++;
          if (res.error) {
            return RankingOptionScan(
              comics,
              res.errorMessage ?? 'unknown error on page $page',
              pagesRead: pagesRead,
            );
          }
          final batch = res.dataOrNull ?? const <Comic>[];
          comics.addAll(batch);
          if (batch.isEmpty) {
            break;
          }
          final maxPage = res.subData;
          if (maxPage is int && page >= maxPage) {
            break;
          }
        }
      } else {
        final loadNext = ranking.loadWithNext!;
        String? cursor;
        for (var page = 0; page < pages; page++) {
          final res = await loadNext(option, cursor);
          pagesRead++;
          if (res.error) {
            return RankingOptionScan(
              comics,
              res.errorMessage ?? 'unknown error on page ${page + 1}',
              pagesRead: pagesRead,
            );
          }
          final batch = res.dataOrNull ?? const <Comic>[];
          comics.addAll(batch);
          final next = res.subData;
          cursor = next is String && next.isNotEmpty ? next : null;
          if (cursor == null || batch.isEmpty) {
            break;
          }
        }
      }
      return RankingOptionScan(comics, null, pagesRead: pagesRead);
    } catch (e, s) {
      Log.error('Ranking', 'Failed to scan $logLabel: $e', s);
      return RankingOptionScan(comics, e.toString(), pagesRead: pagesRead);
    }
  }

  Future<_FollowUpResult> _applyFollowUpActions(
    TaskRunContext context,
    List<_DiscoveredComic> discovered, {
    required int maxNew,
    required int throttleMs,
  }) async {
    final autoFavorite = context.configValue('autoFavorite', false);
    final autoDownload = context.configValue('autoDownload', false);
    final folder = context.configValue('favoriteFolder', '').trim();

    if (discovered.isEmpty || (!autoFavorite && !autoDownload)) {
      // Nothing was consumed, so nothing is remembered and nothing counts as
      // processed: the next run reports the same comics as new. That is the
      // point -- enabling auto-download later has to still work.
      return const _FollowUpResult(processed: 0);
    }

    var processed = 0;
    var favorited = 0;
    var queued = 0;
    var upToDate = 0;
    var remembered = 0;
    var detailFailures = 0;

    for (final item in discovered) {
      if (processed >= maxNew) {
        break;
      }
      context.throwIfCancelled();
      processed++;

      final details = await ComicDownloadPlanner.loadDetails(
        item.source,
        item.comic.id,
      );
      if (details == null) {
        // Not remembered: an unreadable comic has to be retried, and doing
        // that is what stops the whole feature from silently missing titles.
        detailFailures++;
        continue;
      }

      if (autoFavorite && folder.isNotEmpty) {
        if (_addToFavorites(folder, details, item.source)) {
          favorited++;
        }
      }

      if (autoDownload) {
        final action = _handOffDownload(
          ComicDownloadPlanner.plan(details, item.source),
          nasConnectionId: context.task.config['nasConnectionId'] as String?,
        );
        switch (action) {
          case DownloadFollowUp.alreadyComplete:
            upToDate++;
          case DownloadFollowUp.queued:
            queued++;
          case DownloadFollowUp.alreadyQueued:
          case DownloadFollowUp.failed:
            break;
        }
        // A failed hand-off stays unremembered on purpose, so the next run
        // retries it rather than losing the comic for good.
        if (action.isSettled && _remember(item)) {
          remembered++;
        }
      } else {
        // auto-download is off, so this comic has not been downloaded and
        // therefore is not remembered. Only favouriting ran, and that is
        // idempotent, so repeating it next run costs nothing. This is what lets
        // the toggle be switched on later without the ranking having been lost.
      }

      context.reportProgress(
        progress: processed / maxNew,
        message: 'Processing ${item.comic.title}',
      );

      if (throttleMs > 0) {
        await Future.delayed(Duration(milliseconds: throttleMs));
      }
    }

    return _FollowUpResult(
      processed: processed,
      favorited: favorited,
      queued: queued,
      upToDate: upToDate,
      remembered: remembered,
      detailFailures: detailFailures,
    );
  }

  /// Hands one comic's missing chapters to the download queue.
  ///
  /// A comic that is already in the queue counts as settled too: the queue is
  /// persisted in `downloading_tasks.json` and resumed on start, so the
  /// download is owed either way, and queueing it twice would be rejected.
  DownloadFollowUp _handOffDownload(
    DownloadPlan plan, {
    String? nasConnectionId,
  }) {
    if (!plan.hasWork) {
      return DownloadFollowUp.alreadyComplete;
    }
    if (ComicDownloadPlanner.enqueue(plan, nasConnectionId: nasConnectionId)) {
      return DownloadFollowUp.queued;
    }
    return ComicDownloadPlanner.isQueued(plan)
        ? DownloadFollowUp.alreadyQueued
        : DownloadFollowUp.failed;
  }

  /// Records that [item] has been dealt with, so it is not offered again.
  ///
  /// Only ever called once the comic's download is settled: its chapters are on
  /// disk already, or they have been handed to the persistent download queue.
  /// Returns whether the record was written.
  bool _remember(_DiscoveredComic item) {
    if (!SchedulerStore().isOpen) {
      return false;
    }
    SchedulerStore().markSeen(
      seenNamespace(item.source.key),
      item.comic.id,
      payload: '${item.option}\u0000${item.comic.title}',
    );
    return true;
  }

  bool _addToFavorites(
    String folder,
    ComicDetails details,
    ComicSource source,
  ) {
    try {
      final manager = LocalFavoritesManager();
      if (!manager.existsFolder(folder)) {
        manager.createFolder(folder);
      }
      // Enable update tracking without clearing existing flags.
      manager.prepareTableForFollowUpdates(folder, false);

      final tags = <String>[];
      for (final entry in details.tags.entries) {
        tags.addAll(entry.value.map((value) => '${entry.key}:$value'));
      }

      return manager.addComic(
        folder,
        FavoriteItem(
          id: details.comicId,
          name: details.title,
          coverPath: details.cover,
          author: details.subTitle ?? details.uploader ?? '',
          type: ComicType(source.key.hashCode),
          tags: tags,
        ),
        null,
        details.findUpdateTime(),
      );
    } catch (e, s) {
      Log.error('Ranking', 'Failed to favourite ${details.comicId}: $e', s);
      return false;
    }
  }
}

/// A comic seen for the first time, together with where it was found.
class _DiscoveredComic {
  const _DiscoveredComic(this.source, this.comic, this.option);

  final ComicSource source;
  final Comic comic;
  final String option;
}

/// Result of reading one ranking option.
class RankingOptionScan {
  const RankingOptionScan(this.comics, this.error, {this.pagesRead = 0});

  /// Comics gathered, in the order the source returned them.
  final List<Comic> comics;

  /// Null on success; otherwise the first failure encountered.
  final String? error;

  /// How many loader calls were made.
  final int pagesRead;

  bool get failed => error != null;

  @override
  String toString() =>
      'RankingOptionScan(${comics.length} comics, $pagesRead page(s)'
      '${error == null ? '' : ', error: $error'})';
}

/// Counters from the follow-up phase.
class _FollowUpResult {
  const _FollowUpResult({
    required this.processed,
    this.favorited = 0,
    this.queued = 0,
    this.upToDate = 0,
    this.remembered = 0,
    this.detailFailures = 0,
  });

  /// Comics examined this run, capped by `maxNewPerRun`.
  final int processed;

  final int favorited;

  /// Comics whose missing chapters were queued this run.
  final int queued;

  /// Comics that needed nothing, because every chapter is already on disk.
  final int upToDate;

  /// Comics now recorded as dealt with, i.e. that will not be offered again.
  /// Always a subset of [processed]: anything that failed is left out so the
  /// next run retries it.
  final int remembered;

  final int detailFailures;
}

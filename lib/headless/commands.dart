import 'dart:async';
import 'dart:convert';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/favorites.dart';
import 'package:venera_netmatic/foundation/follow_updates.dart';
import 'package:venera_netmatic/foundation/history.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/nas/nas_connection.dart';
import 'package:venera_netmatic/foundation/nas/nas_library.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/comic_download_planner.dart';
import 'package:venera_netmatic/network/download.dart';
import 'package:venera_netmatic/pages/comic_source_page.dart';
import 'package:venera_netmatic/utils/data_sync.dart';
import 'cli.dart';
import 'download_queue.dart';
import 'jobs.dart';
import 'credentials.dart';
import 'source_auth.dart';

class HeadlessCommands {
  HeadlessCommands(
    this.request,
    this.control,
    this.jobs,
    this.report, {
    this.managedScheduler = false,
  });
  final bool managedScheduler;
  final CliRequest request;
  final CliControl control;
  final CliJobs jobs;
  final void Function(Map<String, dynamic>) report;
  LocalManager get local => LocalManager();
  SchedulerEngine get engine => SchedulerEngine();
  List<String> get args => request.arguments;
  late final queue = CliDownloadQueue(
    tasks: () => local.downloadingTasks,
    flush: local.flushDownloadingTasks,
    jobs: jobs,
    control: control,
    report: report,
  );

  Future<T> network<T>(Future<T> future) => control.wait(
    future,
    timeout: Duration(
      seconds: request.integer('timeout', 60, min: 1, max: 86400),
    ),
  );

  T checked<T>(Res<T> result) {
    if (result.error) {
      final message = result.errorMessage!;
      if (message.contains('authentication_required') ||
          message.contains('Not logged in')) {
        throw const CliException(
          'authentication_required',
          'Log in or reauthenticate this source before retrying.',
        );
      }
      if (message.contains('authentication_failed')) {
        throw const CliException(
          'authentication_failed',
          'Source login failed. Submit new credentials.',
        );
      }
      if (message.contains('auth_network_error')) {
        throw const CliException(
          'network_error',
          'The source could not be reached.',
        );
      }
      if (message.contains('auth_rate_limited')) {
        throw const CliException(
          'auth_rate_limited',
          'Login rate limited. Wait before retrying.',
        );
      }
      if (message.contains('interaction_required')) {
        throw const CliException(
          'interaction_required',
          'Complete the required interaction in the GUI.',
        );
      }
      throw CliException('source_error', message);
    }
    return result.data;
  }

  Future<ComicSource> source(String key) async {
    final source = ComicSource.find(key);
    if (source == null) {
      throw CliException('not_found', 'Comic source not found: $key');
    }
    try {
      await network(source.ensureInitialized());
    } catch (error) {
      if (error.toString().contains('source_cleanup_failed')) {
        throw const CliException(
          'source_cleanup_failed',
          'Source cleanup failed. Restart the worker before retrying.',
        );
      }
      rethrow;
    }
    control.check();
    return source;
  }

  Future<ComicDetails> details(String sourceKey, String id) async {
    final s = await source(sourceKey);
    if (s.loadComicInfo == null) {
      throw const CliException(
        'unsupported',
        'This source cannot load comic details.',
      );
    }
    return checked(await network(s.loadComicInfo!(id)));
  }

  NasConnection connection(String id) {
    final result = NasManager.instance.find(id);
    if (result == null) {
      throw const CliException('not_found', 'NAS connection not found.');
    }
    return result;
  }

  Map<String, dynamic> page(Iterable<Map<String, dynamic>> values) {
    final query = request.options['query']?.toLowerCase() ?? '';
    final filtered = values
        .where(
          (v) =>
              query.isEmpty ||
              '${v['title'] ?? v['name'] ?? v['label'] ?? ''} ${v['tags'] ?? ''}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    final offset = request.integer('offset', 0);
    final limit = request.integer('limit', 50, min: 1, max: 1000);
    return {
      'total': filtered.length,
      'offset': offset,
      'limit': limit,
      'items': filtered.skip(offset).take(limit).toList(),
      'nextOffset': offset + limit < filtered.length ? offset + limit : null,
    };
  }

  Map<String, dynamic> queueItem(DownloadTask t) => {
    'sourceKey': t.comicType.sourceKey,
    'comicId': t.id,
    'title': t.title,
    'state': t.isError
        ? 'failed'
        : t.isPaused
        ? 'queued'
        : 'running',
    'progress': t.progress,
    'jobId': jobs.pendingDownload(t.comicType.sourceKey, t.id),
  };

  Map<String, dynamic> jumpTarget(PageJumpTarget target) => {
    'sourceKey': target.sourceKey,
    'action': target.page,
    'supported': ['search', 'category'].contains(target.page),
    if (target.page == 'search')
      'query':
          target.attributes?['text'] ?? target.attributes?['keyword'] ?? '',
    if (target.page == 'category') ...{
      'category': target.attributes?['category'],
      'param': target.attributes?['param'],
    },
    if (target.attributes?['options'] != null)
      'options': target.attributes!['options'],
  };

  Future<List<CategoryComicsOptions>> categoryOptions(
    CategoryComicsData data,
  ) async {
    final options = data.optionsLoader == null
        ? data.options ?? const <CategoryComicsOptions>[]
        : checked(
            await network(
              data.optionsLoader!(args[1], request.options['param']),
            ),
          );
    control.check();
    return options
        .where(
          (option) =>
              !option.notShowWhen.contains(args[1]) &&
              (option.showWhen == null || option.showWhen!.contains(args[1])),
        )
        .toList();
  }

  Future<CliResult> execute() async {
    control.check();
    switch (request.command) {
      case 'help':
        return CliResult({
          'globalOptions': ['--timeout SECONDS', '--queue-timeout SECONDS'],
          'commands': CliRequest.specs.entries
              .where(
                (e) => !['service serve', 'scheduler serve'].contains(e.key),
              )
              .map(
                (e) => {
                  'command': e.key,
                  'minArguments': e.value.$1,
                  'maxArguments': e.value.$2,
                  'options': e.value.$3.toList(),
                },
              )
              .toList(),
        });
      case 'sources list':
        return CliResult({
          'loadErrors': ComicSourceManager().loadErrors,
          'sources': ComicSource.all()
              .map(
                (s) => {
                  'key': s.key,
                  'name': s.name,
                  'version': s.version,
                  'loggedIn': s.isLogged,
                  'account': SourceAuth.describe(s),
                  'capabilities': {
                    'search': s.searchPageData != null,
                    'details': s.loadComicInfo != null,
                    'pages': s.loadComicPages != null,
                    'ranking': s.categoryComicsData?.rankingData != null,
                    'categories': s.categoryData != null,
                    'categoryComics': s.categoryComicsData != null,
                    'tagTargets': s.handleClickTagEvent != null,
                  },
                  'searchOptions':
                      s.searchPageData?.searchOptions
                          ?.map(
                            (o) => {
                              'label': o.label,
                              'type': o.type,
                              'values': o.options,
                              'default': o.defaultValue,
                            },
                          )
                          .toList() ??
                      [],
                },
              )
              .toList(),
        });
      case 'sources status':
        final s = ComicSource.find(args[0]);
        if (s == null) {
          throw const CliException('not_found', 'Comic source not found.');
        }
        return CliResult(SourceAuth.describe(s));
      case 'sources login':
        try {
          final s = await source(args[0]);
          final credentials =
              request.credentials ??
              await SourceCredentials.read(request, control);
          return await SourceAuth(
            s,
            control,
          ).login(credentials, replace: request.options.containsKey('replace'));
        } finally {
          request.credentials = null;
        }
      case 'sources logout':
        return SourceAuth(await source(args[0]), control).logout();
      case 'sources verify':
        return SourceAuth(await source(args[0]), control).verify();
      case 'sources reauth':
        return SourceAuth(await source(args[0]), control).reauthenticate();
      case 'ranking options':
      case 'ranking get':
        final s = await source(args[0]);
        final ranking = s.categoryComicsData?.rankingData;
        if (ranking == null) {
          throw const CliException(
            'unsupported',
            'Source does not provide rankings.',
          );
        }
        if (request.command == 'ranking options') {
          return CliResult({
            'sourceKey': s.key,
            'options': ranking.options,
            'pagination': ranking.load != null ? 'page' : 'cursor',
          });
        }
        if (!ranking.options.containsKey(args[1])) {
          throw const CliException(
            'invalid_arguments',
            'Unknown ranking option. Query ranking options first.',
            exitCode: 2,
          );
        }
        final useCursor =
            request.options.containsKey('cursor') || ranking.load == null;
        Res<List<Comic>> result;
        if (useCursor) {
          if (ranking.loadWithNext == null ||
              request.options.containsKey('page')) {
            throw const CliException(
              'invalid_arguments',
              'Unsupported ranking pagination mode.',
              exitCode: 2,
            );
          }
          result = await network(
            ranking.loadWithNext!(args[1], request.options['cursor']),
          );
        } else {
          result = await network(
            ranking.load!(args[1], request.integer('page', 1, min: 1)),
          );
        }
        return CliResult({
          'sourceKey': s.key,
          'option': args[1],
          'items': checked(result).map((comic) => comic.toJson()).toList(),
          'pagination': useCursor ? 'cursor' : 'page',
          if (useCursor) 'nextCursor': result.subData,
          if (!useCursor) ...{
            'page': request.integer('page', 1),
            'maxPage': result.subData,
          },
        });
      case 'categories list':
        final s = await source(args[0]);
        final categories = s.categoryData;
        if (categories == null) {
          throw const CliException(
            'unsupported',
            'Source does not provide a category catalog.',
          );
        }
        final items = <Map<String, dynamic>>[];
        for (final part in categories.categories) {
          control.check();
          final values = part is RandomCategoryPart
              ? part.all
              : part.categories;
          for (final category in values) {
            items.add({
              'section': part.title,
              'label': category.label,
              'target': jumpTarget(category.target),
            });
          }
        }
        return CliResult({
          'sourceKey': s.key,
          'title': categories.title,
          'categoryKey': categories.key,
          ...page(items),
        });
      case 'categories options':
      case 'categories get':
        final s = await source(args[0]);
        final categories = s.categoryComicsData;
        if (categories == null) {
          throw const CliException(
            'unsupported',
            'Source does not support category browsing.',
          );
        }
        final available = await categoryOptions(categories);
        if (request.command == 'categories options') {
          return CliResult({
            'sourceKey': s.key,
            'category': args[1],
            'param': request.options['param'],
            'options': available
                .map(
                  (option) => {
                    'label': option.label,
                    'values': option.options,
                    'default': option.options.keys.firstOrNull ?? '',
                  },
                )
                .toList(),
          });
        }
        final options =
            request.strings('options') ??
            available
                .map((option) => option.options.keys.firstOrNull ?? '')
                .toList();
        if (options.length != available.length ||
            Iterable.generate(
              options.length,
            ).any((i) => !available[i].options.containsKey(options[i]))) {
          throw const CliException(
            'invalid_arguments',
            'Category options must match categories options output.',
            exitCode: 2,
          );
        }
        final number = request.integer('page', 1, min: 1);
        final result = await network(
          categories.load(args[1], request.options['param'], options, number),
        );
        return CliResult({
          'sourceKey': s.key,
          'category': args[1],
          'param': request.options['param'],
          'items': checked(result).map((comic) => comic.toJson()).toList(),
          'pagination': 'page',
          'page': number,
          'maxPage': result.subData,
        });
      case 'tags resolve':
        final s = await source(args[0]);
        final target = s.handleClickTagEvent?.call(args[1], args[2]);
        if (target == null || !['search', 'category'].contains(target.page)) {
          throw const CliException(
            'unsupported',
            'This tag has no supported headless query target.',
          );
        }
        control.check();
        return CliResult({
          'sourceKey': s.key,
          'namespace': args[1],
          'tag': args[2],
          'target': jumpTarget(target),
        });
      case 'search':
        final s = await source(args[0]);
        final search = s.searchPageData;
        if (search == null) {
          throw const CliException(
            'unsupported',
            'Source does not support search.',
          );
        }
        final options =
            request.strings('options') ??
            search.searchOptions?.map((o) => o.defaultValue).toList() ??
            [];
        if (options.length != (search.searchOptions?.length ?? 0)) {
          throw const CliException(
            'invalid_arguments',
            'Search option count does not match source.',
            exitCode: 2,
          );
        }
        for (var i = 0; i < options.length; i++) {
          final option = search.searchOptions![i];
          if (option.type == 'select' &&
              !option.options.containsKey(options[i])) {
            throw const CliException(
              'invalid_arguments',
              'Invalid search option.',
              exitCode: 2,
            );
          }
        }
        Res<List<Comic>> result;
        String pagination;
        if (request.options.containsKey('cursor') || search.loadPage == null) {
          if (search.loadNext == null || request.options.containsKey('page')) {
            throw const CliException(
              'invalid_arguments',
              'This search requires cursor pagination.',
              exitCode: 2,
            );
          }
          result = await network(
            search.loadNext!(args[1], request.options['cursor'], options),
          );
          pagination = 'cursor';
        } else {
          result = await network(
            search.loadPage!(
              args[1],
              request.integer('page', 1, min: 1),
              options,
            ),
          );
          pagination = 'page';
        }
        return CliResult({
          'sourceKey': s.key,
          'items': checked(result).map((e) => e.toJson()).toList(),
          'pagination': pagination,
          if (pagination == 'page') 'page': request.integer('page', 1),
          if (pagination == 'page') 'maxPage': result.subData,
          if (pagination == 'cursor') 'nextCursor': result.subData,
        });
      case 'comic get':
        return CliResult((await details(args[0], args[1])).toJson());
      case 'comic chapters':
        final comic = await details(args[0], args[1]);
        return CliResult({
          'sourceKey': args[0],
          'comicId': args[1],
          'chapters': comic.chapters?.toJson(),
        });
      case 'library list':
        return CliResult(
          page(
            local
                .getComics(LocalSortType.timeDesc)
                .map(
                  (c) => {
                    ...c.toJson(),
                    'downloadedChapters': c.downloadedChapters,
                  },
                ),
          ),
        );
      case 'favorites list':
        final manager = LocalFavoritesManager();
        final folder = request.options['folder'];
        if (folder == null) return CliResult({'folders': manager.folderNames});
        if (!manager.existsFolder(folder)) {
          throw const CliException('not_found', 'Favorites folder not found.');
        }
        return CliResult(
          page(
            manager
                .getFolderComics(folder)
                .map(
                  (c) => {
                    'id': c.id,
                    'sourceKey': c.sourceKey,
                    'title': c.name,
                    'author': c.author,
                    'tags': c.tags,
                  },
                ),
          ),
        );
      case 'history list':
        return CliResult(
          page(
            HistoryManager().getAll().map(
              (h) => {
                'id': h.id,
                'sourceKey': h.sourceKey,
                'title': h.title,
                'chapter': h.ep,
                'page': h.page,
                'time': h.time.toUtc().toIso8601String(),
              },
            ),
          ),
        );
      case 'jobs list':
        return CliResult({'jobs': jobs.all});
      case 'jobs get':
        final job = jobs.find(args[0]);
        if (job == null) {
          throw const CliException('not_found', 'Job not found.');
        }
        return CliResult(job);
      case 'downloads list':
        return CliResult({
          'tasks': local.downloadingTasks.map(queueItem).toList(),
        });
      case 'downloads add':
        return addDownload();
      case 'downloads run':
        return queue.drain();
      case 'downloads remove':
        final matches = local.downloadingTasks
            .where((t) => t.comicType.sourceKey == args[0] && t.id == args[1])
            .toList();
        if (matches.isEmpty) {
          throw const CliException('not_found', 'Download not found.');
        }
        for (final task in matches) {
          // Removing a stopped queue entry deliberately preserves comic files.
          task.pause();
          await task.settled;
          local.removeTask(task);
          final id = jobs.pendingDownload(args[0], args[1]);
          if (id != null) await jobs.update(id, 'cancelled');
        }
        await local.flushDownloadingTasks();
        return const CliResult(
          null,
          message: 'Removed from queue; downloaded files retained.',
        );
      case 'nas list':
        return CliResult({
          'connections': NasManager.instance.connections
              .map(
                (c) => {
                  'id': c.id,
                  'name': c.name,
                  'protocol': c.protocol.name,
                  'isDefault': c.id == NasManager.instance.defaultConnectionId,
                },
              )
              .toList(),
        });
      case 'nas test':
        await network(NasManager.instance.testConnection(connection(args[0])));
        return const CliResult(null, message: 'NAS connection succeeded.');
      case 'nas library':
        final comics = await network(
          NasLibraryService(connection(args[0])).loadComics(),
        );
        return CliResult(
          page(
            comics.map(
              (c) => {
                'id': c.id,
                'sourceKey': c.resolvedSourceKey,
                'title': c.title,
                'tags': c.tags,
                'chapters': c.chapters?.toJson(),
                'downloadedChapters': c.downloadedChapters,
              },
            ),
          ),
        );
      case 'nas upload':
        connection(args[0]);
        return transferJob('nasUpload', {'connectionId': args[0]}, () async {
          final manager = NasManager.instance;
          void onProgress() {
            final p = manager.progress;
            if (p != null) {
              report({
                'progress': p.fraction,
                'completedBytes': p.completedBytes,
                'totalBytes': p.totalBytes,
                'uploadedFiles': p.uploadedFiles,
              });
            }
          }

          manager.addListener(onProgress);
          try {
            final r = await manager.syncAll(
              args[0],
              checkCancelled: control.check,
            );
            return {
              'uploadedFiles': r.uploadedFiles,
              'skippedFiles': r.skippedFiles,
              'uploadedBytes': r.totalBytes,
            };
          } finally {
            manager.removeListener(onProgress);
          }
        });
      case 'nas download':
        final service = NasLibraryService(connection(args[0]));
        final comics = await network(service.loadComics());
        final matches = comics
            .where((c) => c.resolvedSourceKey == args[1] && c.id == args[2])
            .toList();
        if (matches.length != 1) {
          throw const CliException(
            'not_found',
            'Expected one matching NAS comic.',
          );
        }
        return transferJob(
          'nasDownload',
          {'connectionId': args[0], 'sourceKey': args[1], 'comicId': args[2]},
          () async {
            final c = await service.downloadComic(
              matches.single,
              checkCancelled: control.check,
              onProgress: (done, total, _) =>
                  report({'completedFiles': done, 'totalFiles': total}),
            );
            return c.toJson();
          },
        );
      case 'webdav up':
      case 'webdav down':
        final config = appdata.settings['webdav'];
        if (config is! List ||
            config.length != 3 ||
            config.any((v) => v is! String) ||
            (config.first as String).trim().isEmpty) {
          throw const CliException(
            'not_configured',
            'Configure WebDAV in Venera first.',
          );
        }
        return transferJob(request.command, {}, () async {
          final result = request.command == 'webdav up'
              ? await DataSync().uploadData()
              : await DataSync().downloadData();
          if (result.error) {
            throw CliException('sync_failed', result.errorMessage!);
          }
          return {'synchronized': result.data};
        });
      case 'updatescript all':
        return updateScripts();
      case 'updatesubscribe':
        return updateSubscriptions();
      default:
        if (request.command.startsWith('scheduler ')) return scheduler();
        throw const CliException(
          'invalid_arguments',
          'Unknown command.',
          exitCode: 2,
        );
    }
  }

  Future<CliResult> addDownload() async {
    final s = await source(args[0]);
    if (s.loadComicPages == null) {
      throw const CliException(
        'unsupported',
        'This source does not expose page downloads.',
      );
    }
    final nas = request.options['nas'];
    if (nas != null) connection(nas);
    final comic = await details(s.key, args[1]);
    var plan = ComicDownloadPlanner.plan(comic, s);
    final requested = request.strings('chapters');
    if (requested != null) {
      if (requested.isEmpty ||
          comic.chapters == null ||
          requested.any((c) => !comic.chapters!.ids.contains(c))) {
        throw const CliException(
          'invalid_arguments',
          'Specify existing chapter IDs in a non-empty array.',
          exitCode: 2,
        );
      }
      plan = DownloadPlan(
        source: s,
        details: comic,
        delta: ChapterDelta(
          missingChapters: plan.missingChapters
              .where(requested.contains)
              .toList(),
        ),
      );
    }
    if (!plan.hasWork) {
      return const CliResult(
        null,
        status: 'skipped',
        message: 'Requested chapters are already downloaded.',
      );
    }
    final existing = local.downloadingTasks
        .where((t) => t.id == args[1] && t.comicType.sourceKey == s.key)
        .firstOrNull;
    if (existing != null) {
      // Do not silently discard new chapters or a different NAS destination.
      if (requested != null || nas != null) {
        throw const CliException(
          'already_queued',
          'Comic is already queued. Run or remove that entry before changing its scope.',
        );
      }
    } else if (!ComicDownloadPlanner.enqueue(plan, nasConnectionId: nas)) {
      throw const CliException(
        'enqueue_failed',
        'Could not queue the download.',
      );
    }
    await local.flushDownloadingTasks();
    final task = local.downloadingTasks.firstWhere(
      (t) => t.id == args[1] && t.comicType.sourceKey == s.key,
    );
    final jobId = await queue.jobFor(task);
    if (request.options.containsKey('enqueue-only')) {
      return CliResult(
        {'jobId': jobId, 'task': queueItem(task)},
        status: 'queued',
        message: 'Queue saved. Run downloads run to process it.',
      );
    }
    return queue.drain();
  }

  Future<CliResult> transferJob(
    String kind,
    Map<String, dynamic> refs,
    Future<Object?> Function() work,
  ) async {
    final id = await jobs.create(kind, refs);
    await jobs.update(id, 'running');
    report({'jobId': id, 'state': 'running'});
    try {
      control.check();
      final result = await work();
      control.check();
      await jobs.update(id, 'completed', result: result);
      return CliResult({'jobId': id, 'result': result});
    } catch (_) {
      await jobs.update(
        id,
        control.cancelled || control.timedOut ? 'cancelled' : 'failed',
        error: 'Transfer did not complete.',
      );
      rethrow;
    }
  }

  Future<CliResult> updateScripts() async {
    final count = await network(ComicSourcePage.checkComicSourceUpdate());
    if (count < 0) {
      throw const CliException(
        'source_error',
        'Failed to check script updates.',
      );
    }
    var updated = 0;
    final failed = <String>[];
    for (final key in ComicSourceManager().availableUpdates.keys.toList()) {
      control.check();
      final s = ComicSource.find(key);
      if (s == null) {
        failed.add(key);
        continue;
      }
      try {
        await ComicSourcePage.update(s, false);
        updated++;
      } catch (_) {
        failed.add(key);
      }
      report({'sourceKey': key, 'updated': updated, 'failed': failed.length});
    }
    return CliResult(
      {'updated': updated, 'failedSources': failed},
      status: failed.isEmpty ? 'success' : 'error',
      code: failed.isEmpty ? null : 'partial_failure',
      exitCode: failed.isEmpty ? 0 : 1,
    );
  }

  Future<CliResult> updateSubscriptions() async {
    final folder =
        request.options['folder'] ?? appdata.settings['followUpdatesFolder'];
    final manager = LocalFavoritesManager();
    if (folder is! String || !manager.existsFolder(folder)) {
      throw const CliException(
        'not_configured',
        'Select an existing subscription folder with --folder.',
      );
    }
    manager.prepareTableForFollowUpdates(folder, false);
    final comics = manager
        .getComicsWithUpdatesInfo(folder)
        .where(
          (c) =>
              args.isEmpty || (c.id == args[0] && c.type.sourceKey == args[1]),
        )
        .toList();
    if (args.isNotEmpty && comics.isEmpty) {
      throw const CliException('not_found', 'Subscribed comic not found.');
    }
    var errors = 0;
    var updated = 0;
    for (var i = 0; i < comics.length; i++) {
      control.check();
      final result = await updateComic(comics[i], folder);
      if (result.errorMessage != null) errors++;
      if (result.updated) updated++;
      report({
        'current': i + 1,
        'total': comics.length,
        'updated': updated,
        'errors': errors,
      });
    }
    return CliResult(
      {
        'total': comics.length,
        'updated': updated,
        'errors': errors,
        'comics': jsonDecode(await getUpdatedComicsAsJson(folder)),
      },
      status: errors > 0 ? 'error' : 'success',
      code: errors > 0 ? 'partial_failure' : null,
      exitCode: errors > 0 ? 1 : 0,
    );
  }

  Future<TaskRunOutcome> settleTask(
    TaskDefinition task,
    TaskRunOutcome outcome,
  ) async {
    if (['incrementalDownload', 'rankingMonitor'].contains(task.typeKey)) {
      final downloads = await queue.drain();
      control.check();
      return TaskRunOutcome(
        success: outcome.success && downloads.exitCode == 0,
        skipped: outcome.skipped && (downloads.data as Map)['completed'] == 0,
        message: outcome.message,
        error: downloads.exitCode != 0 ? downloads.message : outcome.error,
        requestRetry: outcome.requestRetry || downloads.exitCode != 0,
        summary: {...?outcome.summary, 'downloads': downloads.data},
      );
    }
    return outcome;
  }

  Future<CliResult> scheduler() async {
    final sub = request.command.substring('scheduler '.length);
    final executing = ['run', 'rundue', 'serve'].contains(sub);
    if (!managedScheduler) {
      await engine.init(
        databasePath: '${App.dataPath}/scheduler.db',
        startTimer: false,
        recoverRuns: executing,
        markRunOnStart: sub == 'serve',
        strict: true,
      );
    }
    try {
      if (sub == 'list') {
        return CliResult({
          'tasks': engine.tasks.map((t) => t.toJson()).toList(),
        });
      }
      if (sub == 'types') {
        return CliResult({
          'types': TaskRunnerRegistry.all()
              .map(
                (r) => {
                  'type': r.typeKey,
                  'name': r.displayName,
                  'description': r.description,
                  'defaultConfig': r.defaultConfig(),
                },
              )
              .toList(),
        });
      }
      if (sub == 'create') {
        final runner = TaskRunnerRegistry.find(args[0]);
        if (runner == null) {
          throw const CliException(
            'invalid_arguments',
            'Unknown task type.',
            exitCode: 2,
          );
        }
        final config = {...runner.defaultConfig(), ...request.object('config')};
        validateConfig(runner, config);
        final schedule = scheduleOption();
        final task = engine.createTask(
          typeKey: runner.typeKey,
          name: request.options['name'] ?? runner.displayName,
          config: config,
          schedule: schedule,
          enabled: !request.options.containsKey('disabled'),
          runOnStart: request.options.containsKey('run-on-start'),
        );
        if (task == null) {
          throw const CliException(
            'invalid_arguments',
            'Invalid task.',
            exitCode: 2,
          );
        }
        return CliResult(task.toJson());
      }
      if (sub == 'rundue') {
        final ids = await engine.runDueBatch(
          maxTasks: request.integer('max-tasks', 100, min: 1),
          deferNas: true,
          checkCancelled: control.check,
          settle: settleTask,
        );
        control.check();
        return runResults(ids);
      }
      if (sub == 'serve') {
        report({'state': 'ready', 'mode': 'scheduler'});
        while (!control.cancelled && !control.timedOut) {
          final ids = await engine.runDueBatch(
            deferNas: true,
            checkCancelled: control.check,
            settle: settleTask,
          );
          if (ids.isNotEmpty) report(runResults(ids).toJson());
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        control.check();
      }
      final task = engine.findTask(args[0]);
      if (task == null) {
        throw const CliException('not_found', 'Scheduled task not found.');
      }
      switch (sub) {
        case 'history':
          return CliResult({
            'runs': engine
                .runsFor(
                  task.id,
                  limit: request.integer('limit', 20, min: 1, max: 1000),
                )
                .map((r) => r.toJson())
                .toList(),
          });
        case 'run':
          await engine.runNow(task.id, settle: settleTask);
          control.check();
          return runResults([task.id]);
        case 'enable':
          engine.setEnabled(task.id, true);
        case 'disable':
          engine.setEnabled(task.id, false);
        case 'delete':
          engine.deleteTask(task.id);
          return const CliResult(null, message: 'Task deleted.');
        case 'update':
          final runner = TaskRunnerRegistry.find(task.typeKey);
          if (runner == null) {
            throw const CliException(
              'unsupported',
              'Task runner is not installed.',
            );
          }
          final config = {...task.config, ...request.object('config')};
          validateConfig(runner, config);
          engine.updateTask(
            task.copyWith(
              name: request.options['name'],
              config: config,
              schedule: request.options.containsKey('schedule')
                  ? scheduleOption()
                  : null,
            ),
          );
      }
      return CliResult(engine.findTask(task.id)?.toJson());
    } finally {
      if (!managedScheduler) engine.close();
    }
  }

  ScheduleSpec scheduleOption() {
    final json = request.object('schedule');
    if (!ScheduleType.values.any((t) => t.name == json['type'])) {
      throw const CliException(
        'invalid_arguments',
        'Provide a valid --schedule JSON object.',
        exitCode: 2,
      );
    }
    final schedule = ScheduleSpec.fromJson(json);
    if (schedule == null || schedule.validationError() != null) {
      throw const CliException(
        'invalid_arguments',
        'Invalid schedule.',
        exitCode: 2,
      );
    }
    return schedule;
  }

  void validateConfig(SchedulableRunner runner, Map<String, dynamic> config) {
    final error = runner.validateConfig(config);
    if (error != null) {
      throw CliException('invalid_arguments', error, exitCode: 2);
    }
    final nas = config['nasConnectionId'];
    if (nas != null) connection(nas as String);
  }

  CliResult runResults(List<String> ids) {
    final tasks = ids.map((id) => engine.findTask(id)!).toList();
    final failed = tasks
        .where(
          (t) => ![
            TaskRunState.success,
            TaskRunState.skipped,
          ].contains(t.lastState),
        )
        .length;
    return CliResult(
      {
        'executed': ids.length,
        'failed': failed,
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'remainingDue': engine.tasks.where((t) => t.isDue).length,
      },
      status: failed > 0 ? 'error' : 'success',
      code: failed > 0 ? 'task_failed' : null,
      exitCode: failed > 0 ? 1 : 0,
    );
  }
}

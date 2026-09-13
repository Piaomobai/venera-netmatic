import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/scheduler/engine.dart';
import 'package:venera/foundation/scheduler/task.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({
          'status': 'running',
          'message': 'Downloading WebDAV data...',
        });
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid webdav command. Use "up" or "down".',
        });
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({
          'status': 'running',
          'message': 'Checking for comic source script updates...',
        });
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                },
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {...data, 'error': e.toString()},
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
        }
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid updatescript command. Use "all".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({
        'status': 'running',
        'message': 'Updating subscribed comics...',
      });
      var folder = appdata.settings["followUpdatesFolder"];
      if (folder == null) {
        cliPrint({
          'status': 'error',
          'message': 'Follow updates folder is not configured.',
        });
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        var comic = comics.firstWhere(
          (c) => c.id == id && c.type.sourceKey == type,
        );

        var result = await updateComic(comic, folder);

        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          },
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({'status': 'running', 'message': message, 'data': data});

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          },
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolder(folder, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({'status': 'running', 'message': message, 'data': data});
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {'total': total, 'updated': updated, 'errors': errors},
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    case 'scheduler':
      await runSchedulerCommand(args, commandIndex);
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}

/// Handles `--headless scheduler <subcommand>`.
///
/// Subcommands:
///   list      print every task as JSON
///   rundue    run every task that is currently due
///   `run <id>`  run one task by id
///
/// No scheduler timer is started here: the process performs the requested work
/// and exits. Results are reported through the same [cliPrint] protocol the
/// other headless commands use. This runs `init()` beforehand, so comic sources
/// are available, but there is no UI, which means `App.rootContext` must never
/// be touched.
Future<void> runSchedulerCommand(List<String> args, int commandIndex) async {
  final subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;
  final engine = SchedulerEngine();

  // init() has already run, so App.dataPath is set.
  await engine.init(
    databasePath: '${App.dataPath}/scheduler.db',
    startTimer: false,
  );

  switch (subCommand) {
    case 'list':
      cliPrint({
        'status': 'success',
        'message': 'Scheduled tasks.',
        'data': {
          'total': engine.tasks.length,
          'enabled': engine.enabledCount,
          'tasks': engine.tasks.map((task) => task.toJson()).toList(),
        },
      });
      break;
    case 'rundue':
      await engine.runDueTasks();
      cliPrint({
        'status': 'success',
        'message': 'Due tasks executed.',
        'data': {'tasks': engine.tasks.map((task) => task.toJson()).toList()},
      });
      break;
    case 'run':
      final id = (commandIndex + 2 < args.length)
          ? args[commandIndex + 2]
          : null;
      if (id == null) {
        cliPrint({
          'status': 'error',
          'message':
              'Missing task id. '
              'Usage: --headless scheduler run <id>',
        });
        exit(1);
      }
      final task = engine.findTask(id);
      if (task == null) {
        cliPrint({'status': 'error', 'message': 'Task not found: $id'});
        exit(1);
      }
      await engine.runNow(id);
      final after = engine.findTask(id);
      final runs = engine.runsFor(id, limit: 1);
      final succeeded = after?.lastState == TaskRunState.success;
      cliPrint({
        'status': succeeded ? 'success' : 'error',
        'message': succeeded ? 'Task finished.' : 'Task failed.',
        'data': {
          if (after != null) 'task': after.toJson(),
          if (runs.isNotEmpty) 'run': runs.first.toJson(),
          'log': engine.logFor(id).reversed.take(20).toList(),
        },
      });
      break;
    default:
      cliPrint({
        'status': 'error',
        'message':
            'Invalid scheduler command: ${subCommand ?? '(none)'}. '
            'Use "list", "rundue" or "run <id>".',
      });
      exit(1);
  }

  engine.close();
}

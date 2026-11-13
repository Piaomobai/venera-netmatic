import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:dio/dio.dart' show CancelToken;
import 'package:venera_netmatic/foundation/async_control.dart';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';
import 'package:venera_netmatic/foundation/comic_type.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/nas/nas_library.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/res.dart';
import 'package:venera_netmatic/network/images.dart';
import 'package:venera_netmatic/utils/ext.dart';
import 'package:venera_netmatic/utils/file_type.dart';
import 'package:venera_netmatic/utils/io.dart';
import 'package:path/path.dart' as path_util;

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// Completes only after all writes and optional NAS finalization settle.
  Future<void> get settled => Future<void>.value();

  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  Future<void>? _activeRun;
  @override
  Future<void> get settled => _activeRun ?? Future<void>.value();
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    this.nasConnectionId,
  });

  final String? nasConnectionId;

  @override
  void cancel() {
    _isRunning = false;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          } catch (e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _coverCancellation?.cancel();
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;
  CancelToken? _coverCancellation;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};
  final Set<_ImageDownloadWrapper> _inFlightImages = {};

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  void _scheduleTasks() {
    if (!_isRunning || _chapter >= _images!.length) return;
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(
          FilePath.join(
            path!,
            LocalManager.getChapterDirectoryName(
              _images!.keys.elementAt(_chapter),
            ),
          ),
        );
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      _inFlightImages.add(task);
      task.wait().then((task) {
        _inFlightImages.remove(task);
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  @override
  void resume() {
    if (_activeRun != null || _isRunning) return;
    _activeRun = _resume()
        .catchError((Object error, StackTrace stack) {
          Log.error('Download', error, stack);
          _setError('Error: $error');
        })
        .whenComplete(() async {
          final pending = _inFlightImages.toList();
          for (final image in pending) {
            image.cancel();
          }
          await Future.wait(pending.map((image) => image.wait()));
          _activeRun = null;
        });
  }

  Future<Res<T>> _runWithRetry<T>(
    Future<T> Function() task, {
    bool readsOnly = true,
  }) async {
    void check() {
      if (!_isRunning) throw StateError('Download paused');
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        check();
        final operation = task();
        final value = readsOnly
            ? await waitCancellable(operation, checkCancelled: check)
            : await operation;
        check();
        return Res(value);
      } catch (error) {
        if (!_isRunning || attempt == 2) return Res.error(error.toString());
        await Future<void>.delayed(Duration(seconds: attempt + 1));
      }
    }
    throw StateError('Download retry budget exhausted');
  }

  Future<void> _resume() async {
    if (_isRunning) return;
    _isError = false;
    _coverCancellation = CancelToken();
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
          author: comic!.findAuthor() ?? comic!.subTitle ?? comic!.uploader,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
          null,
          _coverCancellation,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      }, readsOnly: false);
      if (!_isRunning) return;
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    final expectedChapters = comic!.chapters?.allChapters.keys.where(
      (chapter) => chapters == null || chapters!.contains(chapter),
    );
    if (_images == null ||
        (expectedChapters?.any((chapter) => !_images!.containsKey(chapter)) ??
            false)) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images ??= {};
        _totalCount = 0;
        int cpCount = 0;
        int totalCpCount =
            chapters?.length ?? comic!.chapters!.allChapters.length;
        for (var i in comic!.chapters!.allChapters.keys) {
          if (chapters != null && !chapters!.contains(i)) {
            continue;
          }
          if (_images![i] != null) {
            _totalCount += _images![i]!.length;
            continue;
          }
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isRunning) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images![i] = res.data;
            _totalCount += _images![i]!.length;
          }
        }
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (!_isRunning) return;
    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks();
        var task = tasks[_index]!;
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        await LocalManager().saveCurrentDownloadingTasks();
      }
      _index = 0;
      _chapter++;
    }

    if (!_isRunning || !await _uploadToNasIfNeeded()) return;
    if (!_isRunning) return;
    await LocalManager().completeTask(this);
    stopRecorder();
  }

  Future<bool> _uploadToNasIfNeeded() async {
    if (nasConnectionId == null) return true;
    _message = 'Uploading to NAS...';
    notifyListeners();
    try {
      await NasManager.instance.uploadComicDirectory(
        nasConnectionId!,
        toLocalComic(),
        checkCancelled: () {
          if (!_isRunning) throw StateError('Download paused');
        },
        onProgress: (sent, total) {
          _message =
              'Uploading to NAS: '
              '${bytesToReadableString(sent)}/${bytesToReadableString(total)}';
          notifyListeners();
        },
      );
      return true;
    } catch (e, s) {
      Log.error('NAS', 'Failed to upload downloaded comic: $e', s);
      _setError('NAS upload failed: $e');
      return false;
    }
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
      if (nasConnectionId != null) "nasConnectionId": nasConnectionId,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
        source: ComicSource.find(json["source"])!,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
        nasConnectionId: json["nasConnectionId"] as String?,
      )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    final previous = LocalManager().find(comicId, comicType);
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: LocalManager().relativeDirectoryOf(path!),
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      originalSourceKey: source.key,
      downloadedChapters: <String>{
        ...?previous?.downloadedChapters,
        ...?chapters ?? comic?.chapters?.ids.toList(),
      }.toList(),
      createdAt: previous?.createdAt ?? DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;
  bool _hasSettled = false;
  final _cancellation = CancelToken();

  void cancel() {
    isCancelled = true;
    _cancellation.cancel();
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  Future<void> start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
        cancelToken: _cancellation,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          break;
        }
      }
      if (!isComplete && !isCancelled) {
        throw StateError('Image stream ended without image data');
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        await start();
        return;
      }
      error = e.toString();
    } finally {
      if (isComplete || isCancelled || error != null) {
        _hasSettled = true;
        for (final c in completers) {
          if (!c.isCompleted) c.complete(this);
        }
        completers.clear();
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (_hasSettled) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  Future<void>? _activeRun;
  @override
  Future<void> get settled => _activeRun ?? Future<void>.value();
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic, {this.nasConnectionId}) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  final String? nasConnectionId;

  FileDownloader? _downloader;

  Future<void>? _pendingStop;

  Future<void>? _activeFinalization;

  int _runGeneration = 0;

  File get _archiveFile {
    final identity = '${comic.sourceKey}|${comic.id}|$archiveUrl';
    final suffix = sha256
        .convert(utf8.encode(identity))
        .toString()
        .substring(0, 20);
    return File(FilePath.join(App.dataPath, 'archive_downloading_$suffix.zip'));
  }

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    _runGeneration++;
    await _pendingStop;
    try {
      await _activeFinalization;
    } catch (_) {
      // An interrupted operation is cleaned up below.
    }
    if (_downloader != null) {
      await _downloader!.deletePartial();
    } else {
      final archive = _archiveFile;
      if (await archive.exists()) await archive.delete();
      final status = File('${archive.path}.download');
      if (await status.exists()) await status.delete();
    }
    if (path != null) {
      final existing = LocalManager().find(id, comicType);
      if (existing == null || existing.baseDir != path) {
        await Directory(path!).deleteIgnoreError(recursive: true);
      }
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _runGeneration++;
    _message = "Paused";
    _pendingStop = () async {
      await _downloader?.stop();
      try {
        await _activeFinalization;
      } catch (_) {
        // The running operation reports its own error.
      }
    }();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() {
    if (_activeRun != null || _isRunning) return;
    _activeRun = _resume()
        .catchError((Object error, StackTrace stack) {
          Log.error('Download', error, stack);
          _setError('Error: $error');
        })
        .whenComplete(() => _activeRun = null);
  }

  Future<void> _resume() async {
    if (_isRunning) {
      return;
    }
    final generation = ++_runGeneration;
    _isError = false;
    _isRunning = true;
    notifyListeners();
    await _pendingStop;
    if (generation != _runGeneration || !_isRunning) return;
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
        author: comic.findAuthor() ?? comic.subTitle ?? comic.uploader,
      );
      if (generation != _runGeneration || !_isRunning) return;
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    if (generation != _runGeneration || !_isRunning) return;

    final archiveFile = _archiveFile;

    Log.info("Download", "Downloading $archiveUrl");

    final threads = (appdata.settings['downloadThreads'] as num?)?.toInt() ?? 4;
    _downloader = FileDownloader(
      archiveUrl,
      archiveFile.path,
      maxConcurrent: threads.clamp(1, 8).toInt(),
    );

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning || generation != _runGeneration) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    final finalization = _finishArchive(archiveFile, generation);
    _activeFinalization = finalization;
    try {
      await finalization;
    } finally {
      _activeFinalization = null;
    }
  }

  Future<void> _finishArchive(File archiveFile, int generation) async {
    final staging = Directory(
      '${path!}.venera-download-${DateTime.now().microsecondsSinceEpoch}',
    );
    NasFileInstall? install;
    var committed = false;
    try {
      await _extractArchive(archiveFile.path, staging.path);
      if (!_isRunning || generation != _runGeneration) return;

      final files = <String>[];
      await for (final entity in staging.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          files.add(FilePath.relativeTo(staging.path, entity.path));
        }
      }
      if (!files.any(
        (relative) => !relative.contains('/') && _isComicImagePath(relative),
      )) {
        throw const FormatException('The archive contains no comic images');
      }
      install = await NasFileInstall.begin(staging, Directory(path!), files);
      if (!_isRunning || generation != _runGeneration) return;

      if (!await _uploadToNasIfNeeded()) return;
      if (!_isRunning || generation != _runGeneration) return;

      await LocalManager().completeTask(this);
      committed = true;
      await install.finish();
      await archiveFile.deleteIgnoreError();
    } catch (error) {
      if (_isRunning && generation == _runGeneration) {
        _setError('Failed to install archive: $error');
      }
    } finally {
      if (!committed && install != null) {
        await install.rollback();
      }
      await staging.deleteIgnoreError(recursive: true);
    }
  }

  Future<bool> _uploadToNasIfNeeded() async {
    if (nasConnectionId == null) return true;
    _message = 'Uploading to NAS...';
    notifyListeners();
    try {
      await NasManager.instance.uploadComicDirectory(
        nasConnectionId!,
        toLocalComic(),
        onProgress: (sent, total) {
          _message =
              'Uploading to NAS: '
              '${bytesToReadableString(sent)}/${bytesToReadableString(total)}';
          notifyListeners();
        },
      );
      return true;
    } catch (e, s) {
      Log.error('NAS', 'Failed to upload downloaded archive: $e', s);
      _setError('NAS upload failed: $e');
      return false;
    }
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      final cacheDir = Directory(
        FilePath.join(
          App.cachePath,
          'archive_downloading_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        await Isolate.run(() => extractComicArchive(archive, cacheDir.path));
        await copyDirectoryIsolate(cacheDir, out);
      } finally {
        await cacheDir.deleteIgnoreError(recursive: true);
      }
    } else {
      await Isolate.run(() => extractComicArchive(archive, outDir));
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
      if (nasConnectionId != null) "nasConnectionId": nasConnectionId,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
      nasConnectionId: json["nasConnectionId"] as String?,
    )..path = json["path"];
  }

  String _findCover() {
    final files = Directory(path!)
        .listSync()
        .whereType<File>()
        .where((file) => _isComicImagePath(file.path))
        .toList();
    if (files.isEmpty) {
      throw const FormatException('The archive contains no comic images');
    }
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: LocalManager().relativeDirectoryOf(path!),
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}

bool _isComicImagePath(String path) => const {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
}.contains(path.split('.').last.toLowerCase());

/// Extracts a ZIP archive to an empty staging directory. Rejects paths that
/// escape it and checks each file before any comic image is replaced.
Future<void> extractComicArchive(String archivePath, String outputPath) async {
  final root = path_util.canonicalize(path_util.absolute(outputPath));
  final input = InputFileStream(archivePath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    Directory(root).createSync(recursive: true);
    for (final entry in archive) {
      final target = path_util.canonicalize(path_util.join(root, entry.name));
      if (path_util.isAbsolute(entry.name) ||
          (target != root && !path_util.isWithin(root, target)) ||
          entry.isSymbolicLink) {
        throw FormatException('Unsafe archive entry: ${entry.name}');
      }
      if (entry.isDirectory) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      if (!entry.isFile) continue;

      final outputFile = File(target);
      outputFile.parent.createSync(recursive: true);
      final output = OutputFileStream(target);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (outputFile.lengthSync() != entry.size) {
        throw FormatException('Truncated archive entry: ${entry.name}');
      }
      if (entry.crc32 case final expectedCrc?) {
        var actualCrc = 0;
        await for (final chunk in outputFile.openRead()) {
          actualCrc = getCrc32(chunk, actualCrc);
        }
        if (actualCrc != expectedCrc) {
          throw FormatException('Corrupt archive entry: ${entry.name}');
        }
      }
    }
  } finally {
    await input.close();
  }
}

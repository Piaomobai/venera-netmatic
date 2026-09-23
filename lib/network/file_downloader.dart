import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:venera_netmatic/network/app_dio.dart';
import 'package:venera_netmatic/network/proxy.dart';

/// Streams an archive to disk. Resume is allowed only for the same URL and a
/// server-validated version of the file.
class FileDownloader {
  FileDownloader(
    this.url,
    this.savePath, {
    this.maxConcurrent = 4,
    this.minPartBytes = 4 * 1024 * 1024,
  }) : assert(maxConcurrent > 0),
       assert(minPartBytes > 0);

  final String url;
  final String savePath;
  final int maxConcurrent;
  final int minPartBytes;

  final Dio _dio = Dio();
  final CancelToken _cancelToken = CancelToken();
  CancelToken? _parallelCancelToken;
  Completer<void>? _finished;
  RandomAccessFile? _file;
  Timer? _progressTimer;
  Future<void> _statusQueue = Future<void>.value();

  bool _canceled = false;
  int _currentBytes = 0;
  int _fileSize = 0;
  int _checkpointBytes = 0;
  int _lastBytes = 0;
  String? _validator;

  File get _partialFile => File(savePath);
  File get _statusFile => File('$savePath.download');
  File get _assemblingFile => File('$savePath.assembling');

  Stream<DownloadingStatus> start() {
    if (_finished != null) {
      throw StateError('A FileDownloader can only be started once');
    }
    _finished = Completer<void>();
    final stream = StreamController<DownloadingStatus>();
    unawaited(_download(stream));
    return stream.stream;
  }

  Future<void> stop() async {
    _canceled = true;
    _cancelToken.cancel('Download stopped');
    _parallelCancelToken?.cancel('Download stopped');
    await _finished?.future;
  }

  Future<void> deletePartial() async {
    await stop();
    if (await _partialFile.exists()) await _partialFile.delete();
    if (await _statusFile.exists()) await _statusFile.delete();
    if (await _assemblingFile.exists()) await _assemblingFile.delete();
    for (var index = 0; index < 32; index++) {
      final part = File('$savePath.part$index');
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> _download(StreamController<DownloadingStatus> stream) async {
    var completed = false;
    try {
      final proxy = await getProxy();
      if (_canceled) return;
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()
              ..findProxy = (uri) => proxy == null ? 'DIRECT' : 'PROXY $proxy',
      );

      int? headSize;
      String? headValidator;
      Uri? headUri;
      var acceptsRanges = false;
      try {
        final head = await _dio.head<void>(
          url,
          cancelToken: _cancelToken,
          options: Options(headers: {'Accept-Encoding': 'identity'}),
        );
        headSize = _positiveLength(head.headers.value('content-length'));
        headValidator = _responseValidator(head.headers);
        headUri = head.realUri;
        acceptsRanges =
            head.headers
                .value('accept-ranges')
                ?.toLowerCase()
                .split(',')
                .map((value) => value.trim())
                .contains('bytes') ==
            true;
      } on DioException {
        // A HEAD failure should not prevent a normal streaming GET.
        if (_canceled) return;
      }

      final resumeOffset = await _resumeOffset(headSize, headValidator);
      if (_canceled) return;
      final partCount = headSize == null
          ? 0
          : (headSize ~/ minPartBytes).clamp(0, maxConcurrent).toInt();
      if (resumeOffset == 0 &&
          partCount >= 2 &&
          acceptsRanges &&
          headValidator != null &&
          headValidator.startsWith('"') &&
          headUri != null) {
        if (await _downloadParallel(
          stream,
          headSize!,
          headValidator,
          headUri,
          partCount,
        )) {
          completed = true;
          return;
        }
        if (_canceled) return;
      }
      await _clearParallelArtifacts();
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept-Encoding': 'identity',
            if (resumeOffset > 0) ...{
              'Range': 'bytes=$resumeOffset-',
              'If-Range': headValidator!,
            },
          },
        ),
      );
      if (_canceled) return;
      final body = response.data;
      if (body == null) throw StateError('The download response has no body');

      if (resumeOffset > 0 && response.statusCode == 206) {
        _fileSize = _validatedRangeTotal(
          response.headers.value('content-range'),
          resumeOffset,
          headSize!,
        );
        final responseValidator = _responseValidator(response.headers);
        if (responseValidator != null && responseValidator != headValidator) {
          throw StateError('The remote file changed during resume');
        }
        _currentBytes = resumeOffset;
        _validator = headValidator;
        _file = await _partialFile.open(mode: FileMode.append);
        await _file!.truncate(resumeOffset);
        await _file!.setPosition(resumeOffset);
      } else if (response.statusCode == 200) {
        // If-Range may return 200 when the file changed. Reuse this response
        // from byte zero instead of mixing it with the old partial file.
        final responseSize = _positiveLength(
          response.headers.value('content-length'),
        );
        final responseValidator = _responseValidator(response.headers);
        if (headSize != null &&
            responseSize != null &&
            headSize != responseSize &&
            headValidator != null &&
            headValidator == responseValidator) {
          throw StateError('The server reported inconsistent file sizes');
        }
        _currentBytes = 0;
        _fileSize = responseSize ?? 0;
        _validator = responseValidator;
        _file = await _partialFile.open(mode: FileMode.write);
      } else {
        throw StateError('Unexpected download status: ${response.statusCode}');
      }

      _checkpointBytes = _currentBytes;
      await _writeStatus();
      stream.add(DownloadingStatus(_currentBytes, _fileSize, 0));
      _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!stream.isClosed) {
          stream.add(
            DownloadingStatus(
              _currentBytes,
              _fileSize,
              _currentBytes - _lastBytes,
            ),
          );
        }
        _lastBytes = _currentBytes;
      });

      await for (final chunk in body.stream) {
        if (_canceled) return;
        if (_fileSize > 0 && _currentBytes + chunk.length > _fileSize) {
          throw StateError('The server sent more bytes than expected');
        }
        await _file!.writeFrom(chunk);
        _currentBytes += chunk.length;
        if (_currentBytes - _checkpointBytes >= 1024 * 1024) {
          await _file!.flush();
          await _writeStatus();
          _checkpointBytes = _currentBytes;
        }
      }
      if (_canceled) return;
      if (_currentBytes == 0 || (_fileSize > 0 && _currentBytes != _fileSize)) {
        throw StateError(
          'Download incomplete: $_currentBytes of $_fileSize bytes',
        );
      }
      _fileSize = _currentBytes;
      await _file!.flush();
      await _file!.close();
      _file = null;
      if (await _statusFile.exists()) await _statusFile.delete();
      completed = true;
      stream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
    } catch (error, stack) {
      if (!_canceled && !stream.isClosed) stream.addError(error, stack);
    } finally {
      _progressTimer?.cancel();
      final file = _file;
      _file = null;
      if (file != null) {
        try {
          await file.flush();
          if (!completed) await _writeStatus();
          await file.close();
        } catch (_) {
          try {
            await file.close();
          } catch (_) {}
        }
      }
      await stream.close();
      _finished?.complete();
    }
  }

  Future<bool> _downloadParallel(
    StreamController<DownloadingStatus> stream,
    int size,
    String validator,
    Uri expectedUri,
    int count,
  ) async {
    final parts = await _loadParts(size, validator, count);
    _fileSize = size;
    _currentBytes = parts.fold<int>(0, (sum, part) => sum + part.received);
    _lastBytes = _currentBytes;
    await _writeParallelStatus(parts, size, validator);
    stream.add(DownloadingStatus(_currentBytes, size, 0));
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!stream.isClosed) {
        stream.add(
          DownloadingStatus(
            _currentBytes,
            _fileSize,
            _currentBytes - _lastBytes,
          ),
        );
      }
      _lastBytes = _currentBytes;
    });

    final token = CancelToken();
    _parallelCancelToken = token;
    final downloads = parts
        .map(
          (part) =>
              _downloadPart(part, parts, size, validator, expectedUri, token),
        )
        .toList();
    try {
      try {
        await Future.wait(downloads, eagerError: true);
      } catch (error, stack) {
        token.cancel('Range download stopped');
        await Future.wait(downloads.map((future) => future.catchError((_) {})));
        await _statusQueue;
        if (!_canceled && error is _RangeUnsupported) {
          _progressTimer?.cancel();
          _progressTimer = null;
          _currentBytes = 0;
          _lastBytes = 0;
          await _clearParallelArtifacts();
          return false;
        }
        Error.throwWithStackTrace(error, stack);
      }
      if (_canceled) return false;
      await _statusQueue;
      await _assembleParts(parts, size);
      for (final part in parts) {
        final file = File('$savePath.part${part.index}');
        if (await file.exists()) await file.delete();
      }
      if (await _statusFile.exists()) await _statusFile.delete();
      _progressTimer?.cancel();
      _progressTimer = null;
      stream.add(DownloadingStatus(size, size, 0, true));
      return true;
    } finally {
      _parallelCancelToken = null;
    }
  }

  Future<List<_DownloadPart>> _loadParts(
    int size,
    String validator,
    int count,
  ) async {
    final partSize = (size + count - 1) ~/ count;
    final parts = <_DownloadPart>[];
    for (var index = 0; index < count; index++) {
      final start = index * partSize;
      if (start >= size) break;
      final end = (start + partSize - 1).clamp(0, size - 1);
      parts.add(_DownloadPart(index, start, end));
    }
    try {
      final raw = jsonDecode(await _statusFile.readAsString());
      if (raw is! Map ||
          raw['mode'] != 'parallel' ||
          raw['url'] != url ||
          raw['size'] != size ||
          raw['validator'] != validator ||
          raw['parts'] is! List ||
          (raw['parts'] as List).length != parts.length) {
        return parts;
      }
      final received = <int>[];
      for (var index = 0; index < parts.length; index++) {
        final saved = (raw['parts'] as List)[index];
        final part = parts[index];
        if (saved is! Map ||
            saved['start'] != part.start ||
            saved['end'] != part.end ||
            saved['received'] is! int ||
            saved['received'] < 0 ||
            saved['received'] > part.length ||
            (saved['received'] > 0 &&
                (!await File('$savePath.part$index').exists() ||
                    await File('$savePath.part$index').length() <
                        saved['received']))) {
          return parts;
        }
        received.add(saved['received'] as int);
      }
      for (var index = 0; index < parts.length; index++) {
        parts[index].received = received[index];
      }
    } catch (_) {
      return parts;
    }
    return parts;
  }

  Future<void> _downloadPart(
    _DownloadPart part,
    List<_DownloadPart> parts,
    int size,
    String validator,
    Uri expectedUri,
    CancelToken token,
  ) async {
    if (part.received == part.length) return;
    final offset = part.start + part.received;
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        headers: {
          'Accept-Encoding': 'identity',
          'Range': 'bytes=$offset-${part.end}',
          'If-Range': validator,
        },
      ),
    );
    final expectedRange = 'bytes $offset-${part.end}/$size';
    final responseLength = _positiveLength(
      response.headers.value('content-length'),
    );
    if (response.statusCode != 206 ||
        response.realUri != expectedUri ||
        response.headers.value('content-range') != expectedRange ||
        response.headers.value('etag') != validator ||
        (responseLength != null && responseLength != part.end - offset + 1)) {
      throw const _RangeUnsupported();
    }
    final body = response.data;
    if (body == null) throw const _RangeUnsupported();

    final file = await File(
      '$savePath.part${part.index}',
    ).open(mode: part.received == 0 ? FileMode.write : FileMode.append);
    var checkpoint = part.received;
    try {
      if (part.received > 0) {
        await file.truncate(part.received);
        await file.setPosition(part.received);
      }
      await for (final chunk in body.stream) {
        if (_canceled || token.isCancelled) return;
        if (part.received + chunk.length > part.length) {
          throw const _RangeUnsupported();
        }
        await file.writeFrom(chunk);
        part.received += chunk.length;
        _currentBytes += chunk.length;
        if (part.received - checkpoint >= 1024 * 1024) {
          await file.flush();
          await _writeParallelStatus(parts, size, validator);
          checkpoint = part.received;
        }
      }
      if (part.received != part.length) {
        throw StateError('Incomplete download range: ${part.index}');
      }
    } finally {
      try {
        await file.flush();
        await _writeParallelStatus(parts, size, validator);
      } finally {
        await file.close();
      }
    }
  }

  Future<void> _writeParallelStatus(
    List<_DownloadPart> parts,
    int size,
    String validator,
  ) async {
    final previous = _statusQueue;
    final done = Completer<void>();
    _statusQueue = done.future;
    try {
      await previous;
      final temporary = File('${_statusFile.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'mode': 'parallel',
          'url': url,
          'size': size,
          'validator': validator,
          'parts': [
            for (final part in parts)
              {'start': part.start, 'end': part.end, 'received': part.received},
          ],
        }),
        flush: true,
      );
      try {
        await temporary.rename(_statusFile.path);
      } on FileSystemException {
        if (await _statusFile.exists()) await _statusFile.delete();
        await temporary.rename(_statusFile.path);
      }
    } finally {
      done.complete();
    }
  }

  Future<void> _assembleParts(List<_DownloadPart> parts, int size) async {
    final output = _assemblingFile.openWrite(mode: FileMode.write);
    try {
      for (final part in parts) {
        if (_canceled) throw StateError('Download stopped');
        await output.addStream(
          File('$savePath.part${part.index}').openRead(0, part.length),
        );
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (_canceled) throw StateError('Download stopped');
    if (await _assemblingFile.length() != size) {
      throw StateError('The assembled archive has the wrong size');
    }
    try {
      await _assemblingFile.rename(savePath);
    } on FileSystemException {
      if (await _partialFile.exists()) await _partialFile.delete();
      await _assemblingFile.rename(savePath);
    }
  }

  Future<void> _clearParallelArtifacts() async {
    for (var index = 0; index < 32; index++) {
      final part = File('$savePath.part$index');
      if (await part.exists()) await part.delete();
    }
    if (await _assemblingFile.exists()) await _assemblingFile.delete();
    try {
      final raw = jsonDecode(await _statusFile.readAsString());
      if (raw is Map && raw['mode'] == 'parallel') {
        await _statusFile.delete();
      }
    } catch (_) {}
  }

  Future<int> _resumeOffset(int? size, String? validator) async {
    if (size == null ||
        validator == null ||
        !await _partialFile.exists() ||
        !await _statusFile.exists()) {
      return 0;
    }
    try {
      final raw = jsonDecode(await _statusFile.readAsString());
      if (raw is! Map ||
          raw['url'] != url ||
          raw['size'] != size ||
          raw['validator'] != validator) {
        return 0;
      }
      final received = raw['received'];
      if (received is! int ||
          received <= 0 ||
          received >= size ||
          await _partialFile.length() < received) {
        return 0;
      }
      return received;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _writeStatus() async {
    final temporary = File('${_statusFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'url': url,
        'size': _fileSize,
        'validator': _validator,
        'received': _currentBytes,
      }),
      flush: true,
    );
    try {
      await temporary.rename(_statusFile.path);
    } on FileSystemException {
      // If replacement is unsupported, losing this status only loses resume
      // progress. It never marks a partial file as complete.
      if (await _statusFile.exists()) await _statusFile.delete();
      await temporary.rename(_statusFile.path);
    }
  }

  static int? _positiveLength(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static String? _responseValidator(Headers headers) {
    final etag = headers.value('etag');
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    final modified = headers.value('last-modified');
    return modified == null || modified.isEmpty ? null : modified;
  }

  static int _validatedRangeTotal(String? header, int offset, int expected) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(header ?? '');
    if (match == null ||
        int.parse(match[1]!) != offset ||
        int.parse(match[2]!) != expected - 1 ||
        int.parse(match[3]!) != expected) {
      throw StateError('The server returned an invalid byte range');
    }
    return expected;
  }
}

class _DownloadPart {
  _DownloadPart(this.index, this.start, this.end);

  final int index;
  final int start;
  final int end;
  int received = 0;

  int get length => end - start + 1;
}

class _RangeUnsupported implements Exception {
  const _RangeUnsupported();
}

class DownloadingStatus {
  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  final int downloadedBytes;
  final int totalBytes;
  final int bytesPerSecond;
  final bool isFinished;

  @override
  String toString() =>
      'Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}';
}

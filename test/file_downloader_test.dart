import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/network/file_downloader.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late Object? oldProxy;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-download-test-');
    oldProxy = appdata.settings['proxy'];
    appdata.settings['proxy'] = 'direct';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
    appdata.settings['proxy'] = oldProxy;
  });

  String url() => 'http://127.0.0.1:${server.port}/archive.zip';
  File output() => File('${directory.path}/archive.zip');

  void serve(List<int> bytes, {bool ignoreRange = false, int? sentBytes}) {
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"version-1"');
      if (request.method == 'HEAD') {
        response.headers.contentLength = bytes.length;
        await response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && !ignoreRange) {
        final offset = int.parse(
          range.substring('bytes='.length).split('-').first,
        );
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $offset-${bytes.length - 1}/${bytes.length}',
        );
        final remaining = bytes.sublist(offset);
        response.headers.contentLength = remaining.length;
        response.add(remaining);
      } else {
        final body = bytes.take(sentBytes ?? bytes.length).toList();
        response.headers.contentLength = body.length;
        response.add(body);
      }
      await response.close();
    });
  }

  Future<void> seedPartial(List<int> bytes, int received) async {
    await output().writeAsBytes(bytes.take(received).toList());
    await File('${output().path}.download').writeAsString(
      jsonEncode({
        'url': url(),
        'size': bytes.length,
        'validator': '"version-1"',
        'received': received,
      }),
    );
  }

  test('downloads a complete archive', () async {
    final bytes = List<int>.generate(32768, (index) => index % 251);
    serve(bytes);

    final events = await FileDownloader(url(), output().path).start().toList();

    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
    expect(await File('${output().path}.download').exists(), isFalse);
  });

  test('resumes only the validated remainder', () async {
    final bytes = List<int>.generate(1000, (index) => index % 251);
    await seedPartial(bytes, 321);
    String? observedRange;
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"version-1"');
      if (request.method == 'HEAD') {
        response.headers.contentLength = bytes.length;
      } else {
        observedRange = request.headers.value(HttpHeaders.rangeHeader);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 321-999/1000',
        );
        response.headers.contentLength = 679;
        response.add(bytes.sublist(321));
      }
      await response.close();
    });

    final events = await FileDownloader(url(), output().path).start().toList();

    expect(observedRange, 'bytes=321-');
    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
  });

  test('restarts cleanly when the server ignores Range', () async {
    final bytes = List<int>.generate(1000, (index) => index % 251);
    await seedPartial(bytes, 321);
    serve(bytes, ignoreRange: true);

    final events = await FileDownloader(url(), output().path).start().toList();

    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
  });

  test('rejects inconsistent HEAD and GET sizes', () async {
    final bytes = List<int>.generate(1000, (index) => index % 251);
    serve(bytes, sentBytes: 400);

    await expectLater(
      FileDownloader(url(), output().path).start().toList(),
      throwsA(isA<StateError>()),
    );
    expect(await output().exists(), isFalse);
  });

  test('accepts a streaming response without Content-Length', () async {
    final bytes = List<int>.generate(4096, (index) => index % 251);
    server.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add(bytes);
      }
      await request.response.close();
    });

    final events = await FileDownloader(url(), output().path).start().toList();

    expect(events.last.isFinished, isTrue);
    expect(events.last.totalBytes, bytes.length);
    expect(await output().readAsBytes(), bytes);
  });

  test('stopping during HEAD closes the progress stream', () async {
    final headSeen = Completer<void>();
    final releaseHead = Completer<void>();
    server.listen((request) async {
      if (request.method == 'HEAD') {
        headSeen.complete();
        await releaseHead.future;
      }
      await request.response.close();
    });
    final downloader = FileDownloader(url(), output().path);
    final events = downloader.start().toList();

    await headSeen.future.timeout(const Duration(seconds: 5));
    final stopping = downloader.stop();
    releaseHead.complete();
    await stopping.timeout(const Duration(seconds: 5));
    expect(await events.timeout(const Duration(seconds: 5)), isEmpty);
  });

  test('downloads validated ranges concurrently and assembles them', () async {
    final bytes = List<int>.generate(4000, (index) => index % 251);
    final allStarted = Completer<void>();
    final ranges = <String>[];
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"version-1"');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        response.headers.contentLength = bytes.length;
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        ranges.add(range);
        if (ranges.length == 4) allStarted.complete();
        await allStarted.future.timeout(const Duration(seconds: 5));
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        response.headers.contentLength = end - start + 1;
        response.add(bytes.sublist(start, end + 1));
      }
      await response.close();
    });

    final events = await FileDownloader(
      url(),
      output().path,
      maxConcurrent: 4,
      minPartBytes: 1000,
    ).start().toList().timeout(const Duration(seconds: 10));

    expect(ranges, hasLength(4));
    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
    expect(await File('${output().path}.download').exists(), isFalse);
  });

  test(
    'falls back to one stream when the server ignores range requests',
    () async {
      final bytes = List<int>.generate(4000, (index) => index % 251);
      var fullRequests = 0;
      server.listen((request) async {
        final response = request.response;
        response.headers.set(HttpHeaders.etagHeader, '"version-1"');
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (request.method == 'HEAD') {
          response.headers.contentLength = bytes.length;
        } else {
          if (request.headers.value(HttpHeaders.rangeHeader) == null) {
            fullRequests++;
          }
          response.headers.contentLength = bytes.length;
          response.add(bytes);
        }
        try {
          await response.close();
        } catch (_) {
          // A cancelled range probe can close its connection first.
        }
      });

      final events = await FileDownloader(
        url(),
        output().path,
        maxConcurrent: 4,
        minPartBytes: 1000,
      ).start().toList();

      expect(fullRequests, 1);
      expect(events.last.isFinished, isTrue);
      expect(await output().readAsBytes(), bytes);
    },
  );

  test('does not combine ranges from a changed archive version', () async {
    final bytes = List<int>.generate(4000, (index) => index % 251);
    var fullRequests = 0;
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        response.headers.set(HttpHeaders.etagHeader, '"version-1"');
        response.headers.contentLength = bytes.length;
      } else if (request.headers.value(HttpHeaders.rangeHeader) != null) {
        response.headers.set(HttpHeaders.etagHeader, '"version-2"');
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-999/${bytes.length}',
        );
        response.headers.contentLength = 1000;
        response.add(bytes.sublist(0, 1000));
      } else {
        fullRequests++;
        response.headers.set(HttpHeaders.etagHeader, '"version-2"');
        response.headers.contentLength = bytes.length;
        response.add(bytes);
      }
      try {
        await response.close();
      } catch (_) {}
    });

    final events = await FileDownloader(
      url(),
      output().path,
      maxConcurrent: 4,
      minPartBytes: 1000,
    ).start().toList();

    expect(fullRequests, 1);
    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
  });

  test('resumes only unfinished validated parts', () async {
    final bytes = List<int>.generate(4000, (index) => index % 251);
    final observedRanges = <String>[];
    await File('${output().path}.part0').writeAsBytes(bytes.sublist(0, 1000));
    await File(
      '${output().path}.part1',
    ).writeAsBytes(bytes.sublist(1000, 1400));
    await File('${output().path}.download').writeAsString(
      jsonEncode({
        'mode': 'parallel',
        'url': url(),
        'size': bytes.length,
        'validator': '"version-1"',
        'parts': [
          {'start': 0, 'end': 999, 'received': 1000},
          {'start': 1000, 'end': 1999, 'received': 400},
          {'start': 2000, 'end': 2999, 'received': 0},
          {'start': 3000, 'end': 3999, 'received': 0},
        ],
      }),
    );
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, '"version-1"');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        response.headers.contentLength = bytes.length;
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        observedRanges.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        response.headers.contentLength = end - start + 1;
        response.add(bytes.sublist(start, end + 1));
      }
      await response.close();
    });

    final events = await FileDownloader(
      url(),
      output().path,
      maxConcurrent: 4,
      minPartBytes: 1000,
    ).start().toList();

    expect(
      observedRanges,
      containsAll(['bytes=1400-1999', 'bytes=2000-2999', 'bytes=3000-3999']),
    );
    expect(observedRanges, hasLength(3));
    expect(events.last.isFinished, isTrue);
    expect(await output().readAsBytes(), bytes);
  });
}

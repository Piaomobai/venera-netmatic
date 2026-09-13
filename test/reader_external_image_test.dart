import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  test(
    'reader image provider loads NAS bytes through the external loader',
    () async {
      final expected = Uint8List.fromList([1, 2, 3, 4]);
      String? requestedPath;
      final provider = ReaderImageProvider(
        'chapter/1.webp',
        'picacg',
        'comic-id',
        'chapter-id',
        1,
        externalCacheKey: 'nas-id:library/comic',
        externalBytesLoader: (path) async {
          requestedPath = path;
          return expected;
        },
      );
    final events = StreamController<ImageChunkEvent>();

    final actual = await provider.load(events, () {});
    unawaited(events.close());

      expect(requestedPath, 'chapter/1.webp');
      expect(actual, expected);
      expect(provider.key, contains('nas-id:library/comic'));
    },
  );
}

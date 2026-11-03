import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';

void main() {
  test('NAS hashing can cancel between file chunks', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-nas-hash-cancel-',
    );
    final file = File('${directory.path}/sample.bin');
    try {
      await file.writeAsBytes(List.filled(256 * 1024, 1));
      var checks = 0;
      await expectLater(
        computeNasFileSha256(
          file,
          checkCancelled: () {
            if (++checks >= 2) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(checks, greaterThanOrEqualTo(2));
      await file.delete();
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('NAS file fingerprint uses SHA-256 file contents', () async {
    final directory = await Directory.systemTemp.createTemp('venera-nas-hash-');
    final file = File('${directory.path}${Platform.pathSeparator}sample.txt');
    try {
      await file.writeAsString('abc');
      expect(
        await computeNasFileSha256(file),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );

      // A content change with the same byte length must not be considered the
      // same file. Size-only incremental sync would miss this case.
      await file.writeAsString('abd');
      expect(
        await computeNasFileSha256(file),
        isNot(
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
      );
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/network/download.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-archive-test-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('extracts and checks an archive in a staging directory', () async {
    final zip = File('${root.path}/comic.zip');
    final archive = Archive()..addFile(ArchiveFile.string('1.jpg', 'image'));
    await zip.writeAsBytes(ZipEncoder().encode(archive));

    await extractComicArchive(zip.path, '${root.path}/stage');

    expect(await File('${root.path}/stage/1.jpg').readAsString(), 'image');
  });

  test('rejects an archive path that escapes the staging directory', () async {
    final zip = File('${root.path}/comic.zip');
    final archive = Archive()
      ..addFile(ArchiveFile.string('../outside.jpg', 'bad'));
    await zip.writeAsBytes(ZipEncoder().encode(archive));

    await expectLater(
      extractComicArchive(zip.path, '${root.path}/stage'),
      throwsA(isA<FormatException>()),
    );
    expect(await File('${root.path}/outside.jpg').exists(), isFalse);
  });
}

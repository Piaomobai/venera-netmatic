import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/nas/nas_library.dart';
import 'package:venera_netmatic/foundation/nas/nas_remote_client.dart';

void main() {
  test('a failed remote promotion restores the previous NAS file', () async {
    final remote = <String, String>{'comic/1.jpg': 'old', 'upload.tmp': 'new'};

    await expectLater(
      replaceRemoteFileKeepingBackup(
        temporary: 'upload.tmp',
        target: 'comic/1.jpg',
        exists: (path) async => remote.containsKey(path),
        rename: (from, to) async {
          if (from == 'upload.tmp') throw const FileSystemException('offline');
          remote[to] = remote.remove(from)!;
        },
        delete: (path) async => remote.remove(path),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(remote['comic/1.jpg'], 'old');
    expect(remote.keys.where((key) => key.contains('venera-backup')), isEmpty);
  });

  test('successful remote promotion removes its backup', () async {
    final remote = <String, String>{'comic/1.jpg': 'old', 'upload.tmp': 'new'};

    await replaceRemoteFileKeepingBackup(
      temporary: 'upload.tmp',
      target: 'comic/1.jpg',
      exists: (path) async => remote.containsKey(path),
      rename: (from, to) async => remote[to] = remote.remove(from)!,
      delete: (path) async => remote.remove(path),
    );

    expect(remote, {'comic/1.jpg': 'new'});
  });

  test('an existing NAS image can be retained when content changes', () async {
    final remote = <String, String>{'comic/1.jpg': 'old', 'upload.tmp': 'new'};

    await replaceRemoteFileKeepingBackup(
      temporary: 'upload.tmp',
      target: 'comic/1.jpg',
      preservePrevious: true,
      exists: (path) async => remote.containsKey(path),
      rename: (from, to) async => remote[to] = remote.remove(from)!,
      delete: (path) async => remote.remove(path),
    );

    expect(remote['comic/1.jpg'], 'new');
    final backups = remote.entries.where(
      (entry) => entry.key.contains('.venera-backup-'),
    );
    expect(backups.map((entry) => entry.value), ['old']);
  });

  test('failed local install restores the existing comic file', () async {
    final root = await Directory.systemTemp.createTemp(
      'venera-nas-stage-test-',
    );
    try {
      final staging = await Directory('${root.path}/stage').create();
      final destination = await Directory('${root.path}/comic').create();
      await File('${staging.path}/1.jpg').writeAsString('new');
      await File('${destination.path}/1.jpg').writeAsString('old');

      await expectLater(
        NasFileInstall.begin(staging, destination, ['1.jpg', 'missing.jpg']),
        throwsA(isA<FileSystemException>()),
      );

      expect(await File('${destination.path}/1.jpg').readAsString(), 'old');
      expect(await File('${destination.path}/missing.jpg').exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });
}

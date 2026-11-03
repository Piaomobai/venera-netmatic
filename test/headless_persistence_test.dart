import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/network/cookie_jar.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('headless-persistence-');
    App.dataPath = temp.path;
    App.isInitialized = true;
    App.isHeadless = true;
    Log.isMuted = true;
  });
  tearDown(() async {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    App.isInitialized = false;
    App.isHeadless = false;
    await temp.delete(recursive: true);
  });

  test('queue writes finish with valid JSON and no temporary file', () async {
    final local = LocalManager();
    await Future.wait(
      List.generate(20, (_) => local.saveCurrentDownloadingTasks()),
    );
    await local.flushDownloadingTasks();
    expect(
      jsonDecode(
        await File('${temp.path}/downloading_tasks.json').readAsString(),
      ),
      [],
    );
    expect(
      await File('${temp.path}/downloading_tasks.json.tmp').exists(),
      isFalse,
    );
  });

  test(
    'unsupported queue entries survive failed restore and cannot be overwritten',
    () async {
      final local = LocalManager();
      final file = File('${temp.path}/downloading_tasks.json');
      const contents = '[{"type":"future-format","keep":"original"}]';
      await file.writeAsString(contents);
      expect(local.restoreDownloadingTasks, throwsFormatException);
      await expectLater(
        local.saveCurrentDownloadingTasks(),
        throwsFormatException,
      );
      expect(await file.readAsString(), contents);
      // Reset the singleton using a valid restored queue for later tests.
      await file.writeAsString('[]');
      local.restoreDownloadingTasks();
      await local.saveCurrentDownloadingTasks();
    },
  );

  test(
    'settings and cookies use the selected profile without a platform path lookup',
    () async {
      await File('${temp.path}/appdata.json').writeAsString(
        jsonEncode({
          'settings': {'deviceId': 'isolated-fixture', 'dataVersion': 123},
          'searchHistory': ['profile-only'],
        }),
      );
      await appdata.init();
      expect(appdata.settings['deviceId'], 'isolated-fixture');
      expect(appdata.searchHistory, ['profile-only']);
      final cookies = await SingleInstanceCookieJar.createInstance();
      expect(cookies.path, '${temp.path}/cookie.db');
      expect(await File(cookies.path).exists(), isTrue);
    },
  );
}

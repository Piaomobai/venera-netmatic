part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              "V${App.version}",
              style: const TextStyle(fontSize: 16),
            ),
            const Text(
              "Venera Netmatic",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            Text(
              "Venera Netmatic is an unofficial free and open-source modification of Venera."
                  .tl,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("GitHub - Venera Netmatic"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/Piaomobai/venera-netmatic");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Upstream Venera"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/venera-app/venera");
          },
        ).toSliver(),
      ],
    );
  }
}

Future<bool> checkUpdate() async {
  var res = await AppDio().get(
      "https://raw.githubusercontent.com/Piaomobai/venera-netmatic/main/pubspec.yaml");
  if (res.statusCode == 200) {
    var data = loadYaml(res.data);
    if (data["version"] != null) {
      return _compareVersion(data["version"].toString(), App.version);
    }
  }
  return false;
}

Future<void> checkUpdateUi([bool showMessageIfNoUpdate = true, bool delay = false]) async {
  try {
    var value = await checkUpdate();
    if (value) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      showDialog(
          context: App.rootContext,
          builder: (context) {
            return ContentDialog(
              title: "New version available".tl,
              content: Text(
                      "A new version is available. Do you want to update now?"
                          .tl)
                  .paddingHorizontal(16),
              actions: [
                Button.text(
                  onPressed: () {
                    Navigator.pop(context);
                    launchUrlString(
                        "https://github.com/Piaomobai/venera-netmatic/releases");
                  },
                  child: Text("Update".tl),
                ),
              ],
            );
          });
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  List<int> core(String version) {
    final parts = version.split("+").first.split("-").first.split(".");
    return List.generate(
      3,
      (index) => index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0,
    );
  }

  List<String> preRelease(String version) {
    final value = version.split("+").first;
    final separator = value.indexOf("-");
    return separator == -1
        ? const []
        : value.substring(separator + 1).split(".");
  }

  final v1 = core(version1);
  final v2 = core(version2);
  for (var i = 0; i < 3; i++) {
    if (v1[i] > v2[i]) {
      return true;
    }
    if (v1[i] < v2[i]) {
      return false;
    }
  }

  final pre1 = preRelease(version1);
  final pre2 = preRelease(version2);
  if (pre1.isEmpty || pre2.isEmpty) {
    return pre1.isEmpty && pre2.isNotEmpty;
  }
  for (var i = 0; i < pre1.length && i < pre2.length; i++) {
    if (pre1[i] == pre2[i]) {
      continue;
    }
    final part1 = int.tryParse(pre1[i]);
    final part2 = int.tryParse(pre2[i]);
    if (part1 != null && part2 != null) {
      return part1 > part2;
    }
    if (part1 != null) {
      return false;
    }
    if (part2 != null) {
      return true;
    }
    return pre1[i].compareTo(pre2[i]) > 0;
  }
  return pre1.length > pre2.length;
}

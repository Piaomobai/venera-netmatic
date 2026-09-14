import 'package:flutter/material.dart';
import 'package:venera_netmatic/foundation/appdata.dart';
import 'package:venera_netmatic/pages/categories_page.dart';
import 'package:venera_netmatic/pages/nas_library_page.dart';
import 'package:venera_netmatic/pages/scheduler/scheduler_page.dart';
import 'package:venera_netmatic/pages/search_page.dart';
import 'package:venera_netmatic/pages/settings/settings_page.dart';
import 'package:venera_netmatic/pages/storage_manager_page.dart';
import 'package:venera_netmatic/utils/translations.dart';

import '../components/components.dart';
import '../foundation/app.dart';
import 'explore_page.dart';
import 'favorites/favorites_page.dart';
import 'home_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  void back() {
    _navigatorKey!.currentContext!.pop();
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    index = int.tryParse(appdata.settings['initialPage'].toString()) ?? 0;
    super.initState();
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: [
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
        PaneItemEntry(
          label: 'Favorites'.tl,
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Categories'.tl,
          icon: Icons.category_outlined,
          activeIcon: Icons.category,
        ),
      ],
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        if (index != 0)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        PaneActionEntry(
          icon: Icons.cloud_outlined,
          label: "NAS Library".tl,
          onTap: () {
            to(() => const NasLibraryPage(), preventDuplicate: true);
          },
        ),
        PaneActionEntry(
          icon: Icons.schedule_outlined,
          label: "Scheduled Tasks".tl,
          onTap: () {
            to(() => const SchedulerPage(), preventDuplicate: true);
          },
        ),
        PaneActionEntry(
          icon: Icons.storage_outlined,
          label: "Storage".tl,
          onTap: () {
            to(() => const StorageManagerPage(), preventDuplicate: true);
          },
        ),
        PaneActionEntry(
          icon: Icons.settings,
          label: "Settings".tl,
          onTap: () {
            to(() => const SettingsPage(), preventDuplicate: true);
          },
        ),
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}

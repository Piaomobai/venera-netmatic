import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/nas/nas_manager.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/nas_download_target_dialog.dart';
import 'package:venera/pages/nas_sync_progress.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();

  /// Groups [comics] by their source's display name.
  ///
  /// The key is the same one used for the source folder on disk
  /// ([LocalManager.sourceFolderName]), and it is derived from `comicType`
  /// rather than parsed out of `directory`. That way comics downloaded before
  /// the folder hierarchy existed still land in the correct group, and a comic
  /// whose source has since been uninstalled does not throw.
  static Map<String, List<LocalComic>> groupBySource(List<LocalComic> comics) {
    final grouped = <String, List<LocalComic>>{};
    for (final comic in comics) {
      final key = LocalManager.sourceFolderName(comic.comicType);
      grouped.putIfAbsent(key, () => <LocalComic>[]).add(comic);
    }
    // Locally imported comics come from no source; keep them last so the named
    // sources stay in a predictable alphabetical order.
    final localKey = LocalManager.sourceFolderName(ComicType.local);
    final keys = grouped.keys.toList()
      ..sort((a, b) {
        if (a == localKey) {
          return b == localKey ? 0 : 1;
        }
        if (b == localKey) {
          return -1;
        }
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return <String, List<LocalComic>>{
      for (final key in keys) key: grouped[key]!,
    };
  }
}

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  void update() {
    if (keyword.isEmpty) {
      setState(() {
        comics = LocalManager().getComics(sortType);
      });
    } else {
      setState(() {
        comics = LocalManager().search(keyword);
      });
    }
  }

  Future<void> _syncToNas() async {
    final connectionId = await selectNasConnection(context);
    if (connectionId == null) return;
    try {
      final result = await NasManager.instance.syncAll(
        connectionId,
        skipMarkedComics: true,
      );
      if (mounted) {
        context.showMessage(
          message: 'NAS sync complete: @a uploaded, @b unchanged.'.tlParams({
            'a': result.uploadedFiles.toString(),
            'b': result.skippedFiles.toString(),
          }),
        );
      }
    } catch (e, s) {
      Log.error('NAS', 'NAS sync failed: $e', s);
      if (mounted) context.showMessage(message: 'NAS sync failed: $e');
    }
  }

  Future<void> _syncComicToNas(LocalComic comic) async {
    final connectionId = await selectNasConnection(context);
    if (connectionId == null) return;
    try {
      await NasManager.instance.uploadComicDirectory(connectionId, comic);
      if (mounted) context.showMessage(message: 'Comic synced to NAS'.tl);
    } catch (e, s) {
      Log.error('NAS', 'Comic NAS sync failed: $e', s);
      if (mounted) context.showMessage(message: 'NAS sync failed: $e');
    }
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    comics = LocalManager().getComics(sortType);
    LocalManager().addListener(update);
    NasManager.instance.addListener(_nasChanged);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    NasManager.instance.removeListener(_nasChanged);
    super.dispose();
  }

  void _nasChanged() {
    if (mounted) setState(() {});
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedComics.keys.first.id,
                  sourceKey: selectedComics.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      if (NasManager.instance.connections.isNotEmpty)
        Tooltip(
          message: "Sync to NAS".tl,
          child: IconButton(
            key: const Key('local-sync-nas'),
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: NasManager.instance.isSyncing ? null : _syncToNas,
          ),
        ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          if (NasManager.instance.isSyncing &&
              NasManager.instance.progress != null)
            SliverToBoxAdapter(
              child: NasSyncProgressPanel(
                progress: NasManager.instance.progress!,
              ),
            ),
          ...buildComicSlivers(),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  /// The library grouped by comic source.
  ///
  /// Downloads are stored on disk as `<source>/<author>/<title>`; this surfaces
  /// the same grouping in the app so the hierarchy is visible while browsing.
  /// Groups are ordered by source name with locally imported comics last, and
  /// each group keeps the page's current sort order inside it.
  Iterable<Widget> buildComicSlivers() sync* {
    if (comics.isEmpty) {
      return;
    }
    final groups = LocalComicsPage.groupBySource(comics);
    var index = 0;
    for (final entry in groups.entries) {
      if (index > 0) {
        // Matches the spacing the Explore page uses between its sections.
        yield const SliverToBoxAdapter(child: Divider(height: 1));
      }
      index++;
      yield buildGroupTitle(entry.key, entry.value.length);
      yield buildGroupGrid(entry.value);
    }
  }

  /// Section header, styled to match the Explore page's part titles.
  Widget buildGroupTitle(String title, int count) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(count.toString(), style: ts.s12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One source's comics, sharing the page's selection and menu behaviour.
  Widget buildGroupGrid(List<LocalComic> items) {
    return SliverGridComics(
      comics: items,
      selections: selectedComics,
      overlayBuilder: (comic) {
        if (comic is! LocalComic) return null;
        final connections = NasManager.instance.syncedConnections(comic);
        if (connections.isEmpty) return null;
        return Tooltip(
          message: 'Synced to NAS: @a'.tlParams({
            'a': connections.map((item) => item.name).join(', '),
          }),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.toOpacity(0.92),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                Icons.cloud_done,
                size: 19,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
      },
      onLongPressed: (c, heroID) {
        setState(() {
          multiSelectMode = true;
          selectedComics[c as LocalComic] = true;
        });
      },
      onTap: (c, heroID) {
        if (multiSelectMode) {
          setState(() {
            if (selectedComics.containsKey(c as LocalComic)) {
              selectedComics.remove(c);
            } else {
              selectedComics[c] = true;
            }
            if (selectedComics.isEmpty) {
              multiSelectMode = false;
            }
          });
        } else {
          // [c] may come from a source that is no longer installed, in which
          // case its type cannot be resolved back to the stored row.
          var comic = LocalManager().find(c.id, ComicType.fromKey(c.sourceKey));
          if (comic == null) {
            context.showMessage(message: "Comic not found".tl);
            return;
          }
          comic.read();
        }
      },
      menuBuilder: (c) {
        return [
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(c as LocalComic);
            },
          ),
          MenuEntry(
            icon: Icons.cloud_upload_outlined,
            text: "Sync to NAS".tl,
            onClick: () => _syncComicToNas(c as LocalComic),
          ),
          MenuEntry(
            icon: Icons.delete,
            text: "Delete".tl,
            onClick: () {
              deleteComics([c as LocalComic]).then((value) {
                if (value && multiSelectMode) {
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                }
              });
            },
          ),
          ...exportActions([c as LocalComic]),
        ];
      },
    );
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportComics(comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          exportComics(comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          exportComics(comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }

  /// Export given comics to a file
  void exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    var current = 0;
    var cacheDir = FilePath.join(App.cachePath, 'comics_export');
    var outFile = FilePath.join(App.cachePath, 'comics_export.zip');
    bool canceled = false;
    if (Directory(cacheDir).existsSync()) {
      Directory(cacheDir).deleteSync(recursive: true);
    }
    Directory(cacheDir).createSync();
    var loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${comics.length}",
      withProgress: comics.length > 1,
      onCancel: () {
        canceled = true;
      },
    );
    try {
      var fileName = "";
      // For each comic, export it to a file
      for (var comic in comics) {
        fileName = FilePath.join(
          cacheDir,
          sanitizeFileName(comic.title, maxLength: 100) + ext,
        );
        await export(comic, fileName);
        current++;
        if (comics.length > 1) {
          loadingController.setMessage(
            "${"Exporting".tl} $current/${comics.length}",
          );
          loadingController.setProgress(current / comics.length);
        }
        if (canceled) {
          return;
        }
      }
      // For single comic, just save the file
      if (comics.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
        Directory(cacheDir).deleteSync(recursive: true);
        loadingController.close();
        return;
      }
      // For multiple comics, compress the folder
      loadingController.setProgress(null);
      loadingController.setMessage("Compressing".tl);
      await ZipFile.compressFolderAsync(cacheDir, outFile);
      if (canceled) {
        File(outFile).deleteIgnoreError();
        return;
      }
    } catch (e, s) {
      Log.error("Export Comics", e, s);
      context.showMessage(message: e.toString());
      loadingController.close();
      return;
    } finally {
      Directory(cacheDir).deleteIgnoreError(recursive: true);
    }
    await saveFile(file: File(outFile), filename: "comics_export.zip");
    loadingController.close();
    File(outFile).deleteIgnoreError();
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

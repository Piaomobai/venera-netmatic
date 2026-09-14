import 'package:flutter/material.dart';
import 'package:venera_netmatic/components/components.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/cache_manager.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/pages/local_comics_page.dart' show openComicFolder;
import 'package:venera_netmatic/pages/nas_sync_progress.dart';
import 'package:venera_netmatic/utils/io.dart';
import 'package:venera_netmatic/utils/translations.dart';

/// Local library file management.
///
/// Shows the on-disk footprint of every downloaded comic, allows searching and
/// sorting by size, deleting comics, and pruning individual chapters of one
/// comic.
///
/// Deletion goes through `LocalManager`, which already keeps the comics table,
/// the favourites entries, the read history and the files on disk consistent.
/// This page never deletes directories itself.
///
/// Directory sizes are measured with `Directory.size`, which walks the tree and
/// stats every file. That is the only helper the app provides, so the scan runs
/// asynchronously and reports progress instead of blocking the first frame.
class StorageManagerPage extends StatefulWidget {
  const StorageManagerPage({super.key});

  @override
  State<StorageManagerPage> createState() => _StorageManagerPageState();
}

enum _SortMode { size, name, time }

class _StorageManagerPageState extends State<StorageManagerPage> {
  List<LocalComic> _all = [];

  /// Directory name -> bytes on disk.
  final Map<String, int> _sizes = {};

  final Set<String> _selected = {};

  bool _scanning = false;

  bool _scanCancelled = false;

  String _query = '';

  _SortMode _sort = _SortMode.size;

  String _keyOf(LocalComic comic) => '${comic.comicType.value}@${comic.id}';

  /// `LocalManager.path` is a `late` field assigned by `LocalManager.init()`.
  /// Reading it before initialisation throws a LateInitializationError, so the
  /// page must not assume the library manager is ready.
  String _libraryPath() {
    try {
      return LocalManager().path;
    } catch (_) {
      return '(unavailable)';
    }
  }

  /// `CacheManager` derives its directory from `App.cachePath`, another `late`
  /// field assigned by `App.init()`, and its constructor scans that directory.
  /// Touching it before initialisation throws, so it is read defensively: a
  /// missing cache size must not take the whole page down.
  int _cacheSize() {
    try {
      return CacheManager().currentSize;
    } catch (_) {
      return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    NasManager.instance.addListener(_nasChanged);
    _reload();
    // Set directly rather than through setState: this runs during the build
    // phase, and the first setState inside _scanSizes happens after an await.
    _scanning = true;
    _scanSizes();
  }

  @override
  void dispose() {
    _scanCancelled = true;
    NasManager.instance.removeListener(_nasChanged);
    super.dispose();
  }

  void _nasChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _syncToNas() async {
    final manager = NasManager.instance;
    final connection =
        manager.find(manager.defaultConnectionId) ??
        (manager.connections.isEmpty ? null : manager.connections.first);
    if (connection == null) return;
    try {
      final result = await manager.syncAll(
        connection.id,
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

  void _reload() {
    try {
      _all = LocalManager().getComics(LocalSortType.timeDesc);
    } catch (e, s) {
      _all = [];
      Log.error('Storage', 'Failed to list local comics: $e', s);
    }
    _selected.removeWhere((key) => !_all.any((comic) => _keyOf(comic) == key));
  }

  Future<void> _scanSizes() async {
    for (final comic in List<LocalComic>.from(_all)) {
      if (_scanCancelled || !mounted) {
        return;
      }
      if (_sizes.containsKey(comic.directory)) {
        continue;
      }
      try {
        final bytes = await Directory(comic.baseDir).size;
        if (_scanCancelled || !mounted) {
          return;
        }
        setState(() => _sizes[comic.directory] = bytes);
      } catch (_) {
        // A comic whose folder vanished still shows in the list, just with no
        // size, so the user can delete the stale entry.
        if (mounted) {
          setState(() => _sizes[comic.directory] = 0);
        }
      }
    }
    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  int get _libraryBytes {
    var total = 0;
    for (final comic in _all) {
      total += _sizes[comic.directory] ?? 0;
    }
    return total;
  }

  List<LocalComic> get _visible {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<LocalComic>.from(_all)
        : _all.where((comic) {
            return comic.title.toLowerCase().contains(query) ||
                comic.subtitle.toLowerCase().contains(query) ||
                comic.directory.toLowerCase().contains(query) ||
                comic.tags.any((tag) => tag.toLowerCase().contains(query));
          }).toList();

    switch (_sort) {
      case _SortMode.size:
        filtered.sort((a, b) {
          final bySize = (_sizes[b.directory] ?? 0).compareTo(
            _sizes[a.directory] ?? 0,
          );
          return bySize != 0 ? bySize : a.title.compareTo(b.title);
        });
      case _SortMode.name:
        filtered.sort((a, b) => a.title.compareTo(b.title));
      case _SortMode.time:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return filtered;
  }

  List<LocalComic> get _selectedComics =>
      _all.where((comic) => _selected.contains(_keyOf(comic))).toList();

  void _toggleSelection(LocalComic comic) {
    final key = _keyOf(comic);
    setState(() {
      if (!_selected.remove(key)) {
        _selected.add(key);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final comics = _selectedComics;
    if (comics.isEmpty) {
      return;
    }
    final bytes = comics.fold<int>(
      0,
      (sum, comic) => sum + (_sizes[comic.directory] ?? 0),
    );
    await showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content: '@a comic(s) and @b will be permanently deleted.'.tlParams({
        'a': comics.length.toString(),
        'b': bytesToReadableString(bytes),
      }),
      btnColor: Theme.of(context).colorScheme.error,
      onConfirm: () {
        try {
          LocalManager().batchDeleteComics(comics);
        } catch (e, s) {
          Log.error('Storage', 'Failed to delete comics: $e', s);
        }
        setState(() {
          _selected.clear();
          _reload();
        });
      },
    );
  }

  Future<void> _confirmClearCache() async {
    await showConfirmDialog(
      context: context,
      title: 'Clear Cache'.tl,
      content:
          'The image cache will be emptied. Downloaded comics are not affected.'
              .tl,
      onConfirm: () async {
        await CacheManager().clear();
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  Future<void> _openLibraryFolder() async {
    try {
      final path = LocalManager().path;
      if (App.isWindows) {
        await Process.run('explorer', [path]);
      } else if (App.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e, s) {
      Log.error('Storage', 'Failed to open the library folder: $e', s);
      if (mounted) {
        context.showMessage(message: 'Could not open the folder'.tl);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text(
              _selected.isEmpty
                  ? 'Storage'.tl
                  : '@a selected'.tlParams({'a': _selected.length.toString()}),
            ),
            actions: [
              if (NasManager.instance.connections.isNotEmpty)
                Button.icon(
                  key: const Key('storage-sync-nas'),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'Sync to NAS'.tl,
                  isLoading: NasManager.instance.isSyncing,
                  onPressed: _syncToNas,
                ),
              if (_selected.isNotEmpty)
                Button.icon(
                  key: const Key('storage-delete'),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete'.tl,
                  color: Theme.of(context).colorScheme.error,
                  onPressed: _deleteSelected,
                )
              else
                Button.icon(
                  key: const Key('storage-sort'),
                  icon: const Icon(Icons.sort),
                  tooltip: 'Sort'.tl,
                  onPressed: _showSortMenu,
                ),
              Button.icon(
                key: const Key('storage-open-folder'),
                icon: const Icon(Icons.folder_open),
                tooltip: 'Open folder'.tl,
                onPressed: _openLibraryFolder,
              ),
            ],
          ),
          if (NasManager.instance.isSyncing &&
              NasManager.instance.progress != null)
            SliverToBoxAdapter(
              child: NasSyncProgressPanel(
                progress: NasManager.instance.progress!,
              ),
            ),
          _buildSummary(),
          if (_all.isNotEmpty) _buildSearchBar(),
          if (visible.isEmpty)
            _buildEmpty()
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final comic = visible[index];
                return _ComicStorageTile(
                  key: ValueKey(_keyOf(comic)),
                  comic: comic,
                  size: _sizes[comic.directory],
                  scanning: _scanning && !_sizes.containsKey(comic.directory),
                  selected: _selected.contains(_keyOf(comic)),
                  onToggle: () => _toggleSelection(comic),
                  onOpenFolder: () => openComicFolder(comic),
                  onManageChapters: () => _manageChapters(comic),
                  onDelete: () => _deleteOne(comic),
                );
              }, childCount: visible.length),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final cacheSize = _cacheSize();
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storage_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  '@a comic(s)'.tlParams({'a': _all.length.toString()}),
                  style: ts.s16,
                ),
                const Spacer(),
                Text(bytesToReadableString(_libraryBytes), style: ts.s16),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _scanning
                  ? 'Measuring folder sizes...'.tl
                  : 'Library location: @a'.tlParams({'a': _libraryPath()}),
              style: ts.s12,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '@a: @b'.tlParams({
                      'a': 'Image cache'.tl,
                      'b': bytesToReadableString(cacheSize),
                    }),
                    style: ts.s12,
                  ),
                ),
                Button.normal(
                  onPressed: _confirmClearCache,
                  child: Text('Clear Cache'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          key: const Key('storage-search'),
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search'.tl,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
        child: Column(
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              _all.isEmpty
                  ? 'No downloaded comics yet'.tl
                  : 'Nothing matches this search'.tl,
              style: ts.s16,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSortMenu() async {
    final labels = <String>['Size'.tl, 'Name'.tl, 'Date added'.tl];
    final index = await showSelectDialog(
      title: 'Sort'.tl,
      options: labels,
      initialIndex: _sort.index,
    );
    if (index == null) {
      return;
    }
    setState(() => _sort = _SortMode.values[index.clamp(0, 2)]);
  }

  Future<void> _deleteOne(LocalComic comic) async {
    final size = _sizes[comic.directory] ?? 0;
    await showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content:
          '"${comic.title}" ${"and @a will be permanently deleted.".tlParams({'a': bytesToReadableString(size)})}',
      btnColor: Theme.of(context).colorScheme.error,
      onConfirm: () {
        try {
          LocalManager().deleteComic(comic);
        } catch (e, s) {
          Log.error('Storage', 'Failed to delete "${comic.title}": $e', s);
        }
        setState(() => _reload());
      },
    );
  }

  Future<void> _manageChapters(LocalComic comic) async {
    final changed = await showPopUpWidget<bool?>(
      context,
      _ChapterManager(comic: comic),
    );
    if (changed == true && mounted) {
      setState(() {
        _reload();
        _sizes.remove(comic.directory);
        _scanning = true;
      });
      await _scanSizes();
    }
  }
}

/// One row of the storage list.
class _ComicStorageTile extends StatelessWidget {
  const _ComicStorageTile({
    super.key,
    required this.comic,
    required this.size,
    required this.scanning,
    required this.selected,
    required this.onToggle,
    required this.onOpenFolder,
    required this.onManageChapters,
    required this.onDelete,
  });

  final LocalComic comic;
  final int? size;
  final bool scanning;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpenFolder;
  final VoidCallback onManageChapters;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final total = comic.chapters?.length ?? 0;
    final downloaded = comic.downloadedChapters.length;
    final subtitle = StringBuffer();
    if (scanning) {
      subtitle.write('Measuring...'.tl);
    } else {
      subtitle.write(bytesToReadableString(size ?? 0));
    }
    if (total > 0) {
      subtitle.write(
        '  |  ${'@a/@b chapters'.tlParams({'a': downloaded.toString(), 'b': total.toString()})}',
      );
    } else {
      subtitle.write('  |  ${'Single file comic'.tl}');
    }
    if (comic.subtitle.isNotEmpty) {
      subtitle.write('  |  ${comic.subtitle}');
    }

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle.toString(),
        style: ts.s12,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      secondary: MenuButton(
        entries: [
          MenuEntry(
            text: 'Open folder'.tl,
            icon: Icons.folder_open,
            onClick: onOpenFolder,
          ),
          if (total > 0)
            MenuEntry(
              text: 'Manage chapters'.tl,
              icon: Icons.list_alt,
              onClick: onManageChapters,
            ),
          MenuEntry(
            text: 'Delete'.tl,
            icon: Icons.delete_outline,
            color: Theme.of(context).colorScheme.error,
            onClick: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Lists the downloaded chapters of one comic and deletes selected ones.
class _ChapterManager extends StatefulWidget {
  const _ChapterManager({required this.comic});

  final LocalComic comic;

  @override
  State<_ChapterManager> createState() => _ChapterManagerState();
}

class _ChapterManagerState extends State<_ChapterManager> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final chapters = comic.chapters;
    final downloaded = chapters == null
        ? const <String>[]
        : chapters.ids
              .where((id) => comic.downloadedChapters.contains(id))
              .toList();

    return PopUpWidgetScaffold(
      title: comic.title,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (downloaded.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No chapters are stored for this comic.'.tl),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '@a chapter(s) stored'.tlParams({
                        'a': downloaded.length.toString(),
                      }),
                      style: ts.s14,
                    ),
                  ),
                  Button.normal(
                    onPressed: () => setState(() {
                      if (_selected.length == downloaded.length) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(downloaded);
                      }
                    }),
                    child: Text('Select all'.tl),
                  ),
                ],
              ),
            ),
            for (final id in downloaded)
              CheckboxListTile(
                key: Key('chapter-$id'),
                value: _selected.contains(id),
                onChanged: (_) => setState(() {
                  if (!_selected.remove(id)) {
                    _selected.add(id);
                  }
                }),
                title: Text(
                  chapters?[id] ?? id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(id, style: ts.s12),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _selected.isEmpty
                  ? Text('Select chapters to delete'.tl, style: ts.s12)
                  : Button.filled(
                      key: const Key('chapter-delete'),
                      onPressed: _deleteSelected,
                      child: Text(
                        '@a chapter(s) will be deleted'.tlParams({
                          'a': _selected.length.toString(),
                        }),
                      ),
                    ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) {
      return;
    }
    await showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content: '@a chapter(s) will be deleted from disk.'.tlParams({
        'a': ids.length.toString(),
      }),
      btnColor: Theme.of(context).colorScheme.error,
      onConfirm: () {
        try {
          LocalManager().deleteComicChapters(widget.comic, ids);
        } catch (e, s) {
          Log.error('Storage', 'Failed to delete chapters: $e', s);
        }
        if (mounted) {
          context.pop(true);
        }
      },
    );
  }
}

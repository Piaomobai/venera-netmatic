import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/nas/nas_connection.dart';
import 'package:venera/foundation/nas/nas_library.dart';
import 'package:venera/foundation/nas/nas_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/nas_sync_progress.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

/// A browser for comics previously synchronized to a NAS, with optional local
/// import for offline reading.
class NasLibraryPage extends StatefulWidget {
  const NasLibraryPage({super.key});

  @override
  State<NasLibraryPage> createState() => _NasLibraryPageState();
}

class _NasLibraryPageState extends State<NasLibraryPage> {
  final _manager = NasManager.instance;
  List<NasLibraryComic> _comics = const [];
  String? _connectionId;
  String _query = '';
  bool _loading = false;
  Object? _error;

  NasConnection? get _connection => _manager.find(_connectionId);

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onConnectionsChanged);
    _selectInitialConnection();
    _refresh();
  }

  @override
  void dispose() {
    _manager.removeListener(_onConnectionsChanged);
    super.dispose();
  }

  void _onConnectionsChanged() {
    final current = _connection;
    if (current == null) {
      _selectInitialConnection();
      _refresh();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _selectInitialConnection() {
    final connections = _manager.connections;
    if (connections.isEmpty) {
      _connectionId = null;
      return;
    }
    _connectionId =
        _manager.find(_manager.defaultConnectionId)?.id ?? connections.first.id;
  }

  Future<void> _refresh() async {
    final connection = _connection;
    if (connection == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
          _comics = const [];
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final comics = await NasLibraryService(connection).loadComics();
      // Older builds persisted only the source hash.  The NAS index has the
      // original key (or, for legacy indexes, the source folder), so use a
      // metadata refresh to repair those local rows without forcing the user
      // to download the comic again.
      for (final comic in comics) {
        LocalManager().setOriginalSourceKey(
          comic.id,
          comic.comicType,
          comic.resolvedSourceKey,
        );
      }
      if (mounted) setState(() => _comics = comics);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openConnections() async {
    await context.to(() => const NasSettingsView());
    if (mounted) {
      _selectInitialConnection();
      await _refresh();
    }
  }

  Future<void> _fullSync() async {
    final connection = _connection;
    if (connection == null || _manager.isSyncing) return;
    try {
      final result = await _manager.syncAll(connection.id);
      if (mounted) {
        context.showMessage(
          message: 'NAS sync complete: @a uploaded, @b unchanged.'.tlParams({
            'a': result.uploadedFiles.toString(),
            'b': result.skippedFiles.toString(),
          }),
        );
        await _refresh();
      }
    } catch (e, s) {
      Log.error('NAS', 'NAS full sync failed: $e', s);
      if (mounted) context.showMessage(message: 'NAS sync failed: $e');
    }
  }

  List<NasLibraryComic> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _comics;
    return _comics.where((comic) {
      return comic.title.toLowerCase().contains(query) ||
          comic.subtitle.toLowerCase().contains(query) ||
          comic.directory.toLowerCase().contains(query) ||
          comic.tags.any((tag) => tag.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final connections = _manager.connections;
    final connection = _connection;
    final visible = _visible;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text('NAS Library'.tl),
            actions: [
              IconButton(
                key: const Key('nas-library-full-sync'),
                tooltip: 'Full sync'.tl,
                onPressed: connection == null || _manager.isSyncing
                    ? null
                    : _fullSync,
                icon: const Icon(Icons.cloud_sync_outlined),
              ),
              IconButton(
                key: const Key('nas-library-refresh'),
                tooltip: 'Refresh'.tl,
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                key: const Key('nas-library-connections'),
                tooltip: 'Manage NAS connections'.tl,
                onPressed: _openConnections,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          if (connections.isEmpty)
            _emptyConnections()
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: DropdownButtonFormField<String>(
                  initialValue: connection?.id,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: 'NAS connection'.tl,
                  ),
                  items: connections
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(
                            '${item.name} · ${item.protocol.name.toUpperCase()}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null || value == _connectionId) return;
                    setState(() => _connectionId = value);
                    _refresh();
                  },
                ),
              ),
            ),
            if (_manager.isSyncing && _manager.progress != null)
              SliverToBoxAdapter(
                child: NasSyncProgressPanel(progress: _manager.progress!),
              ),
            if (_comics.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    key: const Key('nas-library-search'),
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search'.tl,
                    ),
                  ),
                ),
              ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorState()
            else if (_comics.isEmpty)
              _emptyLibrary()
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('Nothing matches this search'.tl)),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _NasComicTile(
                      comic: visible[index],
                      service: NasLibraryService(connection!),
                    ),
                    childCount: visible.length,
                  ),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: context.width > 700 ? 240 : 180,
                    mainAxisExtent: context.width > 700 ? 330 : 280,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _emptyConnections() => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 64),
            const SizedBox(height: 16),
            Text('No NAS connections yet'.tl, style: ts.s16),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openConnections,
              icon: const Icon(Icons.add),
              label: Text('Add NAS connection'.tl),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _emptyLibrary() => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.collections_bookmark_outlined, size: 64),
            const SizedBox(height: 16),
            Text('No synchronized comics on this NAS'.tl, style: ts.s16),
            const SizedBox(height: 8),
            Text(
              'Sync your local library to this NAS, then refresh this page.'.tl,
              textAlign: TextAlign.center,
              style: ts.s12,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _errorState() => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64),
            const SizedBox(height: 16),
            Text('Could not load the NAS library'.tl, style: ts.s16),
            const SizedBox(height: 8),
            SelectableText(_error.toString(), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: Text('Retry'.tl),
            ),
          ],
        ),
      ),
    ),
  );
}

class _NasComicTile extends StatelessWidget {
  const _NasComicTile({required this.comic, required this.service});

  final NasLibraryComic comic;
  final NasLibraryService service;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.to(
          () => NasComicDetailPage(comic: comic, service: service),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: _NasCover(comic: comic, service: service),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s14,
                  ),
                  if (comic.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      comic.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s12,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NasCover extends StatelessWidget {
  const _NasCover({required this.comic, required this.service});

  final NasLibraryComic comic;
  final NasLibraryService service;

  @override
  Widget build(BuildContext context) {
    if (comic.cover.isEmpty) return _placeholder(context);
    return FutureBuilder<Uint8List?>(
      future: service.readComicFile(comic, comic.cover),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(bytes, fit: BoxFit.cover);
        }
        return _placeholder(
          context,
          loading: !snapshot.hasError && !snapshot.hasData,
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) => Center(
    child: loading
        ? const CircularProgressIndicator(strokeWidth: 2)
        : Icon(
            Icons.menu_book_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.outline,
          ),
  );
}

class NasComicDetailPage extends StatefulWidget {
  const NasComicDetailPage({
    required this.comic,
    required this.service,
    super.key,
  });

  final NasLibraryComic comic;
  final NasLibraryService service;

  @override
  State<NasComicDetailPage> createState() => _NasComicDetailPageState();
}

class _NasComicDetailPageState extends State<NasComicDetailPage> {
  bool _downloading = false;
  int _downloadedFiles = 0;
  int _totalFiles = 0;
  String? _downloadPath;

  Future<void> _downloadToLocal() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _downloadedFiles = 0;
      _totalFiles = 0;
      _downloadPath = null;
    });
    try {
      await widget.service.downloadComic(
        widget.comic,
        onProgress: (completed, total, path) {
          if (!mounted) return;
          setState(() {
            _downloadedFiles = completed;
            _totalFiles = total;
            _downloadPath = path;
          });
        },
      );
      if (mounted) {
        context.showMessage(message: 'Comic downloaded locally'.tl);
      }
    } catch (error, stack) {
      Log.error('NAS', 'Failed to download comic from NAS: $error', stack);
      if (mounted) {
        context.showMessage(
          message: 'NAS download failed: @a'.tlParams({'a': error.toString()}),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final service = widget.service;
    final chapterCount = comic.chapters?.length ?? 0;
    final storedChapters = comic.downloadedChapters.length;
    final local = LocalManager().find(comic.id, comic.comicType);
    final isCloudSynced =
        local != null &&
        NasManager.instance.isComicSynced(service.connection.id, local);
    return Scaffold(
      appBar: AppBar(title: Text(comic.title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SizedBox(
            height: 280,
            child: _NasCover(comic: comic, service: service),
          ),
          const SizedBox(height: 20),
          Text(comic.title, style: ts.s20),
          if (comic.subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(comic.subtitle, style: ts.s14),
          ],
          if (comic.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: comic.tags
                  .map((tag) => Chip(label: Text(tag)))
                  .toList(),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            comic.hasChapters
                ? '@a/@b chapters on NAS'.tlParams({
                    'a': storedChapters.toString(),
                    'b': chapterCount.toString(),
                  })
                : 'Single file comic'.tl,
            style: ts.s14,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('nas-comic-read'),
            onPressed: () => context.to(
              () => NasComicReaderPage(comic: comic, service: service),
            ),
            icon: const Icon(Icons.menu_book_outlined),
            label: Text('Read from NAS'.tl),
          ),
          const SizedBox(height: 10),
          if (isCloudSynced)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.cloud_done,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text('Downloaded locally and synced to NAS'.tl),
              subtitle: Text('This copy will be skipped by the next sync.'.tl),
            )
          else
            OutlinedButton.icon(
              key: const Key('nas-comic-download-local'),
              onPressed: _downloading ? null : _downloadToLocal,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text('Download to local'.tl),
            ),
          if (_downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _totalFiles > 0 ? _downloadedFiles / _totalFiles : null,
            ),
            const SizedBox(height: 6),
            Text(
              _totalFiles > 0
                  ? '@a/@b files · @c'.tlParams({
                      'a': _downloadedFiles.toString(),
                      'b': _totalFiles.toString(),
                      'c': _downloadPath ?? '',
                    })
                  : 'Preparing NAS download'.tl,
              style: ts.s12,
            ),
          ],
        ],
      ),
    );
  }
}

class NasComicReaderPage extends StatefulWidget {
  const NasComicReaderPage({
    required this.comic,
    required this.service,
    super.key,
  });

  final NasLibraryComic comic;
  final NasLibraryService service;

  @override
  State<NasComicReaderPage> createState() => _NasComicReaderPageState();
}

class _NasComicReaderPageState extends State<NasComicReaderPage> {
  late final NasLibrarySession _session;

  @override
  void initState() {
    super.initState();
    _session = widget.service.openSession();
  }

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final type = comic.comicType;
    final history = HistoryManager().find(comic.id, type);
    final firstChapter = _firstDownloadedChapter(comic);
    return Reader(
      type: type,
      cid: comic.id,
      name: comic.title,
      chapters: comic.chapters,
      history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
      initialChapter: history?.ep ?? firstChapter.$1,
      initialChapterGroup: history?.group ?? firstChapter.$2,
      initialPage: history?.page,
      author: comic.subtitle,
      tags: comic.tags,
      externalImageListLoader: (chapterId) =>
          _session.imagePaths(comic, chapterId: chapterId),
      externalImageBytesLoader: (imageKey) async {
        final bytes = await _session.readComicFile(comic, imageKey);
        if (bytes == null || bytes.isEmpty) {
          throw StateError('NAS image not found: $imageKey');
        }
        return bytes;
      },
      externalImageCacheKey:
          '${widget.service.connection.id}:${comic.directory}',
      onExternalReaderDispose: _session.close,
    );
  }

  (int?, int?) _firstDownloadedChapter(NasLibraryComic comic) {
    final chapters = comic.chapters;
    if (chapters == null || comic.downloadedChapters.isEmpty) {
      return (null, null);
    }
    if (!chapters.isGrouped) {
      final ids = chapters.allChapters.keys.toList();
      final index = ids.indexWhere(comic.downloadedChapters.contains);
      return (index < 0 ? null : index + 1, null);
    }
    for (var groupIndex = 0; groupIndex < chapters.groupCount; groupIndex++) {
      final ids = chapters.getGroupByIndex(groupIndex).keys.toList();
      final chapterIndex = ids.indexWhere(comic.downloadedChapters.contains);
      if (chapterIndex >= 0) return (chapterIndex + 1, groupIndex + 1);
    }
    return (null, null);
  }
}

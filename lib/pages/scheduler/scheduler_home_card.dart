import 'package:flutter/material.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/local.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/pages/scheduler/scheduler_page.dart';
import 'package:venera_netmatic/pages/storage_manager_page.dart';
import 'package:venera_netmatic/utils/translations.dart';

/// Home-page entry point for the scheduled-task queue.
///
/// Kept out of `home_page.dart` so that adding the feature only touches that
/// file by one import and one sliver entry.
///
/// IMPORTANT: this widget is placed directly in `HomePage`'s `slivers:` list, so
/// it must BE a sliver. Returning a plain box (a `Column`, a `Card`) throws at
/// runtime with "A RenderViewport expected a child of type RenderSliver but
/// received a child of type RenderFlex" -- an error that `flutter analyze`
/// cannot see, because both are perfectly valid `Widget`s. Anything added here
/// must be wrapped in `SliverToBoxAdapter` (or be a sliver itself).
class SchedulerHomeCard extends StatefulWidget {
  const SchedulerHomeCard({super.key});

  @override
  State<SchedulerHomeCard> createState() => _SchedulerHomeCardState();
}

class _SchedulerHomeCardState extends State<SchedulerHomeCard> {
  SchedulerEngine get engine => SchedulerEngine();

  @override
  void initState() {
    super.initState();
    engine.addListener(_onChanged);
  }

  @override
  void dispose() {
    engine.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = engine.tasks;
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionHeader(
            title: 'Scheduled Tasks'.tl,
            badge: tasks.isEmpty
                ? null
                : '@a/@b'.tlParams({
                    'a': engine.enabledCount.toString(),
                    'b': tasks.length.toString(),
                  }),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.to(() => const SchedulerPage()),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.schedule_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_summary(tasks.length), style: ts.s14),
                        if (engine.isExecuting) ...[
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: engine.activeProgress),
                          if (engine.activeMessage != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              engine.activeMessage!,
                              style: ts.s12,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ] else if (engine.nextScheduledRun != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Next run: @a'.tlParams({
                              'a': formatRelative(engine.nextScheduledRun!),
                            }),
                            style: ts.s12,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_right),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _summary(int count) {
    if (count == 0) {
      return 'No scheduled tasks yet'.tl;
    }
    if (engine.isExecuting) {
      final active = engine.activeTaskId == null
          ? null
          : engine.findTask(engine.activeTaskId!);
      return 'Running: @a'.tlParams({'a': active?.name ?? ''});
    }
    return '@a task(s) configured'.tlParams({'a': count.toString()});
  }
}

/// Home-page entry point for local file management.
///
/// Must return a sliver for the same reason as [SchedulerHomeCard].
class StorageHomeCard extends StatelessWidget {
  const StorageHomeCard({super.key});

  @override
  Widget build(BuildContext context) {
    int count;
    try {
      count = LocalManager().count;
    } catch (_) {
      // LocalManager is not initialised until App.initComponents() completes.
      count = 0;
    }
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionHeader(title: 'Storage'.tl, badge: null),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.to(() => const StorageManagerPage()),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.storage_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      count == 0
                          ? 'No downloaded comics yet'.tl
                          : '@a comic(s) downloaded'
                              .tlParams({'a': count.toString()}),
                      style: ts.s14,
                    ),
                  ),
                  const Icon(Icons.arrow_right),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header row matching the style of the existing home-page sections.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.badge});

  final String title;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Center(child: Text(title, style: ts.s18)),
          if (badge != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(badge!, style: ts.s12),
            ),
          const Spacer(),
          const Icon(Icons.arrow_right),
        ],
      ),
    ).paddingHorizontal(16);
  }
}

import 'package:flutter/material.dart';
import 'package:venera_netmatic/components/components.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/incremental_download.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/nas_sync.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';
import 'package:venera_netmatic/pages/scheduler/task_editor_page.dart';
import 'package:venera_netmatic/utils/translations.dart';

/// The visual scheduled-task queue.
///
/// Shows every configured task with its schedule, next run, last outcome and
/// live progress, and allows creating, editing, enabling, running, stopping and
/// deleting tasks.
///
/// A task only ever runs while the app is running: the engine is driven by an
/// in-process timer, so there is no background service. Use the headless CLI
/// (`venera --headless scheduler rundue`) to run due tasks without the GUI.
class SchedulerPage extends StatefulWidget {
  const SchedulerPage({super.key});

  @override
  State<SchedulerPage> createState() => _SchedulerPageState();
}

class _SchedulerPageState extends State<SchedulerPage> {
  SchedulerEngine get engine => SchedulerEngine();

  @override
  void initState() {
    super.initState();
    engine.addListener(_onEngineChanged);
  }

  @override
  void dispose() {
    engine.removeListener(_onEngineChanged);
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _createTask() async {
    final created = await App.rootContext.to<TaskDefinition>(
      () => const TaskEditorPage(),
    );
    if (created != null && mounted) {
      context.showMessage(message: '"${created.name}" ${"created".tl}');
    }
  }

  Future<void> _editTask(TaskDefinition task) async {
    await App.rootContext.to<TaskDefinition>(
      () => TaskEditorPage(existing: task),
    );
    _onEngineChanged();
  }

  Future<void> _confirmDelete(TaskDefinition task) async {
    await showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content: '"${task.name}" ${"and its run history will be removed.".tl}',
      btnColor: Theme.of(context).colorScheme.error,
      onConfirm: () {
        engine.deleteTask(task.id);
        _onEngineChanged();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = engine.tasks;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Scheduled Tasks'.tl),
            actions: [
              if (engine.isExecuting)
                Button.icon(
                  key: const Key('scheduler-stop'),
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: 'Stop'.tl,
                  // Button.icon takes a non-nullable VoidCallback, so the
                  // already-requested case is guarded inside the callback
                  // rather than by passing null.
                  onPressed: () {
                    if (!engine.isCancelRequested) {
                      engine.requestCancel();
                    }
                  },
                ),
              Button.icon(
                key: const Key('scheduler-refresh'),
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'.tl,
                onPressed: _onEngineChanged,
              ),
              Button.icon(
                key: const Key('scheduler-create'),
                icon: const Icon(Icons.add),
                tooltip: 'New Task'.tl,
                onPressed: _createTask,
              ),
            ],
          ),
          if (!engine.isStarted) _buildNotStarted(),
          _buildStatusCard(),
          if (tasks.isEmpty)
            _buildEmpty()
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final task = tasks[index];
                return _TaskTile(
                  key: ValueKey(task.id),
                  task: task,
                  isActive: engine.activeTaskId == task.id,
                  onToggle: (value) => engine.setEnabled(task.id, value),
                  onRunNow: () => engine.runNow(task.id),
                  onEdit: () => _editTask(task),
                  onHistory: () => _showHistory(task),
                  onDelete: () => _confirmDelete(task),
                );
              }, childCount: tasks.length),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }

  Widget _buildNotStarted() {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'The scheduler is not running. It starts automatically with the app.'
                    .tl,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final active = engine.activeTaskId == null
        ? null
        : engine.findTask(engine.activeTaskId!);
    final nextRun = engine.nextScheduledRun;

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
                Icon(
                  engine.isExecuting
                      ? Icons.play_circle_outline
                      : Icons.pause_circle_outline,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    engine.isExecuting
                        ? 'Running: @a'.tlParams({'a': active?.name ?? ''})
                        : 'Idle',
                    style: ts.s16,
                  ),
                ),
                Text(
                  '@a of @b enabled'.tlParams({
                    'a': engine.enabledCount.toString(),
                    'b': engine.tasks.length.toString(),
                  }),
                  style: ts.s12,
                ),
              ],
            ),
            if (engine.isExecuting) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: engine.activeProgress),
              if (engine.activeMessage != null) ...[
                const SizedBox(height: 6),
                Text(engine.activeMessage!, style: ts.s12),
              ],
            ] else if (nextRun != null) ...[
              const SizedBox(height: 6),
              Text(
                'Next run: @a'.tlParams({'a': formatRelative(nextRun)}),
                style: ts.s12,
              ),
            ],
          ],
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
              Icons.schedule_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No scheduled tasks yet'.tl,
              style: ts.s16,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Create a task to periodically scan rankings or download new chapters.'
                  .tl,
              style: ts.s12,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Button.filled(onPressed: _createTask, child: Text('New Task'.tl)),
          ],
        ),
      ),
    );
  }

  void _showHistory(TaskDefinition task) {
    showPopUpWidget(
      context,
      _RunHistoryView(taskId: task.id, taskName: task.name),
    );
  }
}

/// A single row in the task queue.
class _TaskTile extends StatelessWidget {
  const _TaskTile({
    super.key,
    required this.task,
    required this.isActive,
    required this.onToggle,
    required this.onRunNow,
    required this.onEdit,
    required this.onHistory,
    required this.onDelete,
  });

  final TaskDefinition task;
  final bool isActive;
  final void Function(bool value) onToggle;
  final VoidCallback onRunNow;
  final VoidCallback onEdit;
  final VoidCallback onHistory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final runner = TaskRunnerRegistry.find(task.typeKey);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(iconForTaskType(task.typeKey), size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              task.name,
                              style: ts.s16,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '@a | @b'.tlParams({
                          'a': runner?.displayName ?? task.typeKey,
                          'b': task.schedule.description.tl,
                        }),
                        style: ts.s12,
                        maxLines: 2,
                      ),
                      const SizedBox(height: 2),
                      Text(_scheduleSummary(task), style: ts.s12, maxLines: 2),
                    ],
                  ),
                ),
                Switch(value: task.enabled, onChanged: onToggle),
                MenuButton(
                  entries: [
                    MenuEntry(
                      text: 'Run now'.tl,
                      icon: Icons.play_arrow,
                      onClick: onRunNow,
                    ),
                    MenuEntry(
                      text: 'Edit'.tl,
                      icon: Icons.edit_outlined,
                      onClick: onEdit,
                    ),
                    MenuEntry(
                      text: 'Run history'.tl,
                      icon: Icons.history,
                      onClick: onHistory,
                    ),
                    MenuEntry(
                      text: 'Delete'.tl,
                      icon: Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                      onClick: onDelete,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _StateChip(state: task.lastState),
                const SizedBox(width: 8),
                if (task.lastSummary != null)
                  Flexible(
                    child: Text(
                      _summaryText(task.lastSummary!),
                      style: ts.s12,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            if (task.lastError != null) ...[
              const SizedBox(height: 4),
              Text(
                task.lastError!,
                style: ts.s12.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _scheduleSummary(TaskDefinition task) {
    final buffer = StringBuffer();
    final lastRun = task.lastRunAt;
    if (lastRun == null) {
      buffer.write('Never run'.tl);
    } else {
      buffer.write(
        'Last run: @a'.tlParams({'a': formatRelative(lastRun, past: true)}),
      );
      if (task.enabled && task.nextRunAt != null) {
        buffer.write(
          '  |  ${'Next: @a'.tlParams({'a': formatRelative(task.nextRunAt!)})}',
        );
      }
    }
    if (task.runOnStart) {
      buffer.write('  |  ${'Runs on app start'.tl}');
    }
    if (task.consecutiveFailures > 0) {
      buffer.write(
        '  |  ${'@a consecutive failure(s)'.tlParams({'a': task.consecutiveFailures.toString()})}',
      );
    }
    return buffer.toString();
  }

  static String _summaryText(Map<String, dynamic> summary) {
    final parts = <String>[];
    for (final entry in summary.entries) {
      final value = entry.value;
      if (value is num && value != 0) {
        parts.add('${entry.key}: $value');
      }
    }
    return parts.join(', ');
  }
}

/// Compact coloured label for a run state.
class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final TaskRunState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color background, Color foreground) = switch (state) {
      TaskRunState.never => (
        'Never run'.tl,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      TaskRunState.running => (
        'Running'.tl,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      TaskRunState.success => (
        'Success'.tl,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      TaskRunState.failed => (
        'Failed'.tl,
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      TaskRunState.cancelled => (
        'Cancelled'.tl,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      TaskRunState.skipped => (
        'Skipped'.tl,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: ts.s12.copyWith(color: foreground)),
    );
  }
}

/// Run history for one task, shown as a pop-up.
class _RunHistoryView extends StatefulWidget {
  const _RunHistoryView({required this.taskId, required this.taskName});

  final String taskId;
  final String taskName;

  @override
  State<_RunHistoryView> createState() => _RunHistoryViewState();
}

class _RunHistoryViewState extends State<_RunHistoryView> {
  @override
  Widget build(BuildContext context) {
    final runs = SchedulerEngine().runsFor(widget.taskId, limit: 50);
    final logs = SchedulerEngine().logFor(widget.taskId);
    return PopUpWidgetScaffold(
      title: widget.taskName,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (runs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No runs recorded yet'.tl, style: ts.s14),
            )
          else
            ...runs.map((run) => _RunTile(run: run)),
          if (logs.isNotEmpty) ...[
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Recent log'.tl, style: ts.s16),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                logs.reversed.take(50).join('\n'),
                style: ts.s12.copyWith(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run});

  final TaskRunRecord run;

  @override
  Widget build(BuildContext context) {
    final duration = run.duration;
    return ListTile(
      leading: _StateChip(state: run.state),
      title: Text(formatAbsolute(run.startedAt), style: ts.s14),
      subtitle: Text(
        [
          if (duration != null) '${duration.inSeconds}s',
          if (run.message != null) run.message!,
          if (run.error != null) run.error!,
        ].join('  |  '),
        style: ts.s12,
        maxLines: 3,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Shared formatting helpers, also used by the task editor.
// -----------------------------------------------------------------------------

/// Icon shown for a task type. Kept here so runners stay free of Flutter types.
IconData iconForTaskType(String typeKey) {
  switch (typeKey) {
    case RankingMonitorRunner.key:
      return Icons.leaderboard_outlined;
    case IncrementalDownloadRunner.key:
      return Icons.download_for_offline_outlined;
    case NasSyncRunner.key:
      return Icons.cloud_sync_outlined;
    default:
      return Icons.schedule_outlined;
  }
}

/// `in 5 minutes` / `3 hours ago`, falling back to an absolute date further out.
String formatRelative(DateTime time, {bool past = false}) {
  final now = DateTime.now();
  var delta = time.difference(now);
  if (past) {
    delta = now.difference(time);
  }
  final isPast = delta.isNegative;
  final magnitude = delta.abs();

  String value;
  if (magnitude.inSeconds < 60) {
    value = 'less than a minute';
  } else if (magnitude.inMinutes < 60) {
    final n = magnitude.inMinutes;
    value = '$n minute${n == 1 ? '' : 's'}';
  } else if (magnitude.inHours < 24) {
    final n = magnitude.inHours;
    value = '$n hour${n == 1 ? '' : 's'}';
  } else if (magnitude.inDays < 7) {
    final n = magnitude.inDays;
    value = '$n day${n == 1 ? '' : 's'}';
  } else {
    return formatAbsolute(time);
  }

  if (isPast || past) {
    return '$value ago';
  }
  return 'in $value';
}

/// `2025-01-01 03:30`.
String formatAbsolute(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

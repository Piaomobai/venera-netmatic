import 'package:flutter/material.dart';
import 'package:venera_netmatic/components/components.dart';
import 'package:venera_netmatic/foundation/app.dart';
import 'package:venera_netmatic/foundation/favorites.dart';
import 'package:venera_netmatic/foundation/log.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/foundation/scheduler/cron.dart';
import 'package:venera_netmatic/foundation/scheduler/engine.dart';
import 'package:venera_netmatic/foundation/scheduler/schedule.dart';
import 'package:venera_netmatic/foundation/scheduler/store.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/incremental_download.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/nas_sync.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';
import 'package:venera_netmatic/utils/translations.dart';

/// Creates or edits one scheduled task.
///
/// Pops with the saved [TaskDefinition], or null when cancelled.
///
/// The runner-specific options are laid out with an explicit switch on
/// `typeKey` rather than a generic schema interpreter. With a few task types
/// that is less machinery and fewer places to get a type wrong; adding a runner
/// means adding a branch here.
class TaskEditorPage extends StatefulWidget {
  const TaskEditorPage({super.key, this.existing});

  /// The task being edited, or null when creating a new one.
  final TaskDefinition? existing;

  @override
  State<TaskEditorPage> createState() => _TaskEditorPageState();
}

class _TaskEditorPageState extends State<TaskEditorPage> {
  final _controllers = <String, TextEditingController>{};

  late String _typeKey;
  late ScheduleType _scheduleType;
  late bool _enabled;
  late int _hour;
  late int _minute;
  late int _dayOfMonth;
  late int _maxAttempts;
  late bool _runOnStart;
  late Set<int> _weekdays;
  late Set<String> _selectedSources;
  late Map<String, Set<String>> _selectedRankingOptions;
  late bool _rankingOptionsEdited;
  late bool _autoFavorite;
  late bool _autoDownload;
  late String _scope;
  String? _nasConnectionId;

  String? _error;

  bool get _isEditing => widget.existing != null;

  static const _weekdayLabels = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _typeKey = existing?.typeKey ?? RankingMonitorRunner.key;
    _enabled = existing?.enabled ?? true;
    _runOnStart = existing?.runOnStart ?? false;
    _maxAttempts = existing?.retry.maxAttempts ?? 1;

    // Only the friendly presets round-trip through the editor; a raw cron
    // expression is represented as ScheduleType.cron directly.
    final schedule = existing?.schedule;
    _scheduleType = schedule?.type ?? ScheduleType.interval;
    _hour = schedule?.hour ?? 3;
    _minute = schedule?.minute ?? 0;
    _dayOfMonth = schedule?.dayOfMonth ?? 1;
    _weekdays = (schedule?.weekdays ?? const <int>[]).toSet();
    // For a new task this stays empty: switching the schedule type to Weekly
    // deliberately requires an explicit day selection rather than silently
    // defaulting to one, and _buildSchedule returns null until a day is picked.
    // An existing weekly task always carries at least one day, because
    // ScheduleSpec.weekly rejects an empty list.

    _selectedSources = _stringListConfig('sources').toSet();
    _selectedRankingOptions = _rankingOptionsConfig();
    _rankingOptionsEdited = false;
    _autoFavorite = _boolConfig('autoFavorite');
    _autoDownload = _boolConfig('autoDownload');
    _scope = _stringConfig('scope', IncrementalDownloadRunner.scopeFavorites);
    _nasConnectionId = _config('nasConnectionId') as String?;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Config helpers
  // ---------------------------------------------------------------------------

  Object? _config(String key) => widget.existing?.config[key];

  int _intConfig(String key, int fallback) {
    final value = _config(key);
    return value is num ? value.toInt() : fallback;
  }

  String _stringConfig(String key, String fallback) {
    final value = _config(key);
    return value is String ? value : fallback;
  }

  bool _boolConfig(String key) {
    final value = _config(key);
    return value is bool && value;
  }

  /// How many comics the ranking monitor has already recorded as seen for
  /// [sourceKey]. 0 while the store is not open, which is the case when the
  /// editor is used to create the very first task.
  int _rememberedCount(String sourceKey) {
    final store = SchedulerStore();
    if (!store.isOpen) {
      return 0;
    }
    try {
      return store.countSeen(RankingMonitorRunner.seenNamespace(sourceKey));
    } catch (e) {
      return 0;
    }
  }

  /// Forgets every comic recorded as seen for the selected sources.
  ///
  /// This is the only way back from a scan that ran before auto-download was
  /// enabled. The scanner records *every* comic it lists, whether or not any
  /// follow-up action is on, so without a reset the whole ranking stays
  /// "already seen" and nothing is ever queued.
  void _forgetRemembered() {
    final store = SchedulerStore();
    if (!store.isOpen) {
      return;
    }
    var cleared = 0;
    for (final sourceKey in _selectedSources) {
      final namespace = RankingMonitorRunner.seenNamespace(sourceKey);
      try {
        cleared += store.countSeen(namespace);
        store.clearSeen(namespace);
      } catch (e) {
        Log.error('Scheduler', 'Failed to clear remembered items: $e');
      }
    }
    setState(() {});
    // The page's own context, not App.rootContext: the latter asserts on a live
    // root navigator, which this page does not need and tests do not have.
    // Not interpolated either -- the count is in the row's subtitle, and an
    // interpolated string could never match a translation key.
    context.showMessage(
      message: cleared == 0
          ? 'Nothing to forget'.tl
          : 'Remembered comics cleared'.tl,
    );
  }

  List<String> _stringListConfig(String key) {
    final value = _config(key);
    if (value is List) {
      return value.whereType<String>().toList();
    }
    return <String>[];
  }

  Map<String, Set<String>> _rankingOptionsConfig() {
    final configured = RankingMonitorRunner.configuredOptionsBySource(
      widget.existing?.config ?? const <String, dynamic>{},
    );
    return <String, Set<String>>{
      for (final entry in configured.entries) entry.key: entry.value.toSet(),
    };
  }

  void _toggleRankingOption(String sourceKey, String optionKey) {
    final selected = _selectedRankingOptions.putIfAbsent(
      sourceKey,
      () => <String>{},
    );
    if (!selected.remove(optionKey)) {
      selected.add(optionKey);
    }
    if (selected.isEmpty) {
      _selectedRankingOptions.remove(sourceKey);
    }
    _rankingOptionsEdited = true;
    setState(() {});
  }

  TextEditingController _controller(String key, String initial) =>
      _controllers.putIfAbsent(key, () => TextEditingController(text: initial));

  int _intValue(String key, int fallback) {
    final text = _controller(key, fallback.toString()).text.trim();
    final parsed = int.tryParse(text);
    return parsed ?? fallback;
  }

  String _textValue(String key, String fallback) =>
      _controller(key, fallback).text.trim();

  /// The interval of the task being edited.
  ///
  /// The interval lives in the schedule, not in the runner config, so reading
  /// it from `config` would silently reset an existing task to the default.
  int _intervalMinutesInitial() {
    final schedule = widget.existing?.schedule;
    if (schedule != null && schedule.type == ScheduleType.interval) {
      return schedule.interval!.inMinutes;
    }
    return 30;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final runner = TaskRunnerRegistry.find(_typeKey);
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text(_isEditing ? 'Edit Task'.tl : 'New Task'.tl),
          ),
          _section('Type'.tl, Icons.category_outlined),
          _wrap([
            for (final candidate in TaskRunnerRegistry.all())
              OptionChip(
                key: Key('type-${candidate.typeKey}'),
                text: candidate.displayName.tl,
                isSelected: candidate.typeKey == _typeKey,
                onTap: _isEditing
                    ? () {}
                    : () => setState(() {
                        _typeKey = candidate.typeKey;
                        _error = null;
                      }),
              ),
          ]),
          if (runner != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(runner.description.tl, style: ts.s12),
              ),
            ),
          if (_isEditing)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'The task type cannot be changed after creation.'.tl,
                  style: ts.s12,
                ),
              ),
            ),

          _section('Name'.tl, Icons.label_outline),
          _field(
            'name',
            widget.existing?.name ?? runner?.displayName ?? 'Task',
            label: 'Name'.tl,
          ),

          _section('Schedule'.tl, Icons.schedule_outlined),
          _wrap([
            for (final type in ScheduleType.values)
              OptionChip(
                key: Key('schedule-${type.name}'),
                text: _scheduleTypeLabel(type).tl,
                isSelected: type == _scheduleType,
                onTap: () => setState(() {
                  _scheduleType = type;
                  _error = null;
                }),
              ),
          ]),
          ..._scheduleEditors(),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_schedulePreview(), style: ts.s12),
            ),
          ),

          ..._runnerOptions(),

          _section('Retry'.tl, Icons.replay),
          _select(
            'Maximum attempts'.tl,
            List.generate(5, (i) => (i + 1).toString()),
            (_maxAttempts - 1).clamp(0, 4),
            (index) => setState(() => _maxAttempts = index + 1),
          ),
          SliverToBoxAdapter(
            child: SwitchListTile(
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
              title: Text('Enabled'.tl),
            ),
          ),
          SliverToBoxAdapter(
            child: SwitchListTile(
              key: const Key('task-run-on-start'),
              value: _runOnStart,
              onChanged: (value) => setState(() => _runOnStart = value),
              title: Text('Run when the app starts'.tl),
              subtitle: Text(
                'The scheduler only runs while the app is open, so a long '
                        'interval can pass without ever firing. This runs the '
                        'task shortly after every start, in addition to its '
                        'normal schedule.'
                    .tl,
              ),
            ),
          ),

          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  _error!,
                  style: ts.s14.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Button.outlined(
                      onPressed: () => context.pop(),
                      child: Text('Cancel'.tl),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Button.filled(
                      key: const Key('task-save'),
                      onPressed: _save,
                      child: Text(_isEditing ? 'Save'.tl : 'Create'.tl),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Schedule editors
  // ---------------------------------------------------------------------------

  List<Widget> _scheduleEditors() {
    switch (_scheduleType) {
      case ScheduleType.interval:
        return [
          _field(
            'intervalMinutes',
            _intervalMinutesInitial().toString(),
            label: 'Interval (minutes)'.tl,
            helper: 'Minimum 5 minutes.'.tl,
            number: true,
          ),
        ];
      case ScheduleType.daily:
        return [_timePickers()];
      case ScheduleType.weekly:
        return [
          _wrap([
            for (var day = 0; day < 7; day++)
              OptionChip(
                key: Key('weekday-$day'),
                text: _weekdayLabels[day],
                isSelected: _weekdays.contains(day),
                onTap: () => setState(() {
                  if (!_weekdays.remove(day)) {
                    _weekdays.add(day);
                  }
                  _error = null;
                }),
              ),
          ]),
          _timePickers(),
        ];
      case ScheduleType.monthly:
        return [
          _select(
            'Day of month'.tl,
            List.generate(31, (i) => (i + 1).toString()),
            (_dayOfMonth - 1).clamp(0, 30),
            (index) => setState(() => _dayOfMonth = index + 1),
          ),
          _timePickers(),
        ];
      case ScheduleType.cron:
        return [
          _field(
            'cron',
            widget.existing?.schedule.cronExpression ?? '0 3 * * *',
            label: 'Cron expression'.tl,
            // Parenthesised so `.tl` applies to the whole concatenated string.
            // Without the parentheses, `.tl` binds only to the second literal
            // and the helper renders as mixed-language text.
            helper:
                ('Five fields: minute hour day-of-month month day-of-week. '
                        'e.g. 0 3 * * *  or  */30 * * * *')
                    .tl,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _cronFeedback(),
            ),
          ),
        ];
    }
  }

  Widget _timePickers() {
    final hours = List.generate(24, (i) => i.toString().padLeft(2, '0'));
    final minutes = List.generate(
      12,
      (i) => (i * 5).toString().padLeft(2, '0'),
    );
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            Text('Time'.tl, style: ts.s14),
            const SizedBox(width: 16),
            Select(
              current: hours[_hour.clamp(0, 23)],
              values: hours,
              onTap: (index) => setState(() => _hour = index),
            ),
            const SizedBox(width: 8),
            Select(
              // Minutes are offered at five-minute granularity; the nearest
              // option is shown if a stored value falls between them.
              current: minutes[(_minute ~/ 5).clamp(0, 11)],
              values: minutes,
              onTap: (index) => setState(() => _minute = index * 5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cronFeedback() {
    final text = _controller('cron', '0 3 * * *').text.trim();
    if (text.isEmpty) {
      return Text('Enter a cron expression.'.tl, style: ts.s12);
    }
    final parsed = CronExpression.tryParse(text);
    if (parsed == null) {
      return Text(
        'Invalid cron expression'.tl,
        style: ts.s12.copyWith(color: Theme.of(context).colorScheme.error),
      );
    }
    final next = parsed.next(DateTime.now());
    if (next == null) {
      return Text(
        'This expression never matches a date in the next 8 years.'.tl,
        style: ts.s12.copyWith(color: Theme.of(context).colorScheme.error),
      );
    }
    return Text('Next run: @a'.tlParams({'a': next.toString()}), style: ts.s12);
  }

  String _scheduleTypeLabel(ScheduleType type) {
    switch (type) {
      case ScheduleType.interval:
        return 'Interval';
      case ScheduleType.daily:
        return 'Daily';
      case ScheduleType.weekly:
        return 'Weekly';
      case ScheduleType.monthly:
        return 'Monthly';
      case ScheduleType.cron:
        return 'Cron';
    }
  }

  String _schedulePreview() {
    final schedule = _buildSchedule();
    if (schedule == null) {
      return 'Complete the schedule to continue.'.tl;
    }
    final next = schedule.nextAfter(DateTime.now());
    if (next == null) {
      return schedule.description;
    }
    return '@a  |  @b'.tlParams({
      'a': schedule.description,
      'b': 'next ${next.toString().split('.').first}',
    });
  }

  // ---------------------------------------------------------------------------
  // Runner-specific options
  // ---------------------------------------------------------------------------

  List<Widget> _runnerOptions() {
    switch (_typeKey) {
      case RankingMonitorRunner.key:
        return _rankingOptions();
      case IncrementalDownloadRunner.key:
        return _downloadOptions();
      case NasSyncRunner.key:
        return _nasSyncOptions();
      default:
        return const [];
    }
  }

  List<Widget> _rankingOptions() {
    final sources = RankingMonitorRunner.rankingCapableSources();
    return [
      _section('Sources'.tl, Icons.public),
      if (sources.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
              'No installed comic source exposes a ranking list.'.tl,
              style: ts.s12,
            ),
          ),
        )
      else ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
              'Leave all unselected to scan every source.'.tl,
              style: ts.s12,
            ),
          ),
        ),
        _wrap([
          for (final source in sources)
            OptionChip(
              key: Key('source-${source.key}'),
              text: source.name,
              isSelected: _selectedSources.contains(source.key),
              onTap: () => setState(() {
                if (!_selectedSources.remove(source.key)) {
                  _selectedSources.add(source.key);
                }
              }),
            ),
        ]),
      ],
      if (sources.isNotEmpty) ...[
        _section('Ranking options'.tl, Icons.list_alt_outlined),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Choose rankings separately for each source. Leave all options '
                      'unselected to use the first option.'
                  .tl,
              style: ts.s12,
            ),
          ),
        ),
        for (final source
            in (_selectedSources.isEmpty
                ? sources
                : sources.where(
                    (source) => _selectedSources.contains(source.key),
                  ))) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(source.name, style: ts.s14),
            ),
          ),
          _wrap([
            for (final option
                in source.categoryComicsData!.rankingData!.options.entries)
              OptionChip(
                key: Key('ranking-option-${source.key}-${option.key}'),
                text: option.value,
                isSelected:
                    _selectedRankingOptions[source.key]?.contains(option.key) ??
                    false,
                onTap: () => _toggleRankingOption(source.key, option.key),
              ),
          ]),
        ],
      ],
      _section('Options'.tl, Icons.tune),
      _field(
        'pagesPerOption',
        _intConfig('pagesPerOption', 1).toString(),
        label: 'Pages per ranking option'.tl,
        number: true,
      ),
      _field(
        'maxNewPerRun',
        _intConfig('maxNewPerRun', 50).toString(),
        label: 'Maximum new comics per run'.tl,
        helper:
            'Detected comics beyond this limit are not processed further.'.tl,
        number: true,
      ),
      _field(
        'throttleMs',
        _intConfig('throttleMs', 300).toString(),
        label: 'Delay between requests (ms)'.tl,
        number: true,
      ),
      _field(
        'forgetAfterDays',
        _intConfig('forgetAfterDays', 90).toString(),
        label: 'Forget ids after (days, 0 = never)'.tl,
        number: true,
      ),
      _section('Follow-up actions'.tl, Icons.download_done_outlined),
      SliverToBoxAdapter(
        child: SwitchListTile(
          value: _autoFavorite,
          onChanged: (value) => setState(() => _autoFavorite = value),
          title: Text('Add new comics to favourites'.tl),
        ),
      ),
      if (_autoFavorite) _favoriteFolderField(),
      SliverToBoxAdapter(
        child: SwitchListTile(
          value: _autoDownload,
          onChanged: (value) => setState(() => _autoDownload = value),
          title: Text('Download new comics automatically'.tl),
          subtitle: Text('Only missing chapters are fetched.'.tl),
        ),
      ),
      if (_autoDownload) _nasTargetField(),
      SliverToBoxAdapter(child: _rememberedRow()),
    ];
  }

  /// Lets the user reset what the ranking monitor remembers.
  ///
  /// Without this, a task that ran once before auto-download was enabled is
  /// permanently stuck at "0 new": the scan marked the entire ranking as seen.
  Widget _rememberedRow() {
    final counts = <String, int>{
      for (final sourceKey in _selectedSources)
        sourceKey: _rememberedCount(sourceKey),
    };
    final total = counts.values.fold<int>(0, (sum, value) => sum + value);
    return ListTile(
      title: Text('Remembered comics'.tl),
      subtitle: Text(
        'Comics this task already reported. Forget them to download them again.'
                .tl +
            (counts.isEmpty
                ? ''
                : '\n$total  ·  '
                      '${counts.entries.map((e) => '${e.key}: ${e.value}').join('   ')}'),
      ),
      trailing: TextButton(
        onPressed: total == 0 ? null : _forgetRemembered,
        child: Text('Forget'.tl),
      ),
    );
  }

  List<Widget> _downloadOptions() {
    return [
      _section('Scope'.tl, Icons.folder_outlined),
      _select(
        'Which comics to check'.tl,
        [
          IncrementalDownloadRunner.scopeFavorites,
          IncrementalDownloadRunner.scopeLibrary,
        ],
        _scope == IncrementalDownloadRunner.scopeLibrary ? 1 : 0,
        (index) => setState(() {
          _scope = index == 1
              ? IncrementalDownloadRunner.scopeLibrary
              : IncrementalDownloadRunner.scopeFavorites;
        }),
      ),
      if (_scope == IncrementalDownloadRunner.scopeFavorites)
        _favoriteFolderField(),
      _section('Options'.tl, Icons.tune),
      _field(
        'maxComicsPerRun',
        _intConfig('maxComicsPerRun', 20).toString(),
        label: 'Maximum comics per run'.tl,
        number: true,
      ),
      _field(
        'maxChaptersPerComic',
        _intConfig('maxChaptersPerComic', 0).toString(),
        label: 'Maximum chapters per comic (0 = no limit)'.tl,
        number: true,
      ),
      _field(
        'throttleMs',
        _intConfig('throttleMs', 300).toString(),
        label: 'Delay between requests (ms)'.tl,
        number: true,
      ),
      _nasTargetField(),
    ];
  }

  List<Widget> _nasSyncOptions() {
    return [
      _section('NAS connection'.tl, Icons.cloud_sync_outlined),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            'Select a NAS connection for scheduled synchronization.'.tl,
            style: ts.s12,
          ),
        ),
      ),
      _nasTargetField(nasOnly: true),
    ];
  }

  Widget _nasTargetField({bool nasOnly = false}) {
    final connections = NasManager.instance.connections;
    if (_nasConnectionId != null &&
        !connections.any((item) => item.id == _nasConnectionId)) {
      _nasConnectionId = null;
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: DropdownButtonFormField<String>(
          initialValue: _nasConnectionId ?? (nasOnly ? null : ''),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: (nasOnly ? 'NAS connection' : 'Download destination').tl,
            helperText: nasOnly && connections.isEmpty
                ? 'No NAS connections yet'.tl
                : null,
          ),
          items: [
            if (!nasOnly)
              DropdownMenuItem<String>(
                value: '',
                child: Text('Local storage'.tl),
              ),
            for (final connection in connections)
              DropdownMenuItem<String>(
                value: connection.id,
                child: Text(connection.name),
              ),
          ],
          onChanged: (value) => setState(
            () => _nasConnectionId = value == null || value.isEmpty
                ? null
                : value,
          ),
        ),
      ),
    );
  }

  Widget _favoriteFolderField() {
    var folders = <String>[];
    try {
      folders = LocalFavoritesManager().folderNames;
    } catch (_) {
      // Favourites may not be initialised yet; the field still works.
    }
    return _field(
      'favoriteFolder',
      _stringConfig('favoriteFolder', ''),
      label: 'Favourites folder'.tl,
      helper: folders.isEmpty
          ? 'The folder is created if it does not exist.'.tl
          : 'Existing folders: @a'.tlParams({'a': folders.join(', ')}),
    );
  }

  // ---------------------------------------------------------------------------
  // Sliver helpers
  // ---------------------------------------------------------------------------

  Widget _section(String title, IconData icon) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(title, style: ts.s16),
          ],
        ),
      ),
    );
  }

  Widget _wrap(List<Widget> children) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      ),
    );
  }

  Widget _field(
    String key,
    String initial, {
    required String label,
    String? helper,
    bool number = false,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          key: Key('field-$key'),
          controller: _controller(key, initial),
          keyboardType: number ? TextInputType.number : TextInputType.text,
          onChanged: (_) => setState(() => _error = null),
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    );
  }

  Widget _select(
    String label,
    List<String> values,
    int selectedIndex,
    void Function(int index) onTap,
  ) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            Expanded(child: Text(label, style: ts.s14)),
            Select(
              current: values[selectedIndex.clamp(0, values.length - 1)],
              values: values,
              onTap: onTap,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  ScheduleSpec? _buildSchedule() {
    switch (_scheduleType) {
      case ScheduleType.interval:
        final minutes = int.tryParse(
          _controller(
            'intervalMinutes',
            _intervalMinutesInitial().toString(),
          ).text.trim(),
        );
        if (minutes == null ||
            minutes < ScheduleSpec.minimumInterval.inMinutes) {
          return null;
        }
        return ScheduleSpec.everyInterval(Duration(minutes: minutes));
      case ScheduleType.daily:
        return ScheduleSpec.daily(hour: _hour, minute: _minute);
      case ScheduleType.weekly:
        if (_weekdays.isEmpty) {
          return null;
        }
        return ScheduleSpec.weekly(
          weekdays: _weekdays.toList(),
          hour: _hour,
          minute: _minute,
        );
      case ScheduleType.monthly:
        return ScheduleSpec.monthly(
          dayOfMonth: _dayOfMonth,
          hour: _hour,
          minute: _minute,
        );
      case ScheduleType.cron:
        final text = _controller('cron', '0 3 * * *').text.trim();
        if (!CronExpression.isValid(text)) {
          return null;
        }
        return ScheduleSpec.cron(text);
    }
  }

  Map<String, dynamic> _buildConfig() {
    switch (_typeKey) {
      case RankingMonitorRunner.key:
        return <String, dynamic>{
          'sources': _selectedSources.toList(),
          // Keep the legacy list untouched until the user changes a
          // per-source option. This lets older tasks round-trip without
          // changing their first-option behaviour.
          'options': _rankingOptionsEdited
              ? <String>[]
              : _stringListConfig('options'),
          RankingMonitorRunner.optionsBySourceConfigKey: {
            for (final entry in _selectedRankingOptions.entries)
              if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
          },
          'pagesPerOption': _intValue('pagesPerOption', 1),
          'maxNewPerRun': _intValue('maxNewPerRun', 50),
          'throttleMs': _intValue('throttleMs', 300),
          'autoFavorite': _autoFavorite,
          'favoriteFolder': _textValue('favoriteFolder', ''),
          'autoDownload': _autoDownload,
          'forgetAfterDays': _intValue('forgetAfterDays', 90),
          'nasConnectionId': _nasConnectionId,
        };
      case IncrementalDownloadRunner.key:
        return <String, dynamic>{
          'scope': _scope,
          'favoriteFolder': _textValue('favoriteFolder', ''),
          'maxComicsPerRun': _intValue('maxComicsPerRun', 20),
          'maxChaptersPerComic': _intValue('maxChaptersPerComic', 0),
          'throttleMs': _intValue('throttleMs', 300),
          'nasConnectionId': _nasConnectionId,
        };
      case NasSyncRunner.key:
        return <String, dynamic>{'nasConnectionId': _nasConnectionId};
      default:
        return <String, dynamic>{};
    }
  }

  void _save() {
    final runner = TaskRunnerRegistry.find(_typeKey);
    if (runner == null) {
      setState(() => _error = 'Unknown task type'.tl);
      return;
    }

    final ScheduleSpec schedule;
    try {
      final built = _buildSchedule();
      if (built == null) {
        setState(() => _error = 'Please complete the schedule'.tl);
        return;
      }
      schedule = built;
    } catch (e) {
      setState(() => _error = e.toString());
      return;
    }

    final scheduleError = schedule.validationError();
    if (scheduleError != null) {
      setState(() => _error = scheduleError.tl);
      return;
    }

    final config = _buildConfig();
    final configError = runner.validateConfig(config);
    if (configError != null) {
      setState(() => _error = configError.tl);
      return;
    }

    final rawName = _controller('name', runner.displayName).text.trim();
    final name = rawName.isEmpty ? runner.displayName : rawName;
    final retry = TaskRetryPolicy(maxAttempts: _maxAttempts);
    final engine = SchedulerEngine();
    final existing = widget.existing;

    if (existing == null) {
      final created = engine.createTask(
        typeKey: _typeKey,
        name: name,
        schedule: schedule,
        config: config,
        retry: retry,
        enabled: _enabled,
        runOnStart: _runOnStart,
      );
      if (created == null) {
        setState(() => _error = 'Could not create the task'.tl);
        return;
      }
      context.pop(created);
      return;
    }

    engine.updateTask(
      existing.copyWith(
        name: name,
        schedule: schedule,
        config: config,
        retry: retry,
        enabled: _enabled,
        runOnStart: _runOnStart,
      ),
    );
    context.pop(engine.findTask(existing.id) ?? existing);
  }
}

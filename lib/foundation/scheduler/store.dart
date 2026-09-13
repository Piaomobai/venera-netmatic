import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'schedule.dart';
import 'task.dart';

/// SQLite persistence for scheduled tasks and their run history.
///
/// Uses its own database file rather than `local.db`, because
/// `LocalManager._db` is private (`local.dart:185`) and the rest of the app
/// follows the same one-file-per-manager convention
/// (`cache_manager.dart:71-90`, `cookie_jar.dart:14-32`).
///
/// The engine passes `'${App.dataPath}/scheduler.db'`; keeping the path an
/// explicit argument rather than reading `App.dataPath` internally means this
/// class has no Flutter dependency and can be tested against a temporary
/// directory.
class SchedulerStore {
  SchedulerStore._();

  static SchedulerStore? _instance;

  factory SchedulerStore() => _instance ??= SchedulerStore._();

  Database? _db;

  String? _path;

  bool get isOpen => _db != null;

  String? get path => _path;

  Database get _database =>
      _db ?? (throw StateError('SchedulerStore is not open'));

  /// Number of run records retained per task. Older rows are pruned after
  /// each completed run so the history table cannot grow without bound.
  static const int defaultRunsPerTask = 50;

  /// Opens (creating if needed) the scheduler database at [path].
  ///
  /// Safe to call again with the same path; a different path reopens.
  void open(String path) {
    if (_db != null && _path == path) {
      return;
    }
    close();
    final directory = Directory(File(path).parent.path);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    _db = sqlite3.open(path);
    _path = path;
    _createSchema();
    _migrate();
  }

  void close() {
    final db = _db;
    _db = null;
    _path = null;
    db?.dispose();
  }

  void _createSchema() {
    final db = _database;
    db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_tasks (
        id TEXT NOT NULL PRIMARY KEY,
        type_key TEXT NOT NULL,
        name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        run_on_start INTEGER NOT NULL DEFAULT 0,
        schedule TEXT NOT NULL,
        config TEXT NOT NULL,
        retry TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_run_at INTEGER,
        next_run_at INTEGER,
        last_state TEXT NOT NULL DEFAULT 'never',
        last_error TEXT,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        last_summary TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS task_runs (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        state TEXT NOT NULL,
        message TEXT,
        error TEXT,
        summary TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_task_runs_task
      ON task_runs (task_id, started_at DESC);
    ''');
    // Generic "have I seen this before?" table. Backs the ranking monitor's
    // new-entry detection and the incremental downloader's chapter tracking.
    db.execute('''
      CREATE TABLE IF NOT EXISTS seen_items (
        namespace TEXT NOT NULL,
        item_key TEXT NOT NULL,
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        payload TEXT,
        PRIMARY KEY (namespace, item_key)
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_seen_items_ns
      ON seen_items (namespace, first_seen_at DESC);
    ''');
  }

  /// Adds columns introduced after the first release.
  ///
  /// Follows the pattern used by `history.dart:223-225`: read
  /// `PRAGMA table_info` and `alter table` only the missing columns.
  void _migrate() {
    final db = _database;
    final existing = <String>{};
    for (final row in db.select('PRAGMA table_info(scheduled_tasks);')) {
      final name = row['name'];
      if (name is String) {
        existing.add(name);
      }
    }
    const additions = <String, String>{
      'last_summary': 'TEXT',
      'consecutive_failures': 'INTEGER NOT NULL DEFAULT 0',
      'run_on_start': 'INTEGER NOT NULL DEFAULT 0',
    };
    for (final entry in additions.entries) {
      if (!existing.contains(entry.key)) {
        db.execute(
          'ALTER TABLE scheduled_tasks ADD COLUMN ${entry.key} ${entry.value};',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  /// All tasks, ordered for display: manual order first, then creation time.
  List<TaskDefinition> loadTasks() {
    final rows = _database.select('''
      SELECT * FROM scheduled_tasks
      ORDER BY sort_order ASC, created_at ASC;
    ''');
    final tasks = <TaskDefinition>[];
    for (final row in rows) {
      final task = _taskFromRow(row);
      if (task != null) {
        tasks.add(task);
      }
    }
    return tasks;
  }

  TaskDefinition? loadTask(String id) {
    final rows = _database.select(
      'SELECT * FROM scheduled_tasks WHERE id = ?;',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _taskFromRow(rows.first);
  }

  /// Inserts or replaces [task].
  void saveTask(TaskDefinition task) {
    _database.execute('''
      INSERT OR REPLACE INTO scheduled_tasks (
        id, type_key, name, enabled, run_on_start, schedule, config, retry,
        sort_order, created_at, last_run_at, next_run_at, last_state,
        last_error, consecutive_failures, last_summary
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''', [
      task.id,
      task.typeKey,
      task.name,
      task.enabled ? 1 : 0,
      task.runOnStart ? 1 : 0,
      jsonEncode(task.schedule.toJson()),
      jsonEncode(task.config),
      jsonEncode(task.retry.toJson()),
      task.sortOrder,
      task.createdAt.millisecondsSinceEpoch,
      task.lastRunAt?.millisecondsSinceEpoch,
      task.nextRunAt?.millisecondsSinceEpoch,
      task.lastState.name,
      task.lastError,
      task.consecutiveFailures,
      task.lastSummary == null ? null : jsonEncode(task.lastSummary),
    ]);
  }

  void saveTasks(Iterable<TaskDefinition> tasks) {
    _database.execute('BEGIN TRANSACTION;');
    try {
      for (final task in tasks) {
        saveTask(task);
      }
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
    _database.execute('COMMIT;');
  }

  /// Deletes a task and its run history.
  void deleteTask(String id) {
    _database.execute('BEGIN TRANSACTION;');
    try {
      _database.execute('DELETE FROM task_runs WHERE task_id = ?;', [id]);
      _database.execute('DELETE FROM scheduled_tasks WHERE id = ?;', [id]);
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
    _database.execute('COMMIT;');
  }

  /// Rewrites `sort_order` for [orderedIds], following the given order.
  void reorder(Iterable<String> orderedIds) {
    _database.execute('BEGIN TRANSACTION;');
    try {
      var index = 0;
      for (final id in orderedIds) {
        _database.execute(
          'UPDATE scheduled_tasks SET sort_order = ? WHERE id = ?;',
          [index, id],
        );
        index++;
      }
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
    _database.execute('COMMIT;');
  }

  int countTasks() {
    final rows = _database.select('SELECT COUNT(*) FROM scheduled_tasks;');
    return rows.isEmpty ? 0 : (rows.first[0] as int);
  }

  TaskDefinition? _taskFromRow(Row row) {
    try {
      final scheduleJson = jsonDecode(row['schedule'] as String);
      final schedule = scheduleJson is Map
          ? ScheduleSpec.fromJson(Map<String, dynamic>.from(scheduleJson))
          : null;
      if (schedule == null) {
        return null;
      }
      final configJson = jsonDecode(row['config'] as String);
      final retryJson = jsonDecode(row['retry'] as String);
      final summaryRaw = row['last_summary'];
      return TaskDefinition(
        id: row['id'] as String,
        typeKey: row['type_key'] as String,
        name: row['name'] as String,
        schedule: schedule,
        enabled: (row['enabled'] as int) != 0,
        runOnStart: ((row['run_on_start'] as int?) ?? 0) != 0,
        config: configJson is Map
            ? Map<String, dynamic>.from(configJson)
            : const {},
        retry: retryJson is Map
            ? TaskRetryPolicy.fromJson(Map<String, dynamic>.from(retryJson))
            : const TaskRetryPolicy(),
        sortOrder: row['sort_order'] as int,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        lastRunAt: _dateFrom(row['last_run_at']),
        nextRunAt: _dateFrom(row['next_run_at']),
        lastState: _stateFrom(row['last_state']),
        lastError: row['last_error'] as String?,
        consecutiveFailures: (row['consecutive_failures'] as int?) ?? 0,
        lastSummary: summaryRaw is String && summaryRaw.isNotEmpty
            ? _mapFromJsonString(summaryRaw)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Runs
  // ---------------------------------------------------------------------------

  /// Records a run that has just started and returns its rowid.
  int insertRun(TaskRunRecord record) {
    _database.execute('''
      INSERT INTO task_runs (
        task_id, started_at, finished_at, state, message, error, summary
      ) VALUES (?, ?, ?, ?, ?, ?, ?);
    ''', [
      record.taskId,
      record.startedAt.millisecondsSinceEpoch,
      record.finishedAt?.millisecondsSinceEpoch,
      record.state.name,
      record.message,
      record.error,
      record.summary == null ? null : jsonEncode(record.summary),
    ]);
    return _database.lastInsertRowId;
  }

  /// Writes the terminal state of a run started by [insertRun].
  void finishRun(TaskRunRecord record) {
    final rowId = record.rowId;
    if (rowId == null) {
      return;
    }
    _database.execute('''
      UPDATE task_runs
      SET finished_at = ?, state = ?, message = ?, error = ?, summary = ?
      WHERE id = ?;
    ''', [
      record.finishedAt?.millisecondsSinceEpoch,
      record.state.name,
      record.message,
      record.error,
      record.summary == null ? null : jsonEncode(record.summary),
      rowId,
    ]);
  }

  /// Closes run rows that a previous process left as `running`.
  ///
  /// A run interrupted by a shutdown or a crash never reaches [finishRun], so
  /// without this the history would show a run that started and never ends.
  /// Returns how many rows were closed.
  int closeInterruptedRuns({String message = 'Interrupted by app shutdown'}) {
    final open = _database.select(
      'SELECT COUNT(*) FROM task_runs WHERE state = ?;',
      [TaskRunState.running.name],
    );
    final count = open.isEmpty ? 0 : (open.first[0] as int);
    if (count == 0) {
      return 0;
    }
    _database.execute('''
      UPDATE task_runs
      SET state = ?, finished_at = MAX(started_at, ?), message = ?
      WHERE state = ?;
    ''', [
      TaskRunState.cancelled.name,
      DateTime.now().millisecondsSinceEpoch,
      message,
      TaskRunState.running.name,
    ]);
    return count;
  }

  /// Most recent runs first.
  List<TaskRunRecord> loadRuns({String? taskId, int limit = 100}) {
    final ResultSet rows;
    if (taskId == null) {
      rows = _database.select('''
        SELECT * FROM task_runs ORDER BY started_at DESC LIMIT ?;
      ''', [limit]);
    } else {
      rows = _database.select('''
        SELECT * FROM task_runs WHERE task_id = ? ORDER BY started_at DESC LIMIT ?;
      ''', [taskId, limit]);
    }
    final runs = <TaskRunRecord>[];
    for (final row in rows) {
      runs.add(TaskRunRecord(
        rowId: row['id'] as int,
        taskId: row['task_id'] as String,
        startedAt:
            DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
        finishedAt: _dateFrom(row['finished_at']),
        state: _stateFrom(row['state']),
        message: row['message'] as String?,
        error: row['error'] as String?,
        summary: row['summary'] is String
            ? _mapFromJsonString(row['summary'] as String)
            : null,
      ));
    }
    return runs;
  }

  int countRuns(String taskId) {
    final rows = _database.select(
      'SELECT COUNT(*) FROM task_runs WHERE task_id = ?;',
      [taskId],
    );
    return rows.isEmpty ? 0 : (rows.first[0] as int);
  }

  /// Drops all but the newest [keepPerTask] runs of every task.
  void pruneRuns({int keepPerTask = defaultRunsPerTask}) {
    final ids = <String>[];
    for (final row in _database.select('SELECT DISTINCT task_id FROM task_runs;')) {
      ids.add(row['task_id'] as String);
    }
    if (ids.isEmpty) {
      return;
    }
    _database.execute('BEGIN TRANSACTION;');
    try {
      for (final id in ids) {
        _database.execute('''
          DELETE FROM task_runs
          WHERE task_id = ? AND id NOT IN (
            SELECT id FROM task_runs
            WHERE task_id = ?
            ORDER BY started_at DESC
            LIMIT ?
          );
        ''', [id, id, keepPerTask]);
      }
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
    _database.execute('COMMIT;');
  }

  void clearRuns(String taskId) {
    _database.execute('DELETE FROM task_runs WHERE task_id = ?;', [taskId]);
  }

  void clearAllRuns() {
    _database.execute('DELETE FROM task_runs;');
  }

  /// Replaces the entire task list, used by import.
  void replaceAll(List<TaskDefinition> tasks) {
    _database.execute('BEGIN TRANSACTION;');
    try {
      _database.execute('DELETE FROM task_runs;');
      _database.execute('DELETE FROM scheduled_tasks;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
    _database.execute('COMMIT;');
    saveTasks(tasks);
  }

  // ---------------------------------------------------------------------------
  // Seen items
  // ---------------------------------------------------------------------------

  /// Records that [key] has now been observed in [namespace].
  ///
  /// Returns true when this is the **first** time it has been seen, which is
  /// what the ranking monitor uses to distinguish a genuinely new entry from
  /// one merely re-listed on a later page or run.
  bool markSeen(String namespace, String key, {String? payload}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _database.execute(
      'INSERT OR IGNORE INTO seen_items '
      '(namespace, item_key, first_seen_at, last_seen_at, payload) '
      'VALUES (?, ?, ?, ?, ?);',
      [namespace, key, now, now, payload],
    );
    if (_database.updatedRows > 0) {
      return true;
    }
    _database.execute(
      'UPDATE seen_items SET last_seen_at = ? '
      'WHERE namespace = ? AND item_key = ?;',
      [now, namespace, key],
    );
    return false;
  }

  bool isSeen(String namespace, String key) {
    final rows = _database.select(
      'SELECT 1 FROM seen_items WHERE namespace = ? AND item_key = ?;',
      [namespace, key],
    );
    return rows.isNotEmpty;
  }

  int countSeen(String namespace) {
    final rows = _database.select(
      'SELECT COUNT(*) FROM seen_items WHERE namespace = ?;',
      [namespace],
    );
    return rows.isEmpty ? 0 : (rows.first[0] as int);
  }

  void clearSeen(String namespace) {
    _database.execute('DELETE FROM seen_items WHERE namespace = ?;', [namespace]);
  }

  /// Forgets entries not observed since [olderThan].
  ///
  /// Without this the ranking monitor would remember every comic ever listed
  /// and could never re-report one that legitimately left and returned.
  int pruneSeenBefore(String namespace, DateTime olderThan) {
    _database.execute(
      'DELETE FROM seen_items WHERE namespace = ? AND last_seen_at < ?;',
      [namespace, olderThan.millisecondsSinceEpoch],
    );
    return _database.updatedRows;
  }

  /// Most recently first-seen entries in [namespace].
  List<SeenItem> loadSeen(String namespace, {int limit = 100}) {
    final rows = _database.select('''
      SELECT * FROM seen_items WHERE namespace = ?
      ORDER BY first_seen_at DESC LIMIT ?;
    ''', [namespace, limit]);
    final items = <SeenItem>[];
    for (final row in rows) {
      items.add(SeenItem(
        key: row['item_key'] as String,
        firstSeenAt:
            DateTime.fromMillisecondsSinceEpoch(row['first_seen_at'] as int),
        lastSeenAt:
            DateTime.fromMillisecondsSinceEpoch(row['last_seen_at'] as int),
        payload: row['payload'] as String?,
      ));
    }
    return items;
  }

  /// Every namespace currently tracked, used to prune on a schedule.
  List<String> seenNamespaces() {
    final rows = _database.select('SELECT DISTINCT namespace FROM seen_items;');
    return rows.map((row) => row['namespace'] as String).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static DateTime? _dateFrom(Object? value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  static TaskRunState _stateFrom(Object? value) {
    if (value is String) {
      for (final state in TaskRunState.values) {
        if (state.name == value) {
          return state;
        }
      }
    }
    return TaskRunState.never;
  }

  static Map<String, dynamic>? _mapFromJsonString(String data) {
    if (data.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Corrupt summary; treat as absent rather than failing the whole load.
    }
    return null;
  }
}

/// One entry in the `seen_items` table.
class SeenItem {
  const SeenItem({
    required this.key,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.payload,
  });

  final String key;

  final DateTime firstSeenAt;

  final DateTime lastSeenAt;

  /// Optional opaque annotation supplied by the caller.
  final String? payload;

  @override
  String toString() => 'SeenItem($key, first: $firstSeenAt, last: $lastSeenAt)';
}

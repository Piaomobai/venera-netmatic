import 'package:venera_netmatic/foundation/scheduler/task.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/incremental_download.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/nas_sync.dart';
import 'package:venera_netmatic/foundation/scheduler/tasks/ranking_monitor.dart';

/// Registers every task type the scheduler ships with.
///
/// Called once by [SchedulerEngine.init], so runners exist before any persisted
/// task is dispatched (otherwise a reloaded task would be marked failed with
/// "Unknown task type").
void registerBuiltInTaskRunners() {
  _register(RankingMonitorRunner.key, RankingMonitorRunner.new);
  _register(IncrementalDownloadRunner.key, IncrementalDownloadRunner.new);
  _register(NasSyncRunner.key, NasSyncRunner.new);
}

void _register(String typeKey, SchedulableRunner Function() create) {
  if (!TaskRunnerRegistry.has(typeKey)) {
    TaskRunnerRegistry.register(create());
  }
}

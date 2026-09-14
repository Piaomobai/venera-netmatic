import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/foundation/scheduler/task.dart';

/// Periodically mirrors the complete local comic library to one configured NAS.
///
/// [NasManager] owns the protocol-specific transfer and SHA-256 manifest logic,
/// so scheduled, manual, WebDAV, FTP and SMB syncs all make the same decision
/// about whether a file has changed.
class NasSyncRunner extends SchedulableRunner {
  static const String key = 'nasSync';

  @override
  String get typeKey => key;

  @override
  String get displayName => 'NAS sync';

  @override
  String get description =>
      'Synchronize the local comic library to a NAS, skipping comics already '
      'marked as current and files with the same SHA-256 hash';

  @override
  Map<String, dynamic> defaultConfig() => <String, dynamic>{
    'nasConnectionId': null,
  };

  @override
  String? validateConfig(Map<String, dynamic> config) {
    final id = config['nasConnectionId'];
    if (id is! String || id.trim().isEmpty) {
      return 'A NAS connection is required';
    }
    return null;
  }

  @override
  Future<TaskRunOutcome> run(TaskRunContext context) async {
    context.throwIfCancelled();
    final connectionId = context.task.config['nasConnectionId'];
    if (connectionId is! String || connectionId.trim().isEmpty) {
      return const TaskRunOutcome.failed('A NAS connection is required');
    }

    final manager = NasManager.instance;
    final connection = manager.find(connectionId);
    if (connection == null) {
      return const TaskRunOutcome.failed(
        'The configured NAS connection no longer exists',
      );
    }

    void reportNasProgress() {
      final progress = manager.progress;
      if (!manager.isSyncing || progress == null) return;
      final path = progress.currentPath.isEmpty
          ? 'Preparing NAS sync'
          : progress.currentPath;
      context.reportProgress(
        progress: progress.fraction.clamp(0.0, 1.0).toDouble(),
        message:
            '${progress.scannedFiles}/${progress.totalFiles} files · $path',
      );
    }

    manager.addListener(reportNasProgress);
    try {
      context.log('Synchronizing to NAS "${connection.name}"');
      final result = await manager.syncAll(
        connectionId,
        skipMarkedComics: true,
      );
      context.throwIfCancelled();
      final message =
          'NAS sync complete: ${result.uploadedFiles} uploaded, '
          '${result.skippedFiles} unchanged';
      context.log(message);
      context.reportProgress(progress: 1, message: message);
      return TaskRunOutcome(
        success: true,
        message: message,
        summary: {
          'nasConnectionId': connectionId,
          'uploadedFiles': result.uploadedFiles,
          'skippedFiles': result.skippedFiles,
          'uploadedBytes': result.totalBytes,
        },
      );
    } on TaskCancelledException {
      rethrow;
    } catch (e) {
      context.log('NAS sync failed: $e');
      return TaskRunOutcome(
        success: false,
        error: e.toString(),
        requestRetry: true,
      );
    } finally {
      manager.removeListener(reportNasProgress);
    }
  }
}

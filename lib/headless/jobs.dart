import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';

/// Small durable CLI job journal. Credentials and raw download URLs are never
/// put in references. The application process lock owns all writes.
class CliJobs {
  CliJobs(this.directory);
  final String directory;
  final List<Map<String, dynamic>> _jobs = [];
  Future<void> _writes = Future<void>.value();

  Future<void> load() async {
    final file = File('$directory/headless_jobs.json');
    if (!await file.exists()) return;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List) throw const FormatException('Invalid CLI job journal');
    _jobs.addAll(raw.map((e) => Map<String, dynamic>.from(e as Map)));
    // The process lock proves the former owner is no longer running.
    for (final job in _jobs) {
      if (job['state'] == 'running') job['state'] = 'interrupted';
    }
  }

  List<Map<String, dynamic>> get all =>
      _jobs.reversed.map(Map<String, dynamic>.from).toList();
  Map<String, dynamic>? find(String id) {
    for (final job in _jobs) {
      if (job['id'] == id) return Map.from(job);
    }
    return null;
  }

  String? pendingDownload(String sourceKey, String comicId) {
    for (final job in _jobs.reversed) {
      final refs = job['references'];
      if (job['kind'] == 'download' &&
          refs is Map &&
          refs['sourceKey'] == sourceKey &&
          refs['comicId'] == comicId &&
          !['completed', 'cancelled'].contains(job['state'])) {
        return job['id'] as String;
      }
    }
    return null;
  }

  Future<String> create(String kind, Map<String, dynamic> references) async {
    final id = const Uuid().v4();
    _jobs.add({
      'id': id,
      'kind': kind,
      'references': references,
      'state': 'queued',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _save();
    return id;
  }

  Future<void> update(
    String id,
    String state, {
    Object? result,
    String? error,
  }) async {
    final job = _jobs.firstWhere((e) => e['id'] == id);
    job['state'] = state;
    job['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    if (result != null) job['result'] = result;
    job.remove('error');
    if (error != null) job['error'] = error;
    await _save();
  }

  Future<void> _save() {
    // Keep every unfinished job, plus the most recent 200 terminal jobs.
    var terminal = 0;
    final retained = _jobs.reversed
        .where((job) {
          if (!['completed', 'cancelled'].contains(job['state'])) return true;
          return ++terminal <= 200;
        })
        .toList()
        .reversed
        .toList();
    final data = jsonEncode(retained);
    final write = _writes.then((_) async {
      final temporary = File('$directory/headless_jobs.json.tmp');
      await temporary.writeAsString(data, flush: true);
      await temporary.rename('$directory/headless_jobs.json');
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}

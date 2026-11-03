import 'dart:io';

/// Held for the lifetime of the application, before any shared state is opened.
/// Keep the file in place: deleting it would allow locking a different inode.
class AppProcessLock {
  AppProcessLock._(this._file, this.path);

  final RandomAccessFile _file;
  final String path;
  static final Set<String> _held = {};
  bool _closed = false;

  static Future<AppProcessLock> acquire(String directory) async {
    final dir = await Directory(directory).create(recursive: true);
    final path = '${await dir.resolveSymbolicLinks()}/.venera.lock';
    if (!_held.add(path)) throw const AppBusyException();
    RandomAccessFile? file;
    try {
      file = await File(path).open(mode: FileMode.append);
      try {
        await file.lock(FileLock.exclusive);
      } on FileSystemException {
        throw const AppBusyException();
      }
      return AppProcessLock._(file, path);
    } catch (_) {
      await file?.close();
      _held.remove(path);
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _file.close();
    } finally {
      _held.remove(path);
    }
  }
}

class AppBusyException implements Exception {
  const AppBusyException();

  @override
  String toString() =>
      'This data directory is in use. Close the other Venera '
      'process or use a separate --data-dir.';
}
